"""Managed offline Jedi runtime. No learner-module execution or pip setup."""
import hashlib
import os
from pathlib import Path
import shutil
import sys
import tempfile
import zipfile

_engine = None


def engine():
    global _engine
    if _engine is not None:
        return _engine
    wheels = sorted((Path(__file__).parent / 'vendor').glob('*.whl'))
    if len(wheels) != 2:
        raise RuntimeError('离线 Python 分析组件不完整')
    digest = hashlib.sha256(b''.join(p.read_bytes() for p in wheels)).hexdigest()[:12]
    cache = Path.home() / ('Library/Caches' if sys.platform == 'darwin' else '.cache') / 'Pyvis' / 'python-analysis'
    cache.mkdir(parents=True, exist_ok=True)
    target = cache / digest
    if not (target / 'jedi/__init__.py').is_file():
        stage = Path(tempfile.mkdtemp(prefix='extract-', dir=cache))
        try:
            for wheel in wheels:
                with zipfile.ZipFile(wheel) as archive:
                    archive.extractall(stage)
            try:
                os.rename(stage, target)
            except OSError:
                if not (target / 'jedi/__init__.py').is_file():
                    raise
        finally:
            if stage.exists():
                shutil.rmtree(stage)
    sys.path.insert(0, str(target))
    import jedi
    jedi.settings.auto_import_modules = []
    jedi.settings.cache_directory = str(cache / 'jedi-cache')
    _engine = jedi
    return jedi


def complete(source, filename, line, column, project=None):
    jedi = engine()
    root = Path(project) if project else Path(filename).parent
    workspace = jedi.Project(str(root), load_unsafe_extensions=False, smart_sys_path=False, added_sys_path=[str(root)])
    script = jedi.Script(code=source, path=filename, project=workspace)
    completions = []
    candidates = script.complete(line, column, fuzzy=True)
    import re
    prefix = re.search(r'[\w]+$', source.split('\n')[line - 1][:column])
    if prefix:
        exact_prefix = [c for c in candidates if c.name.lower().startswith(prefix[0].lower())]
        if exact_prefix:
            candidates = exact_prefix
    candidates.sort(key=lambda c: (c.module_name != Path(filename).stem,
        c.name.startswith('_'), c.type == 'keyword'))
    for candidate in candidates[:60]:
        detail = candidate.description
        has_parameters = True
        if candidate.type in ('function', 'class'):
            try:
                signatures = candidate.get_signatures()
                if signatures:
                    detail = signatures[0].to_string()
                    has_parameters = bool(signatures[0].params)
            except (ValueError, AttributeError):
                pass
        completions.append(dict(name=candidate.name, kind={
            'function': '函数', 'class': '类', 'module': '模块',
            'param': '参数', 'keyword': '关键字', 'instance': '变量',
        }.get(candidate.type, '变量'), detail=detail,
            origin=candidate.module_name or '', has_parameters=has_parameters, start=0, end=0))
    signatures = []
    for signature in script.get_signatures(line, column):
        signatures.append(dict(text=signature.to_string(), index=signature.index,
                               parameters=[p.to_string() for p in signature.params], name=signature.name))
    from .code_intelligence import recovered_tree, symbols_for
    symbols, members = symbols_for(recovered_tree(source))
    known = {'dict','list','tuple','set','str','range','int','bool'}
    unresolved = [s for s in symbols if s['kind'] in ('变量','参数') and s['detail'] not in known and s.get('line',0) <= line]
    if unresolved:
        definitions = script.get_names(all_scopes=True, definitions=True, references=False)
        for symbol in unresolved[:40]:
            matches = [n for n in definitions if n.name == symbol['name'] and n.line == symbol.get('line')]
            for definition in matches:
                try:
                    inferred = definition.infer()
                    kinds = {n.name for n in inferred if n.type == 'instance'}
                    if len(kinds) == 1 and kinds <= known: symbol['detail'] = kinds.pop()
                except (ValueError, AttributeError):
                    pass
    return dict(completions=completions, signatures=signatures, engine='Jedi', context=dict(symbols=symbols, members=members))


def symbol_info(source, filename, line, column, project=None, action='definition', candidate=None):
    jedi = engine()
    root = Path(project) if project else Path(filename).parent
    workspace = jedi.Project(str(root), load_unsafe_extensions=False, smart_sys_path=False, added_sys_path=[str(root)])
    script = jedi.Script(code=source, path=filename, project=workspace)
    names = [c for c in script.complete(line,column,fuzzy=True) if c.name==candidate] if candidate else []
    if not names: names = script.goto(line, column, follow_imports=True)
    if not names:
        names = script.infer(line, column)
    definitions, documentation = [], []
    for name in names[:12]:
        if name.module_path and name.line:
            definitions.append(dict(file=str(name.module_path), line=name.line,
                column=(name.column or 0) + 1, name=name.full_name or name.name))
        if action == 'documentation':
            signatures = [signature.to_string() for signature in name.get_signatures()[:8]]
            body = name.docstring(raw=True)[:12000]
            documentation.append(dict(name=name.full_name or name.name,
                description=name.description, signatures=signatures, body=body,
                text=name.docstring()[:12000]))
    return dict(definitions=definitions, documentation=documentation)


def rename_variable(source, filename, line, column, new_name=None):
    """Rename references to a variable in the current editor buffer."""
    import keyword
    jedi = engine()
    path = Path(filename).resolve()
    script = jedi.Script(code=source, path=path)
    definitions = script.goto(line, column)
    if not definitions or any(d.module_path != path or d.type not in ('statement', 'param')
                              for d in definitions):
        raise ValueError('请将光标放在当前文件定义的变量或参数上')
    old = definitions[0].name
    refs = sorted({(r.line, r.column) for r in script.get_references(line, column, scope='file')
                   if r.module_path == path and r.name == old})
    if not any(row == line and start <= column <= start + len(old) for row, start in refs):
        raise ValueError('当前位置没有可重命名的变量')
    if new_name is None:
        return dict(name=old, count=len(refs))
    if not new_name.isidentifier() or keyword.iskeyword(new_name) or new_name == '__debug__':
        raise ValueError('请输入有效的 Python 变量名')
    lines = source.split('\n')
    expected = set()
    delta = len(new_name) - len(old)
    shifts = {}
    for row, start in refs:
        if lines[row-1][start:start+len(old)] != old:
            raise ValueError('源码位置已变化，请重新选择变量')
        expected.add((row, start + shifts.get(row, 0)))
        shifts[row] = shifts.get(row, 0) + delta
    for row, start in reversed(refs):
        text = lines[row-1]
        lines[row-1] = text[:start] + new_name + text[start+len(old):]
    result = '\n'.join(lines)
    updated = jedi.Script(code=result, path=path)
    first = min(expected)
    bound = {(r.line, r.column) for r in updated.get_references(*first, scope='file')
             if r.module_path == path and r.name == new_name}
    if bound != expected:
        raise ValueError('新名称与现有变量冲突，请选择其他名称')
    return dict(source=result, count=len(refs))
