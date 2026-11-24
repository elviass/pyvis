"""Presentation categories corresponding to PyCharm inspection attributes.

See docs/pycharm-source-reference.md for scheme and inspection sources.
"""
import re
import ast
import tokenize

from .source_encoding import source_tokens


_IMPORT_HINT = '检查模块名、项目中的文件位置，以及软件是否提供该学习库。'
_RUFF_HINTS = {
    'F401': '删除未使用的导入，或在后续代码中使用它。',
    'F841': '检查变量是否需要使用；也可以去掉无用的赋值。',
    'F811': '检查此名称是否重复定义，避免覆盖前面的定义。',
    'F823': '函数内给名称赋值后，它通常被视为局部变量；检查赋值与读取的顺序。',
    'E722': '说明要捕获的异常类型，避免掩盖意外错误。',
}
_TYPE_HINTS = {
    'unresolved-reference': '检查名称的拼写、定义位置和当前作用域。',
    'unresolved-import': _IMPORT_HINT,
    'import-not-found': _IMPORT_HINT,
    'invalid-argument-type': '比较实际传入的值与参数要求的类型。',
    'missing-argument': '检查调用是否传入了所有必需参数。',
    'too-many-positional-arguments': '比较调用中的实参数量与函数的参数定义。',
    'unknown-argument': '检查关键字参数的名称是否与函数定义一致。',
    'missing-attribute': '检查该对象的数据类型，以及它是否具有此属性或方法。',
    'invalid-assignment': '检查赋值右侧的数据类型是否满足变量的类型声明。',
    'unsupported-operator': '检查两个操作数的类型，以及它们是否支持此运算。',
    'possibly-unresolved-reference': '检查该变量是否在每条可能到达此处的路径上都有赋值。',
}


def ruff_hint(code):
    return _RUFF_HINTS.get(code, '检查标记处的写法、空白和名称使用。')


def type_hint(code, fallback):
    return _TYPE_HINTS.get(code, fallback)


def apply_presentation(issues, source, tree=None, tokens=None):
    lines = source.split('\n')
    for issue in issues:
        code, engine = issue['code'], issue.get('engine')
        if code == 'Typo': continue
        if code in ('F401', 'F841'):
            kind, inspection = 'unused', 'PyUnresolvedReferences' if code == 'F401' else 'PyUnusedLocal'
        elif code == 'UndefinedName':
            kind, inspection = 'warning', 'PyUnresolvedReferences'
        elif engine == 'ty':
            issue['severity'] = 'warning'
            kind = 'warning'
            inspection = 'PyArgumentList' if code in ('missing-argument','too-many-positional-arguments','unknown-argument') else 'PyTypeChecker'
        else:
            kind = issue['severity']
            inspection = 'PyPep8' if code.startswith(('E','W')) else code
        issue['presentation'], issue['inspection'] = kind, inspection
        # EOF/newline diagnostics are not a fictitious character after the EOL.
        # Anchor a zero-width range to the final token of a nonempty source row.
        row = issue['line'] - 1
        if 0 <= row < len(lines) and issue.get('end_column',0) <= issue['column']:
            line = lines[row]
            if issue['column'] > len(line):
                last = list(re.finditer(r'\S+',line))
                if last:
                    issue['column'] = last[-1].start()+1
                    issue['end_column'] = last[-1].end()+1
    # A PyCharm suppression comment applies to the following statement/suite.
    # Read comments through tokenize so string content cannot disable checks.
    if 'noinspection' not in source:
        return issues
    lexical = source_tokens(source) if tokens is None else tokens
    comments = (token for token in lexical if token.type == tokenize.COMMENT)
    try: statements = sorted((n for n in ast.walk(tree if tree is not None else ast.parse(source)) if isinstance(n,ast.stmt)), key=lambda n:(n.lineno,n.col_offset))
    except SyntaxError: statements=[]
    suppressed=[]
    for comment in comments:
        match=re.match(r'#\s*noinspection\s+(.+)',comment.string)
        if not match: continue
        next_statement=next((n for n in statements if n.lineno>comment.end[0]),None)
        if next_statement and not any(row.strip() and not row.lstrip().startswith('#') for row in lines[comment.end[0]:next_statement.lineno-1]):
            suppressed.append((next_statement.lineno,next_statement.end_lineno,set(re.split(r'[,\s]+',match[1].strip()))))
    return [d for d in issues if (d.get('engine') == 'CPython' and d['severity']=='error') or
        not any(start<=d['line']<=end and (d.get('inspection') in names or 'ALL' in names) for start,end,names in suppressed)]
