"""Readable whole-scope projection; references never alter the Python program."""
import ast
from .blueprint_regions import detailed_specs
from .blueprint_teaching import lesson
from .blueprint_flow import flow_tree


def _title(stmt):
    if isinstance(stmt, ast.Try): return '异常保护'
    if isinstance(stmt, (ast.With, ast.AsyncWith)): return '上下文管理'
    if isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Constant) and isinstance(stmt.value.value, str): return '程序说明'
    if isinstance(stmt, ast.If): return '判断与分支'
    if isinstance(stmt, (ast.For, ast.AsyncFor, ast.While)): return '循环'
    if isinstance(stmt, (ast.FunctionDef, ast.AsyncFunctionDef)): return f'定义函数 {stmt.name}'
    if isinstance(stmt, ast.ClassDef): return f'定义类 {stmt.name}'
    if isinstance(stmt, ast.Return): return '返回结果'
    if isinstance(stmt, (ast.Import, ast.ImportFrom)): return '导入工具'
    if isinstance(stmt, (ast.Assign, ast.AnnAssign, ast.AugAssign)):
        targets = stmt.targets if isinstance(stmt, ast.Assign) else [stmt.target]
        names = ', '.join(ast.unparse(t) for t in targets)
        return f'计算 {names}'
    if isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Call):
        return '输出' if ast.unparse(stmt.value.func) == 'print' else f'调用 {ast.unparse(stmt.value.func)}'
    return f'第 {stmt.lineno} 行'


def _initial(stmt):
    return isinstance(stmt, (ast.Assign, ast.AnnAssign)) and isinstance(stmt.value, ast.Constant)


def whole_views(builder, scope_bodies):
    views = []
    for scope in builder.scopes:
        scope_id = scope['id']
        nodes = [dict(n) for n in builder.nodes if n['scope'] == scope_id]
        lookup = {n['id']: n for n in nodes}
        edges = [dict(e) for e in builder.edges if e['from'] in lookup and e['to'] in lookup]
        detailed = len(nodes) > 140 or any(n['kind'] in ('try', 'context_enter') for n in nodes)
        structured = detailed or any(isinstance(stmt, (ast.If, ast.While, ast.For, ast.AsyncFor, ast.Try, ast.With, ast.AsyncWith)) for stmt in scope_bodies.get(scope_id, []))
        if structured:
            specs = detailed_specs(builder, scope_id, nodes)
            for i, spec in enumerate(specs):
                spec['id'] = f'{scope_id}:section:{i}'
                for n in nodes:
                    if n['id'] in spec['members']: n['section_id'] = spec['id']
        else:
            specs = []
            for stmt in scope_bodies.get(scope_id, []):
                if _initial(stmt) and specs and specs[-1]['initial']:
                    specs[-1]['end_line'] = stmt.end_lineno
                    specs[-1]['statements'].append(stmt)
                else:
                    specs.append(dict(title='初始化变量' if _initial(stmt) else _title(stmt),
                                      line=stmt.lineno, end_line=stmt.end_lineno,
                                      initial=_initial(stmt), statements=[stmt]))
            # Entry and formal parameters belong to their own visible region.
            if nodes and (not specs or any(n['line'] < specs[0]['line'] for n in nodes)):
                first = specs[0]['line'] if specs else max(n['line'] for n in nodes) + 1
                specs.insert(0, dict(title='函数入口', line=min(n['line'] for n in nodes),
                                     end_line=first - 1, initial=False, statements=[]))

            for i, spec in enumerate(specs): spec['id'] = f'{scope_id}:section:{i}'
            for n in nodes:
                spec = next((s for s in specs if s['line'] <= n['line'] <= s['end_line']), None)
                if spec is not None: n['section_id'] = spec['id']
            specs = [s for s in specs if any(n.get('section_id') == s['id'] for n in nodes)]
        projected = []
        links, seen_links = [], set()
        for edge in edges:
            source, target = lookup[edge['from']], lookup[edge['to']]
            source_section, target_section = source.get('section_id'), target.get('section_id')
            if source_section != target_section and edge['kind'] in ('flow', 'guard', 'exception'):
                key = (source_section, target_section, edge['kind'], edge['label'])
                if source_section and target_section and key not in seen_links:
                    links.append(dict(source=source_section, target=target_section, label=edge['label'], kind=edge['kind'], from_node=edge['from'], to_node=edge['to']))
                    seen_links.add(key)
                continue
            if ((source_section != target_section or source.get('statement_id') != target.get('statement_id')) and edge['kind'] in ('data', 'binding')
                    and source['kind'] in ('symbol', 'variable', 'container', 'parameter')):
                ref = dict(id=f"ref_{source['id']}_{target['id']}_{edge['port']}", kind='reference',
                           title=target.get('symbol') or source.get('symbol') or source['title'],
                           symbol=target.get('symbol') or source.get('symbol'),
                           code=target['code'], line=target['line'], end_line=target['line'],
                           scope=scope_id, section_id=target_section, inputs=[],
                           origin_id=source['id'], origin_line=source['line'], statement_id=target.get('statement_id'),
                           reference_label=edge['label'] if edge['label'] in ('初始值', '下一轮的值', '成立时', '不成立时') else f'来自 L{source["line"]}',
                           role='同一变量在此处的引用；点击可定位来源')
                if source.get('value_type'):
                    ref['value_type'] = source['value_type']
                nodes.append(ref)
                projected.append({**edge, 'from': ref['id']})
                projected.append(dict(edge, to=ref['id'], kind='reference', label='变量来源'))
            else:
                projected.append(edge)

        def arrange_base(group, wrap=False):
            if not group: return 0, 0
            group.sort(key=lambda n: n['kind'] != 'reference')
            ids = {n['id'] for n in group}
            layout = type(builder)('')
            layout.nodes = group
            layout.edges = [e for e in projected if e['from'] in ids and e['to'] in ids and e['kind'] != 'reference']
            layout.scopes = [dict(id=scope_id, name=scope['name'])]
            layout.layout()
            # Leave wider routing corridors between columns and rows.
            columns = sorted({n['x'] for n in group})
            for n in group:
                n['_column'] = columns.index(n['x'])
                n['x'] += n['_column'] * 16
                n['y'] *= 1.15
            if wrap and len(columns) > 4:
                band_top = 0
                for start in range(0, len(columns), 4):
                    # Keep expanded content readable without shrinking the canvas.
                    band = [n for n in group if start <= n['_column'] < start + 4]
                    left = min(n['x'] for n in band)
                    first_y = min(n['y'] for n in band)
                    for n in band: n['x'] -= left - 20; n['y'] += band_top + 24 - first_y
                    band_top = max(n['y'] + n['height'] for n in band) + 64
            return max(n['x'] + n['width'] for n in group), max(n['y'] + n['height'] for n in group)

        def arrange(group):
            rows = {}
            for n in group: rows.setdefault(n.get('statement_id'), []).append(n)
            top, width = 0, 0
            for row in rows.values():
                components = [row]
                if any(n['kind'] == 'condition' for n in row):
                    members = {n['id']: n for n in row}
                    adjacency = {id: set() for id in members}
                    for edge in projected:
                        if edge['kind'] != 'reference' and edge['from'] in members and edge['to'] in members:
                            adjacency[edge['from']].add(edge['to'])
                            adjacency[edge['to']].add(edge['from'])
                    components, visited = [], set()
                    for id in members:
                        if id in visited: continue
                        pending, component = [id], []
                        while pending:
                            current = pending.pop()
                            if current in visited: continue
                            visited.add(current)
                            component.append(members[current])
                            pending.extend(adjacency[current] - visited)
                        components.append(component)
                    # Show the condition before loop state used only by later statements.
                    components.sort(key=lambda c: not any(n['kind'] == 'condition' for n in c))
                for component in components:
                    w, h = arrange_base(component, wrap=True)
                    for n in component: n['y'] += top
                    top += h + 48
                    width = max(width, w)
            return width, max(0, top - 48)

        sections, top = [], 24
        for spec in specs:
            group = [n for n in nodes if n.get('section_id') == spec['id']]
            lanes = []
            width, height = arrange(group)
            for n in group:
                n['x'] += 148
                n['y'] += top + 100
            teaching = lesson(spec['statements'], spec['title'])
            teaching['line'] = spec['line']
            sections.append(dict(id=spec['id'], title=spec['title'], line=spec['line'],
                                 end_line=spec['end_line'], x=112, y=top,
                                 width=max(400, width + 72), height=height + 128,
                                 code='; '.join(ast.unparse(s).splitlines()[0] for s in spec['statements'] if s.lineno == spec['line'] or len(spec['statements']) > 1)[:180],
                                 category={'分支汇合': 'Join', '离开循环': 'LoopExit',
                                           '准备执行 finally': 'Finally', '退出上下文': 'ContextExit',
                                           '异常处理后的继续路径': 'Join'}.get(spec['title'],
                                           type(spec['statements'][0]).__name__ if spec['statements'] else 'Entry'),
                                 path=spec.get('path', []), teaching=teaching,
                                 lanes=[dict(l, y=l['y'] + top + 100) for l in lanes]))
            top += height + 184
        tree = flow_tree(scope_id, scope_bodies.get(scope_id, []), specs) if structured else dict(kind='sequence', children=[dict(kind='section', id=s['id']) for s in sections])
        views.append(dict(scope=scope_id, detailed=detailed, flow_tree=tree, nodes=nodes, edges=projected, sections=sections,
                          section_links=links,
                          width=max((s['x'] + s['width'] + 32 for s in sections), default=500), height=top))
    return views
