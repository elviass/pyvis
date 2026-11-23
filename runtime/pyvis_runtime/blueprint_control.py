"""Static exception and cleanup paths. Never evaluates the learner's code."""
import ast
from .blueprint_liveness import needed_after, names


class ControlFlow:
    def merge_paths(self, source, paths, title='所选路径中的值', phase='end'):
        paths = [(label, bindings) for label, bindings in paths if bindings is not None]
        if not paths:
            return {}
        merged = {}
        needed = needed_after(self, source)
        for name in sorted(set().union(*(set(b) for _, b in paths))):
            values = [b.get(name) for _, b in paths]
            if len(set(values)) == 1:
                if values[0] is not None: merged[name] = values[0]
                continue
            if name not in needed: continue
            slot = self.node(source, 'variable', f'{name}：{title}',
                             [label for label, _ in paths], symbol=name,
                             region_phase=phase, line=source.end_lineno)
            for i, ((label, _), value) in enumerate(zip(paths, values)):
                if value is None:
                    value = self.node(source, 'unbound', f'{name} 可能未赋值',
                                      symbol=name, region_phase=phase, line=source.end_lineno)
                self.edge(value, slot, 'binding', label, port=i)
            merged[name] = slot
        return merged

    def abrupt(self, source, endpoint, kind, destination=None, value=None, loop_depth=None):
        depth = len(self.loops) if loop_depth is None else loop_depth
        cleanup = next((f for f in reversed(self.cleanups)
                        if kind == 'return' or depth <= f['loop_depth']), None)
        if cleanup is not None:
            self.edge(endpoint, cleanup['entry'], 'flow', f'先{cleanup["label"]}')
            cleanup['pending'].append(dict(source=source, kind=kind, destination=destination,
                                           value=value, loop_depth=depth))
        elif kind == 'return':
            # The real return node is created only after all enclosing cleanup.
            if next(n for n in self.nodes if n['id'] == endpoint)['kind'] != 'return':
                returned = self.node(source, 'return', '返回给调用处', ['返回值'], region_phase='end')
                self.edge(value, returned)
                self.edge(endpoint, returned, 'flow', '继续返回')
        else:
            self.edge(endpoint, destination, 'flow', '跳转')

    def resume_cleanup(self, source, frame, tails, normal, exception_target):
        if not tails:
            return []
        dispatch = self.node(source, 'condition', '按进入原因继续', ['进入原因'],
                             region_phase='end', line=source.end_lineno)
        self.flow(tails, dispatch)
        frame['dispatch'] = dispatch
        normal_tails = [(dispatch, '正常继续')] if normal else []
        if frame['error_used']:
            propagated = self.node(source, 'raise', '继续传递异常', region_phase='end',
                                   line=source.end_lineno, no_exception_edge=True)
            self.edge(dispatch, propagated, 'guard', '尚未处理的异常')
            self.edge(propagated, exception_target, 'exception', '向外传递')
        for pending in frame['pending']:
            resumed = self.node(pending['source'], 'control',
                                '继续返回' if pending['kind'] == 'return' else
                                '继续跳出循环' if pending['kind'] == 'break' else '继续下一轮',
                                region_phase='end')
            self.edge(dispatch, resumed, 'guard', f'{pending["kind"]} · L{pending["source"].lineno}')
            self.abrupt(pending['source'], resumed, pending['kind'], pending['destination'],
                        pending['value'], pending['loop_depth'])
        return normal_tails

    def try_statement(self, stmt, tails):
        original, outer_error = dict(self.bindings), self.exception_target
        begin = self.node(stmt, 'try', '进入 try', region_phase='header')
        self.flow(tails, begin)
        handler_line = stmt.handlers[0].lineno if stmt.handlers else stmt.end_lineno
        dispatch = self.node(stmt.handlers[0] if stmt.handlers else stmt, 'exception', '捕获发生的异常', region_phase='except', line=handler_line)
        final_entry = self.node(stmt.finalbody[0], 'finally', '执行 finally', region_phase='finally') if stmt.finalbody else None
        final_error = self.node(stmt, 'exception', '携带异常进入 finally', region_phase='finally', line=stmt.finalbody[0].lineno) if stmt.finalbody else None
        if final_entry: self.edge(final_error, final_entry, 'flow', '先执行 finally')
        frame = dict(entry=final_entry, label='执行 finally', pending=[], loop_depth=len(self.loops), error_used=False)
        if final_entry: self.cleanups.append(frame)
        self.exception_target = dispatch
        first_body_node = len(self.nodes)
        body_tails = self.block(stmt.body, [(begin, '')])
        body_bindings = dict(self.bindings)
        # A handler may be entered before or after any assignment in the body.
        possible = {}
        for n in self.nodes[first_body_node:]:
            if n['scope'] == self.scope and n['kind'] == 'symbol' and n.get('assignment_line'):
                possible.setdefault(n['symbol'], []).append(n['id'])
        handler_bindings = dict(original)
        handler_reads = set().union(*(names(h).loaded for h in stmt.handlers), *(names(s).loaded for s in stmt.finalbody))
        for name, versions in possible.items():
            if name not in handler_reads | needed_after(self, stmt): continue
            initial = original.get(name)
            slot = self.node(stmt, 'variable', f'{name}：异常发生前的值',
                             ['进入 try 时', *[f'可能写入 {i+1}' for i in range(len(versions))]],
                             symbol=name, region_phase='except', line=handler_line)
            if initial is None:
                initial = self.node(stmt, 'unbound', f'{name} 可能未赋值', symbol=name, region_phase='except', line=handler_line)
            self.edge(initial, slot, 'binding', '进入 try 时')
            for i, version in enumerate(versions): self.edge(version, slot, 'binding', '可能已写入', port=i+1)
            handler_bindings[name] = slot
        self.exception_target = final_error or outer_error
        normal_tails = self.block(stmt.orelse, body_tails) if stmt.orelse and body_tails else body_tails
        paths = [('正常完成', dict(self.bindings))] if normal_tails else []
        handler_tails, unmatched = [], dispatch
        old_statement = self.statement
        for handler in stmt.handlers:
            self.statement = handler
            self.bindings = dict(handler_bindings)
            name = self.text(handler.type) if handler.type else '任意异常'
            check = self.node(handler, 'exception', f'匹配 {name}', ['异常'], exception_type=name)
            self.edge(unmatched, check, 'guard', '检查异常类型' if unmatched == dispatch else '不匹配，继续检查')
            entry = self.node(handler, 'branch', '处理这个异常', ['匹配结果'])
            self.edge(check, entry, 'guard', '匹配')
            if handler.name:
                alias = ast.copy_location(ast.Name(id=handler.name, ctx=ast.Store()), handler)
                assigned = self.store(alias, check)
                self.edge(entry, assigned, 'flow', '保存异常对象')
                entry = assigned
            ends = self.block(handler.body, [(entry, '')])
            if handler.name: self.bindings.pop(handler.name, None)  # Python clears the exception alias.
            if ends:
                paths.append((f'处理 {name}', dict(self.bindings)))
                handler_tails.extend(ends)
            unmatched = check if handler.type is not None else None
            if unmatched is None: break
        self.statement = old_statement
        self.bindings = self.merge_paths(stmt, paths, '正常或异常处理后的值')
        successful = [*normal_tails, *handler_tails]
        if unmatched is not None:
            self.edge(unmatched, final_error or outer_error, 'exception', '未匹配，向外传递')
            if not (final_error or outer_error):
                escaped = self.node(stmt, 'raise', '未处理的异常向外传递', region_phase='except', line=handler_line, no_exception_edge=True)
                self.edge(unmatched, escaped, 'exception', '未匹配')
        if final_entry:
            self.flow(successful, final_entry)
            frame['error_used'] = unmatched is not None or any(e['to'] == final_error for e in self.edges)
            self.cleanups.pop()
            self.exception_target = outer_error
            final_tails = self.block(stmt.finalbody, [(final_entry, '')])
            successful = self.resume_cleanup(stmt, frame, final_tails, bool(successful), outer_error)
        self.exception_target = outer_error
        if not successful: return []
        end = self.node(stmt, 'join', '离开 try', region_phase='end', line=stmt.end_lineno)
        self.flow(successful, end)
        return [(end, '')]

    def with_statement(self, stmt, tails):
        # Each manager enters left-to-right and exits right-to-left.
        frames = []
        outer_error = self.exception_target
        for index, item in enumerate(stmt.items):
            value = self.expression(item.context_expr)
            entered = self.node(item.context_expr, 'context_enter', '进入上下文', ['上下文管理器'])
            self.edge(value, entered); self.flow(tails, entered)
            tails = [(entered, '')]
            exited = self.node(stmt, 'context_exit', '退出上下文', ['进入原因'],
                               region_phase=f'exit-{index}', line=stmt.end_lineno, no_exception_edge=True)
            error_gate = self.node(stmt, 'exception', '携带异常退出上下文',
                                   region_phase=f'exit-{index}', line=stmt.end_lineno)
            self.edge(error_gate, exited, 'flow', '先退出上下文')
            frame = dict(entry=exited, error_gate=error_gate, outer_error=self.exception_target,
                         label='退出上下文', pending=[], loop_depth=len(self.loops), error_used=False)
            self.cleanups.append(frame); frames.append(frame)
            self.exception_target = error_gate
            if item.optional_vars is not None:
                result = self.result_value(item.context_expr, entered, '__enter__ 的结果')
                assigned = self.store(item.optional_vars, result)
                self.flow(tails, assigned); tails = [(assigned, '')]
        tails = self.block(stmt.body, tails)
        for index, frame in reversed(list(enumerate(frames))):
            frame['error_used'] = any(e['to'] == frame['error_gate'] for e in self.edges)
            self.cleanups.pop()
            self.exception_target = frame['outer_error']
            self.flow(tails, frame['entry'])
            self.edge(frame['entry'], self.exception_target, 'exception', '__exit__ 自身发生异常')
            normal = bool(tails)
            resume_frame = {**frame, 'error_used': False}
            resumed = self.resume_cleanup(stmt, resume_frame, [(frame['entry'], '')], normal, None)
            if frame['error_used']:
                check = self.node(stmt, 'condition', '上下文是否处理了异常', ['__exit__ 的结果'],
                                  region_phase=f'exit-{index}', line=stmt.end_lineno)
                result = self.node(stmt, 'value', '__exit__ 的结果', ['来源'], operation=frame['entry'],
                                   region_phase=f'exit-{index}', line=stmt.end_lineno)
                self.edge(frame['entry'], result)
                self.edge(result, check)
                self.edge(resume_frame['dispatch'], check, 'guard', '异常退出时')
                destination = self.exception_target or self.node(stmt, 'raise', '未处理的异常向外传递',
                                      region_phase=f'exit-{index}', line=stmt.end_lineno, no_exception_edge=True)
                self.edge(check, destination, 'exception', '未处理，向外传递')
                resumed.append((check, '已处理，继续'))
            tails = resumed
        self.exception_target = outer_error
        return tails
