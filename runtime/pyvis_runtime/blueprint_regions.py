"""Partition compound statements without swallowing their nested statements."""
import ast


def key(scope, stmt):
    return f'{scope}:{stmt.lineno}:{stmt.col_offset}:{type(stmt).__name__}'


def detailed_specs(builder, scope, nodes):
    from .blueprint_sections import _title, _initial
    specs, claimed = [], set()
    by_owner = {}
    for n in nodes: by_owner.setdefault(n.get('statement_id'), []).append(n)

    def emit(stmt, phases, title, path, merge=False):
        members = [n for n in by_owner.get(key(scope, stmt), [])
                   if n['id'] not in claimed and (phases is None or n.get('region_phase', '') in phases)]
        if not members: return
        claimed.update(n['id'] for n in members)
        start, end = min(n['line'] for n in members), max(n['line'] for n in members)
        if (merge and specs and specs[-1]['title'] == title and specs[-1]['path'] == path
                and len(specs[-1]['statements']) < 3):
            specs[-1]['members'].extend(n['id'] for n in members)
            specs[-1]['statements'].append(stmt)
            specs[-1]['end_line'] = end
        else:
            specs.append(dict(title=title, line=start, end_line=end, initial=False,
                              statements=[stmt], members=[n['id'] for n in members], path=path,
                              owner=key(scope, stmt), phase=next(iter(phases)) if phases and len(phases) == 1 else 'end'))

    def block(body, path):
        for stmt in body:
            if isinstance(stmt, ast.Try):
                emit(stmt, {'header'}, '进入异常保护', path)
                block(stmt.body, [*path, f'try · L{stmt.lineno}'])
                if stmt.orelse:
                    block(stmt.orelse, [*path, '未发生异常'])
                emit(stmt, {'except'}, '异常分派（出错时）', path)
                for handler in stmt.handlers:
                    name = builder.text(handler.type) if handler.type else '任意异常'
                    emit(handler, None, f'捕获 {name}', path)
                    block(handler.body, [*path, f'except {name}'])
                emit(stmt, {'finally'}, '准备执行 finally', path)
                block(stmt.finalbody, [*path, 'finally · 始终执行'])
                emit(stmt, None, '异常处理后的继续路径', path)
            elif isinstance(stmt, (ast.With, ast.AsyncWith)):
                emit(stmt, {''}, '进入上下文', path)
                block(stmt.body, [*path, f'with · L{stmt.lineno}'])
                emit(stmt, None, '退出上下文', path)
            elif isinstance(stmt, ast.If):
                emit(stmt, {''}, f'判断 {builder.text(stmt.test)[:54]}', path)
                block(stmt.body, [*path, f'L{stmt.lineno} 成立'])
                block(stmt.orelse, [*path, f'L{stmt.lineno} 不成立'])
                emit(stmt, None, '分支汇合', path)
            elif isinstance(stmt, (ast.While, ast.For, ast.AsyncFor)):
                caption = f'while {builder.text(stmt.test)}' if isinstance(stmt, ast.While) else f'for {builder.text(stmt.target)} in {builder.text(stmt.iter)}'
                emit(stmt, {''}, caption[:72], path)
                block(stmt.body, [*path, f'循环体 · L{stmt.lineno}'])
                block(stmt.orelse, [*path, '循环正常结束'])
                emit(stmt, None, '离开循环', path)
            else:
                title = '程序说明' if isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Constant) and isinstance(stmt.value.value, str) else '设置变量' if _initial(stmt) else _title(stmt)
                emit(stmt, None, title, path, merge=title in ('输出', '设置变量'))
    block(builder.scope_bodies.get(scope, []), [])
    extras = [n for n in nodes if n['id'] not in claimed]
    if extras:
        specs.insert(0, dict(title='函数入口', line=min(n['line'] for n in extras),
                             end_line=max(n['line'] for n in extras), initial=False,
                             statements=[], members=[n['id'] for n in extras], path=[]))
    return specs
