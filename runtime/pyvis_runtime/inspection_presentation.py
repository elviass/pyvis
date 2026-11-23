"""Presentation categories corresponding to PyCharm inspection attributes.

See docs/pycharm-source-reference.md for scheme and inspection sources.
"""
import re
import ast
import io
import tokenize


def apply_presentation(issues, source):
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
    comments = []
    try:
        for token in tokenize.generate_tokens(io.StringIO(source).readline):
            if token.type == tokenize.COMMENT: comments.append(token)
    except (tokenize.TokenError, IndentationError, SyntaxError): pass
    try: statements = sorted((n for n in ast.walk(ast.parse(source)) if isinstance(n,ast.stmt)), key=lambda n:(n.lineno,n.col_offset))
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
