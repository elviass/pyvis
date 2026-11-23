"""A source-reading outline. It describes possible behavior without running code."""
import ast

from .blueprint_teaching import calculation, condition, falls_through, input_steps, summary, text


def _line(node):
    # The opening line remains the navigation target for multiline statements.
    return ast.unparse(node).splitlines()[0][:130]


def _literal_title(value, target):
    if isinstance(value, (ast.Dict, ast.List, ast.Tuple, ast.Set)):
        pairs = isinstance(value, ast.Dict)
        elements = value.keys if pairs else value.elts
        name = {ast.Dict: '字典', ast.List: '列表', ast.Tuple: '元组', ast.Set: '集合'}[type(value)]
        count = f'，写有 {len(elements)} {"组键值" if pairs else "个元素"}' if all(
            e is not None and not isinstance(e, ast.Starred) for e in elements) else ''
        return f'建立 {target} {name}{count}'
    return None


def _breaks_loop(node):
    if isinstance(node, ast.Break):
        return True
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
        return False
    if isinstance(node, (ast.For, ast.AsyncFor, ast.While)):
        return any(_breaks_loop(child) for child in node.orelse)
    return any(_breaks_loop(child) for child in ast.iter_child_nodes(node))


def reading_flow(body):
    def branch(label, statements, empty='', role=None):
        return dict(label=label, items=block(statements), empty=empty, role=role)

    def card(stmt):
        start, end = stmt.lineno, stmt.end_lineno
        item = dict(id=f'{start}:{stmt.col_offset}', line=start, end=end,
                    kind='action', syntax=type(stmt).__name__, title=summary(stmt), detail='', branches=[],
                    terminal=not falls_through([stmt]),
                    code=_line(stmt))
        if isinstance(stmt, ast.If):
            item.update(kind='branch', title=f'判断 {condition(stmt.test)}',
                        expression=text(stmt.test), branches=[branch('条件成立', stmt.body, role='taken'),
                                  branch('条件不成立', stmt.orelse, '跳过这个分支', 'skipped')])
        elif isinstance(stmt, (ast.For, ast.AsyncFor, ast.While)):
            if isinstance(stmt, ast.While):
                title = '重复执行循环体' if isinstance(stmt.test, ast.Constant) and stmt.test.value is True else f'当 {condition(stmt.test)} 时重复'
                detail = '每轮开始前检查条件'
            else:
                title = f'逐个处理 {text(stmt.iter)} 中的元素'
                detail = f'每轮把取出的元素赋给 {text(stmt.target)}'
            always = isinstance(stmt, ast.While) and isinstance(stmt.test, ast.Constant) and stmt.test.value is True
            has_break = any(_breaks_loop(child) for child in stmt.body)
            arms = [branch('每一轮执行', stmt.body, role='taken')]
            if not always:
                label = '条件不成立' if isinstance(stmt, ast.While) else '没有下一个元素'
                arms.append(branch(label, stmt.orelse, '继续到循环之后', 'exhausted'))
            if has_break:
                arms.append(branch('执行 break', [], '退出循环，跳过循环的 else' if stmt.orelse
                                   else '退出循环，继续后续代码', 'break'))
            expression = text(stmt.test) if isinstance(stmt, ast.While) else f'{text(stmt.target)} in {text(stmt.iter)}'
            item.update(kind='loop', title=title, detail=detail, expression=expression,
                        branches=arms, terminal=always and not has_break)
        elif isinstance(stmt, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            function = not isinstance(stmt, ast.ClassDef)
            item.update(kind='definition', title=f'定义{"函数" if function else "类"} {stmt.name}',
                        detail='调用时执行函数体' if function else '',
                        branches=[branch('函数体' if function else '类体', stmt.body, role='body')],
                        name=stmt.name,
                        entry=min([start, *(d.lineno for d in stmt.decorator_list)]))
        elif isinstance(stmt, (ast.Try, ast.TryStar)):
            arms = [branch('正常路径', stmt.body, role='body')]
            for handler in stmt.handlers:
                name = text(handler.type) if handler.type is not None else '任意异常'
                arms.append(branch(f'{name} 异常', handler.body, role='handler'))
            if stmt.orelse: arms.append(branch('受保护代码正常完成后执行', stmt.orelse, role='else'))
            if stmt.finalbody: arms.append(branch('离开这段代码前执行', stmt.finalbody, role='finally'))
            item.update(kind='branch', title='执行受保护的代码', branches=arms)
        elif isinstance(stmt, (ast.With, ast.AsyncWith)):
            item.update(kind='branch', title='在指定上下文中执行',
                        detail='离开上下文时执行退出操作', branches=[branch('上下文中的操作', stmt.body)])
        elif isinstance(stmt, ast.Match):
            arms = [branch(f'匹配 {text(case.pattern)}' +
                           (f' 且 {condition(case.guard)}' if case.guard is not None else ''),
                           case.body, role='case') for case in stmt.cases]
            item.update(kind='branch', title=f'根据 {text(stmt.subject)} 选择一个匹配分支',
                        expression=text(stmt.subject),
                        detail='按代码顺序检查，执行第一个匹配的分支', branches=arms)
        elif isinstance(stmt, (ast.Assign, ast.AnnAssign)):
            targets = stmt.targets if isinstance(stmt, ast.Assign) else [stmt.target]
            target = '、'.join(text(t) for t in targets)
            value = stmt.value
            literal = _literal_title(value, target)
            if literal:
                item.update(kind='data', title=literal,
                            code=f'{target} = …' if start < end else item['code'])
            elif value is None:
                item.update(title=f'为 {target} 声明类型')
            elif isinstance(value, ast.Constant):
                item.update(kind='data', title=f'设置 {target} 的值', detail=text(value))
            elif input_steps(value):
                operations = input_steps(value)
                item.update(kind='input', title=f'读取输入并赋给 {target}',
                            detail='、'.join(label for label, _ in operations[1:]))
            elif isinstance(value, ast.Call):
                item.update(title=f'调用 {text(value.func)}，将返回值赋给 {target}')
            elif isinstance(value, ast.BinOp):
                item.update(title=f'将计算结果赋给 {target}', detail=calculation(value))
        elif isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Call):
            call = stmt.value
            if text(call.func) == 'print':
                labels = []
                for arg in call.args:
                    if isinstance(arg, ast.Constant) and isinstance(arg.value, str):
                        label = arg.value.strip()
                        if label: labels.append(label)
                    else:
                        labels.append(text(arg))
                item.update(kind='output', title='输出到控制台', detail=' '.join(labels)[:130])
            elif text(call.func) == 'input':
                item.update(kind='input')
        elif isinstance(stmt, (ast.Import, ast.ImportFrom)):
            item.update(kind='data', title='导入所需模块或名称',
                        detail='、'.join(n.asname or n.name for n in stmt.names))
        elif isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Constant) and isinstance(stmt.value.value, str):
            item.update(kind='note', title='程序说明',
                        detail=' '.join(stmt.value.value.split())[:160])
        elif isinstance(stmt, ast.Pass):
            item.update(title='保持当前状态，继续执行')
        elif isinstance(stmt, ast.Delete):
            item.update(title=f'删除 {"、".join(text(target) for target in stmt.targets)}')
        elif isinstance(stmt, ast.Assert):
            item.update(kind='branch', title=f'检查 {condition(stmt.test)}',
                        detail='检查启用时，条件不成立会抛出 AssertionError')
        elif isinstance(stmt, ast.Expr) and isinstance(stmt.value, (ast.Yield, ast.YieldFrom)):
            item.update(title='交出一个值，等待下一次迭代' if isinstance(stmt.value, ast.Yield)
                        else '依次交出所引用对象产生的值')
        elif isinstance(stmt, ast.Global):
            item.update(title=f'使用模块中的名称 {"、".join(stmt.names)}')
        elif isinstance(stmt, ast.Nonlocal):
            item.update(title=f'使用外层函数中的名称 {"、".join(stmt.names)}')
        return item

    def block(statements):
        items = [card(stmt) for stmt in statements]
        grouped = []
        for item in items:
            kind = item['kind']
            prior = grouped[-1] if grouped else {}
            if kind in ('data', 'definition', 'output') and (prior.get('items_kind') or prior.get('kind')) == kind:
                if 'items_kind' not in prior:
                    grouped[-1] = prior = dict(
                        id='set:' + prior['id'], line=prior['line'], end=prior['end'],
                        kind='group', items_kind=kind, terminal=False, code='',
                        title={'data': '准备数据', 'definition': '定义后续使用的函数或类',
                               'output': '依次输出结果'}[kind],
                        branches=[dict(label='本组操作', items=[prior], empty='')])
                children = prior['branches'][0]['items']
                children.append(item)
                prior['end'] = item['end']
                prior['detail'] = '；'.join(
                    c['detail'] if kind == 'output' and c['detail'] else c['title'] for c in children[:3])
                if len(children) > 3: prior['detail'] += f'，共 {len(children)} 项'
            else:
                grouped.append(item)
        return grouped

    return block(body)
