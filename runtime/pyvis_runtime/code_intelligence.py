"""Offline editor analysis with CPython, AST and managed static tools; never execute learner code."""
import ast
from collections import deque
from .local_imports import import_candidates
from .source_encoding import source_tokens
import base64
import builtins
import inspect
import json
import keyword
from pathlib import Path
import symtable
import sys
import warnings


def hint_for(message):
    if "expected ':'" in message:
        return '检查 if、for、while、def 等语句末尾是否缺少冒号。'
    if 'indent' in message or 'tabs and spaces' in message:
        return '同一代码块保持一致缩进；建议使用四个空格，避免混用 Tab。'
    if 'never closed' in message or 'unmatched' in message:
        return '检查括号是否成对，以及字符串引号是否闭合。'
    if 'unterminated' in message:
        return '检查字符串两端的引号；跨行字符串需要三引号。'
    if 'outside' in message or 'not properly in loop' in message:
        return '检查该语句的位置：return 需要在函数中，break 和 continue 需要在循环中。'
    return '检查标记位置及上一行的冒号、括号、引号和缩进。'


def issue(filename, line, column, message, severity='error', code='SyntaxError', hint='', end_line=None, end_column=None):
    return dict(file=filename, line=max(1, line or 1), column=max(1, column or 1),
                severity=severity, code=code, message=message, hint=hint, end_line=end_line or line or 1, end_column=end_column or column or 1, engine='CPython', blocking=severity == 'error', fixes=[])


def compile_check(source, filename):
    result = []
    with warnings.catch_warnings(record=True) as captured:
        warnings.simplefilter('always', SyntaxWarning)
        try:
            compile(source, filename, 'exec', dont_inherit=True)
        except (SyntaxError, ValueError) as exc:
            message = getattr(exc, 'msg', str(exc))
            result.append(issue(filename, getattr(exc, 'lineno', 1), getattr(exc, 'offset', 1),
                                message, code=type(exc).__name__, hint=hint_for(message),
                                end_line=getattr(exc, 'end_lineno', None), end_column=getattr(exc, 'end_offset', None)))
        for warning in captured:
            result.append(issue(filename, warning.lineno, 1, str(warning.message), 'warning',
                                warning.category.__name__, '检查此处的运算符或字符串写法。'))
    return result


def recovered_tree(source):
    try:
        return ast.parse(source)
    except (SyntaxError, ValueError) as exc:
        lines = source.splitlines()
        line = getattr(exc, 'lineno', len(lines)) or len(lines)
        prefix = lines[:max(0, line - 1)]
        for _ in range(5):
            text = '\n'.join(prefix)
            last = prefix[-1] if prefix else ''
            indent = len(last) - len(last.lstrip()) + (4 if last.rstrip().endswith(':') else 0)
            try:
                return ast.parse(text + '\n' + ' ' * indent + 'pass\n')
            except (SyntaxError, ValueError):
                if not prefix:
                    break
                prefix.pop()
    return ast.Module(body=[], type_ignores=[])


def prompt(name, kind='变量', detail='', start=0, end=0):
    return dict(name=name, kind=kind, detail=detail, start=start, end=end)


MEMBERS = {
    'list': 'append extend insert pop remove clear index count sort reverse copy',
    'dict': 'get keys values items update pop popitem setdefault clear copy fromkeys',
    'str': 'strip lstrip rstrip split rsplit join replace lower upper title capitalize startswith endswith find index count isdigit isalpha format',
    'set': 'add update remove discard pop clear union intersection difference copy',
    'tuple': 'count index',
    'math': 'sqrt floor ceil sin cos tan log log10 exp pow fabs gcd isfinite pi e tau inf',
    'random': 'randint randrange choice choices sample shuffle random uniform seed',
    'time': 'sleep time monotonic perf_counter',
}
BUILTINS = []
for name in dir(builtins):
    if name.startswith('_'):
        continue
    value = getattr(builtins, name)
    detail = ''
    if callable(value):
        try:
            detail = f'{name}{inspect.signature(value)}'
        except (ValueError, TypeError):
            detail = name + '(…)'
    BUILTINS.append(prompt(name, '内置函数' if callable(value) else '内置值', detail))
BUILTINS.extend(prompt(name, '关键字') for name in keyword.kwlist)


def symbols_for(tree):
    symbols, members = [], {}

    def collect(body, start=0, end=0, inherited=None):
        types = dict(inherited or {})
        def infer(value):
            if isinstance(value, (ast.List, ast.ListComp)): return 'list'
            if isinstance(value, (ast.Dict, ast.DictComp)): return 'dict'
            if isinstance(value, (ast.Set, ast.SetComp)): return 'set'
            if isinstance(value, ast.Tuple): return 'tuple'
            if isinstance(value, ast.Constant):
                if isinstance(value.value, bool): return 'bool'
                if isinstance(value.value, str): return 'str'
                if isinstance(value.value, int): return 'int'
            if isinstance(value, ast.Name): return types.get(value.id)
            if isinstance(value, ast.Call) and isinstance(value.func, ast.Name): return value.func.id
            return None

        def annotation_type(annotation):
            if isinstance(annotation, ast.Subscript): return annotation_type(annotation.value)
            if isinstance(annotation, ast.Name): name = annotation.id.lower()
            elif isinstance(annotation, ast.Attribute): name = annotation.attr.lower()
            else: return ''
            return {'mapping':'dict', 'sequence':'list', 'iterable':'list'}.get(name, name)

        class Visitor(ast.NodeVisitor):
            def visit_FunctionDef(self, node):
                symbols.append(prompt(node.name, '函数', f'{node.name}({ast.unparse(node.args)})', start, end))
                first, last = node.lineno, node.end_lineno
                for arg in [*node.args.posonlyargs, *node.args.args, *node.args.kwonlyargs,
                            *([node.args.vararg] if node.args.vararg else []),
                            *([node.args.kwarg] if node.args.kwarg else [])]:
                    item = prompt(arg.arg, '参数', annotation_type(arg.annotation), first, last)
                    item['line'] = arg.lineno
                    symbols.append(item)
                collect(node.body, first, last, types)
            visit_AsyncFunctionDef = visit_FunctionDef
            def visit_ClassDef(self, node):
                symbols.append(prompt(node.name, '类', node.name, start, end))
                members[node.name] = [prompt(n.name, '方法', f'{n.name}({ast.unparse(n.args)})')
                                      for n in node.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))]
                collect(node.body, node.lineno, node.end_lineno, types)
            def visit_Name(self, node):
                if isinstance(node.ctx, ast.Store):
                    item = prompt(node.id, '变量', types.get(node.id, ''), start, end)
                    item['line'] = node.lineno
                    symbols.append(item)
            def visit_Assign(self, node):
                kind = infer(node.value)
                for target in node.targets:
                    if isinstance(target, ast.Name) and kind:
                        types[target.id] = kind
                self.generic_visit(node)
            def visit_AnnAssign(self, node):
                kind = infer(node.value)
                if isinstance(node.target, ast.Name) and kind:
                    types[node.target.id] = kind
                self.generic_visit(node)
            def visit_Import(self, node):
                for alias in node.names:
                    name = alias.asname or alias.name.split('.')[0]
                    types[name] = alias.name
                    symbols.append(prompt(name, '模块', alias.name, start, end))
            def visit_ImportFrom(self, node):
                for alias in node.names:
                    if alias.name != '*':
                        symbols.append(prompt(alias.asname or alias.name, '导入', node.module or '', start, end))
        visitor = Visitor()
        for node in body:
            visitor.visit(node)
        for name, kind in types.items():
            if kind in MEMBERS:
                members.setdefault(name, []).extend(prompt(n, '方法' if n not in ('pi', 'e', 'tau', 'inf') else '常量',
                                                           f'{name}.{n}' + ('' if n in ('pi', 'e', 'tau', 'inf') else '(…)'), start, end)
                                                     for n in MEMBERS[kind].split())
            elif kind in members:
                members.setdefault(name, []).extend(members[kind])
    collect(tree.body)
    unique = {(s['name'], s['start'], s['end']): s for s in symbols}
    return list(unique.values()), members


COMMON_IMPORTS = {
    'Path': ('pathlib', 'Path'), 'Decimal': ('decimal', 'Decimal'),
    'datetime': ('datetime', 'datetime'), 'date': ('datetime', 'date'),
    'timedelta': ('datetime', 'timedelta'), 'Counter': ('collections', 'Counter'),
    'defaultdict': ('collections', 'defaultdict'), 'deque': ('collections', 'deque'),
    'sqrt': ('math', 'sqrt'), 'randint': ('random', 'randint'), 'choice': ('random', 'choice'),
}


def import_suggestion(source, filename, name, tree):
    if name in COMMON_IMPORTS:
        module, symbol = COMMON_IMPORTS[name]
        statement = f'from {module} import {symbol}\n'
    elif name in sys.stdlib_module_names or (Path(filename).parent / (name + '.py')).is_file():
        statement = f'import {name}\n'
    else:
        return []
    after = 0
    for node in tree.body:
        if (isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str)) or (
                isinstance(node, ast.ImportFrom) and node.module == '__future__'):
            after = node.end_lineno
        else:
            break
    lines = source.split('\n')
    # Preserve a shebang and encoding comment before imports.
    while after < min(2, len(lines)) and (lines[after].startswith('#!') or 'coding' in lines[after] and lines[after].lstrip().startswith('#')):
        after += 1
    if any(isinstance(n, ast.Name) and n.id == name and isinstance(n.ctx, ast.Load) and n.lineno <= after for n in ast.walk(tree)):
        return []
    location = dict(row=after + 1, column=1)
    return [dict(title=f'导入 {name}', applicability='safe', edits=[dict(
        content=statement, location=location, end_location=location)])]


def unknown_names(source, filename, tree):
    # Dynamic namespace changes cannot be resolved without executing user code.
    if any((isinstance(n, ast.ImportFrom) and any(a.name == '*' for a in n.names)) or
           (isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id in ('exec', 'eval', 'globals', 'locals'))
           for n in ast.walk(tree)):
        return []
    table = symtable.symtable(source, filename, 'exec')
    defined = set(dir(builtins)) | {'__name__', '__file__', '__package__', '__doc__', '__annotations__', '__builtins__', '__spec__', '__loader__', '__cached__'}
    defined.update(s.get_name() for s in table.get_symbols() if s.is_assigned() or s.is_imported() or s.is_namespace())
    unresolved = set()
    def visit(scope):
        unresolved.update(s.get_name() for s in scope.get_symbols()
                          if s.is_referenced() and s.is_global() and s.get_name() not in defined)
        for child in scope.get_children(): visit(child)
    visit(table)
    seen, result = set(), []
    for node in ast.walk(tree):
        if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load) and node.id in unresolved and node.id not in seen:
            seen.add(node.id)
            # AST columns are UTF-8 byte offsets, editor columns are characters.
            line = source.splitlines()[node.lineno - 1]
            column = len(line.encode('utf-8')[:node.col_offset].decode('utf-8')) + 1
            diagnostic = issue(filename, node.lineno, column, f'未找到名称 {node.id}', 'warning', 'UndefinedName',
                               '检查拼写、定义位置和导入。动态创建的名称可能无法静态判断；此提示不阻止运行。', end_line=node.lineno, end_column=column + len(node.id))
            diagnostic['fixes'] = import_suggestion(source, filename, node.id, tree)
            result.append(diagnostic)
    return result


def bracket_pairs(source, tokens=None):
    import tokenize
    stack, result = [], []
    closing = {')': '(', ']': '[', '}': '{'}
    for token in source_tokens(source) if tokens is None else tokens:
        if token.type != tokenize.OP:
            continue
        if token.string in '([{':
            stack.append(token)
        elif token.string in closing and stack and stack[-1].string == closing[token.string]:
            opening = stack.pop()
            result.append(dict(start=list(opening.start), end=list(token.start)))
    return result


def analyze(source, filename, project=None, inspections=True, buffers=None, dictionary=()):
    diagnostics = compile_check(source, filename)
    valid = not any(d['severity'] == 'error' for d in diagnostics)
    tree = recovered_tree(source)
    tokens = tuple(source_tokens(source))
    if valid:
        diagnostics.extend(unknown_names(source, filename, tree))
    failures = []
    if inspections and sys.platform != 'android' and valid:
        from .editor_tools import inspect_source
        extra, failures = inspect_source(source, filename, project or str(Path(filename).parent), buffers)
        diagnostics.extend(extra)
    if inspections:
        from .spelling import inspect_spelling
        diagnostics.extend(inspect_spelling(source, filename, dictionary, tokens))
    from .inspection_presentation import apply_presentation
    diagnostics = apply_presentation(diagnostics, source, tree if valid else None, tokens)
    diagnostics.sort(key=lambda d: (d['line'], d['column'], d['code']))
    symbols, members = symbols_for(tree)
    return dict(diagnostics=diagnostics, symbols=symbols, members=members, builtins=BUILTINS,
                inspection_failures=failures, brackets=bracket_pairs(source, tokens), engines=['CPython', 'Jedi'] + ([] if sys.platform == 'android' else ['Ruff', 'ty']))


def check_sources(sources, entry=None, project=None, source_errors=None, *, discover_imports=False):
    sources = {str(Path(name)): source for name, source in sources.items()}
    source_errors = {str(Path(name)): error for name, error in (source_errors or {}).items()}
    pending = deque([*sources, *source_errors] if entry is None else [str(Path(entry))])
    root = Path(project) if project else Path(entry or '.').parent
    visited, diagnostics, dependencies = set(), [], {}
    while pending:
        filename = pending.popleft()
        if filename in visited: continue
        visited.add(filename)
        if filename in source_errors:
            diagnostics.append(issue(filename, 1, 1, source_errors[filename], code='SourceReadError'))
            continue
        if filename not in sources:
            diagnostics.append(issue(filename, 1, 1, '入口文件不在当前源码快照中', code='MissingEntry'))
            continue
        source = sources[filename]
        errors = compile_check(source, filename)
        diagnostics.extend(errors)
        if any(d['severity'] == 'error' for d in errors): continue
        tree = ast.parse(source)
        diagnostics.extend(unknown_names(source, filename, tree))
        if entry is None and not discover_imports: continue
        for candidate in import_candidates(tree, Path(filename), root):
            name = str(candidate)
            if discover_imports:
                dependencies[name] = None
            elif name not in visited and (name in sources or name in source_errors):
                pending.append(name)
    result = dict(diagnostics=diagnostics, checked=sorted(visited))
    if discover_imports:
        result['dependencies'] = list(dependencies)
    return result


def main():
    for line in sys.stdin:
        request_id = None
        try:
            request = json.loads(line)
            if not isinstance(request, dict):
                raise ValueError('请求必须是 JSON 对象')
            request_id = request.get('id')
            if request.get('action') == 'format':
                from .editor_tools import format_source
                result = dict(source=format_source(request['source'], request['filename'], request.get('imports', False), request.get('selection')))
            elif request.get('action') == 'rename':
                from .semantic_analysis import rename_variable
                result = rename_variable(request['source'], request['filename'], request['line'],
                                         request['column'], request.get('candidate'))
            elif request.get('action') in ('definition', 'documentation'):
                from .semantic_analysis import symbol_info
                result = symbol_info(request.get('source', ''), request['filename'], request['line'],
                                     request['column'], request.get('project'), request['action'], request.get('candidate'))
            elif request.get('action') == 'complete':
                from .semantic_analysis import complete
                result = complete(request.get('source', ''), request.get('filename', '<editor>.py'),
                                  request['line'], request['column'], request.get('project'))
            elif request.get('action') == 'validate_inline':
                from .inline_validation import validate_inline
                result = validate_inline(request['source'], request['line'], request['column'], request['prediction'])
            elif request.get('action') == 'check':
                result = check_sources(request['sources'], request.get('entry'), request.get('project'), request.get('source_errors'))
            elif request.get('action') == 'check_project':
                result = check_sources(request['sources'], project=request['project'],
                                       source_errors=request.get('source_errors'), discover_imports=True)
            elif request.get('action') == 'decode_source':
                from .source_encoding import decode_source
                source, encoding = decode_source(base64.b64decode(request['data']))
                result = dict(source=source, encoding=encoding)
            elif request.get('action') == 'convert_source':
                from .source_encoding import convert_source
                result = dict(source=convert_source(request['source'], request['encoding']))
            elif request.get('action') == 'encode_source':
                from .source_encoding import encode_source
                data = encode_source(request['source'], request['encoding'])
                result = dict(data=base64.b64encode(data).decode('ascii'))
            else:
                result = analyze(request.get('source', ''), request.get('filename', '<editor>'), request.get('project'), buffers=request.get('buffers'), dictionary=request.get('dictionary', ()))
            result['id'] = request_id
            print(json.dumps(result, ensure_ascii=False), flush=True)
        except Exception as exc:
            print(json.dumps({'id': request_id, 'error': f'{type(exc).__name__}: {exc}'}, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()
