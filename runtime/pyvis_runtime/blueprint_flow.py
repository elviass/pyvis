"""Structured placement hints; actual connections remain the AST graph's edges."""
import ast
from .blueprint_regions import key


def flow_tree(scope, body, specs):
    used = set()

    def take(stmt, phase):
        children = []
        for spec in specs:
            if spec['id'] not in used and spec.get('owner') == key(scope, stmt) and spec.get('phase') == phase:
                used.add(spec['id'])
                children.append(dict(kind='section', id=spec['id']))
        return children

    def seq(children):
        return dict(kind='sequence', children=children)

    def block(statements):
        result = []
        for stmt in statements:
            start = len(result)
            if isinstance(stmt, ast.If):
                result.extend(take(stmt, ''))
                result.append(dict(kind='fork', labels=['条件成立', '条件不成立'],
                                   children=[block(stmt.body), block(stmt.orelse)]))
                result.extend(take(stmt, 'end'))
            elif isinstance(stmt, (ast.While, ast.For, ast.AsyncFor)):
                result.extend(take(stmt, ''))
                result.append(dict(kind='fork', labels=['循环体', '循环正常结束'],
                                   children=[block(stmt.body), block(stmt.orelse)]))
                result.extend(take(stmt, 'end'))
            elif isinstance(stmt, ast.Try):
                result.extend(take(stmt, 'header'))
                dispatch = take(stmt, 'except')
                handlers, labels = [], []
                for handler in stmt.handlers:
                    handlers.append(seq([*take(handler, 'end'), block(handler.body)]))
                    labels.append(ast.unparse(handler.type) if handler.type else '任意异常')
                result.append(dict(kind='fork', labels=['正常执行', '异常处理'],
                                   children=[seq([block(stmt.body), block(stmt.orelse)]),
                                             seq([*dispatch, dict(kind='fork', labels=labels, children=handlers)])]))
                result.extend(take(stmt, 'finally'))
                result.append(block(stmt.finalbody))
                result.extend(take(stmt, 'end'))
            elif isinstance(stmt, (ast.With, ast.AsyncWith)):
                result.extend(take(stmt, ''))
                result.append(block(stmt.body))
                result.extend(take(stmt, 'end'))
            else:
                result.extend(take(stmt, 'end'))
            if isinstance(stmt, (ast.If, ast.While, ast.For, ast.AsyncFor, ast.Try, ast.With, ast.AsyncWith)):
                children = result[start:]
                del result[start:]
                header = next((s for s in specs if s.get('owner') == key(scope, stmt)), None)
                if header:
                    result.append(dict(kind='group', id=key(scope, stmt), header=header['id'],
                                       title=header['title'], line=stmt.lineno, end_line=stmt.end_lineno,
                                       children=children))
                else:
                    result.extend(children)
        return seq(result)

    # Entry/formal parameters have no statement owner.
    entry = [dict(kind='section', id=s['id']) for s in specs if not s.get('owner')]
    used.update(n['id'] for n in entry)
    tree = block(body)
    remaining = [dict(kind='section', id=s['id']) for s in specs if s['id'] not in used]
    return seq([*entry, tree, *remaining])
