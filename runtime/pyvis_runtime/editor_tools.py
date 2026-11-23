"""Managed offline editor tools, separate from execution of learner programs."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urlparse
from urllib.request import url2pathname
import zipfile
from .source_encoding import convert_source, decode_source

VENDOR = Path(__file__).parent / 'vendor' / 'tools'


def executable(name):
    embedded = os.environ.get('PYVIS_EDITOR_TOOLS')
    if sys.platform == 'darwin' and embedded:
        binary = Path(embedded) / name
        if not binary.is_file():
            raise RuntimeError(f'应用内缺少已签名的 {name} 分析组件')
        return str(binary)
    machine = platform.machine().lower()
    if sys.platform == 'darwin':
        tag = 'macosx_11_0_arm64' if machine in ('arm64', 'aarch64') else 'macosx_10_12_x86_64'
    elif sys.platform == 'win32' and machine in ('amd64', 'x86_64'):
        tag = 'win_amd64'
    else:
        raise RuntimeError(f'此平台尚未打包 {name} 分析组件')
    manifest = json.loads((VENDOR / 'manifest.json').read_text())
    record = next(x for x in manifest if x['filename'].startswith(name + '-') and tag in x['filename'])
    wheel = VENDOR / record['filename']
    digest = record['sha256']
    cache = Path.home() / ('Library/Caches' if sys.platform == 'darwin' else '.cache') / 'Pyvis' / 'editor-tools'
    target = cache / (name + '-' + digest[:12])
    suffix = '.exe' if sys.platform == 'win32' else ''
    candidates = [p for p in target.rglob(name + suffix) if p.is_file()] if target.exists() else []
    if not candidates:
        if hashlib.sha256(wheel.read_bytes()).hexdigest() != digest:
            raise RuntimeError(f'{name} 离线组件校验失败')
        cache.mkdir(parents=True, exist_ok=True)
        stage = Path(tempfile.mkdtemp(prefix=name + '-', dir=cache))
        try:
            with zipfile.ZipFile(wheel) as archive:
                archive.extractall(stage)
            for file in stage.rglob(name + suffix):
                file.chmod(file.stat().st_mode | 0o700)
            try:
                os.rename(stage, target)
            except OSError:
                if not target.exists():
                    raise
        finally:
            if stage.exists(): shutil.rmtree(stage)
        candidates = [p for p in target.rglob(name + suffix) if p.is_file()]
    if not candidates:
        raise RuntimeError(f'{name} 离线组件缺少可执行文件')
    return str(candidates[0])


def run(name, args, source=None, cwd=None):
    env = dict(os.environ, NO_COLOR='1', RAYON_NUM_THREADS='2', TY_MAX_PARALLELISM='2')
    for key in ['VIRTUAL_ENV', 'CONDA_PREFIX', 'TY_CONFIG_FILE', 'RUFF_CONFIG_FILE']:
        env.pop(key, None)
    result = subprocess.run([executable(name), *args], input=source, text=True,
                            encoding='utf-8', capture_output=True, cwd=cwd, env=env,
                            timeout=6, creationflags=subprocess.CREATE_NO_WINDOW if sys.platform == 'win32' else 0)
    if result.returncode not in (0, 1):
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f'{name} 未能完成分析')
    return result.stdout


def format_source(source, filename, imports=False, selection=None):
    if imports:
        return run('ruff', ['check', '--isolated', '--no-cache', '--select', 'I,F401', '--fix',
                            '--exit-zero', '--stdin-filename', filename, '-'], source)
    args = ['format', '--isolated', '--config', "format.quote-style='preserve'", '--stdin-filename', filename]
    if selection: args += ['--range', selection]
    return run('ruff', [*args, '-'], source)


def lint(source, filename):
    records = json.loads(run('ruff', ['check', '--isolated', '--no-cache', '--output-format', 'json',
        '--select', 'E4,E7,E9,F,W291,W293', '--ignore', 'F821', '--stdin-filename', filename, '-'], source))
    result = []
    hints = {'F401': '删除未使用的导入，或在后续代码中使用它。',
             'F841': '检查变量是否需要使用；也可以去掉无用的赋值。',
             'F811': '检查此名称是否重复定义，避免覆盖前面的定义。',
             'F823': '函数内给名称赋值后，它通常被视为局部变量；检查赋值与读取的顺序。',
             'E722': '说明要捕获的异常类型，避免掩盖意外错误。'}
    for item in records:
        code = item['code'] or 'SyntaxError'
        if code == 'SyntaxError': continue
        loc, end = item['location'], item['end_location']
        fix = item.get('fix')
        result.append(dict(file=filename, line=loc['row'], column=loc['column'],
            end_line=end['row'], end_column=end['column'], code=code, engine='Ruff',
            severity='weak_warning' if code in ('F401','F841') or code.startswith(('E2','E3','W')) else 'warning',
            message=item['message'], hint=hints.get(code, '检查标记处的写法、空白和名称使用。'),
            blocking=False, fixes=[] if not fix else [dict(title=fix['message'], edits=fix['edits'],
                applicability=fix.get('applicability', 'unsafe'))]))
    return result


def write_snapshot(folder, source, filename, project=None, buffers=None):
    import ast
    root = Path(project).resolve() if project and Path(project).is_dir() else Path(filename).resolve().parent
    active = Path(filename).resolve()
    overlays = {str(Path(k).resolve()): v for k, v in (buffers or {}).items()}
    overlays[str(active)] = source
    pending, visited = [active], set()
    def include(base, module):
        parts = module.split('.') if module else []
        for count in range(1, len(parts) + 1):
            path = base.joinpath(*parts[:count])
            for candidate in (path.with_suffix('.py'), path.with_suffix('.pyi'), path / '__init__.py'):
                if str(candidate) in overlays or candidate.is_file(): pending.append(candidate)
    while pending:
        path = pending.pop(0).resolve()
        if path in visited: continue
        visited.add(path)
        try: relative = path.relative_to(root)
        except ValueError:
            if path != active: continue
            relative = Path(path.name)
        text = overlays.get(str(path))
        if text is None:
            text, _ = decode_source(path.read_bytes())
            text = text.replace('\r\n', '\n').replace('\r', '\n')
        target = Path(folder) / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(convert_source(text, 'utf-8'), encoding='utf-8')
        # Package markers and their imports also participate in resolution.
        parent = path.parent
        while parent != root and root in parent.parents:
            marker = parent / '__init__.py'
            if marker != path and marker.is_file(): pending.append(marker)
            parent = parent.parent
        if len(visited) > 500:
            raise RuntimeError('本地依赖超过单次检查范围')
        try: tree = ast.parse(text)
        except SyntaxError: continue
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for alias in node.names: include(root, alias.name)
            elif isinstance(node, ast.ImportFrom):
                base = path.parent if node.level else root
                for _ in range(max(0, node.level - 1)): base = base.parent
                include(base, node.module)
                for alias in node.names:
                    if alias.name != '*': include(base, '.'.join(filter(None, [node.module, alias.name])))
    try: relative = active.relative_to(root)
    except ValueError: relative = Path(active.name)
    return Path(folder) / relative


def type_check(source, filename, project=None, buffers=None):
    # Check a disposable snapshot, not the saved file. Imported local modules are
    # copied with package paths and unsaved overlays, parsed statically, never executed.
    with tempfile.TemporaryDirectory(prefix='pyvis-inspection-') as folder:
        snapshot = write_snapshot(folder, source, filename, project, buffers)
        config = Path(folder) / 'ty.toml'
        config.write_text('[environment]\npython-version = "' + '.'.join(map(str, sys.version_info[:2])) + '"\n', encoding='utf-8')
        args = ['check', '--config-file', str(config), '--output-format', 'sarif', '--no-progress',
                '--python', sys.executable]
        args += ['--project', folder]
        args.append(str(snapshot))
        report = json.loads(run('ty', args, cwd=folder))
        result = []
        hints = {'unresolved-reference': '检查名称的拼写、定义位置和当前作用域。',
                 'unresolved-import': '检查模块名、项目中的文件位置，以及软件是否提供该学习库。',
                 'import-not-found': '检查模块名、项目中的文件位置，以及软件是否提供该学习库。',
                 'invalid-argument-type': '比较实际传入的值与参数要求的类型。',
                 'missing-argument': '检查调用是否传入了所有必需参数。',
                 'too-many-positional-arguments': '比较调用中的实参数量与函数的参数定义。',
                 'unknown-argument': '检查关键字参数的名称是否与函数定义一致。',
                 'missing-attribute': '检查该对象的数据类型，以及它是否具有此属性或方法。',
                 'invalid-assignment': '检查赋值右侧的数据类型是否满足变量的类型声明。',
                 'unsupported-operator': '检查两个操作数的类型，以及它们是否支持此运算。',
                 'possibly-unresolved-reference': '检查该变量是否在每条可能到达此处的路径上都有赋值。'}
        for run_report in report.get('runs', []):
            for item in run_report.get('results', []):
                locations = item.get('locations', [])
                if not locations: continue
                physical = locations[0].get('physicalLocation', {})
                uri = physical.get('artifactLocation', {}).get('uri', '')
                if uri:
                    artifact = Path(url2pathname(urlparse(uri).path))
                    if not artifact.is_absolute(): artifact = Path(folder) / artifact
                    if artifact.resolve() != snapshot.resolve(): continue
                region = physical.get('region', {})
                code = item.get('ruleId', 'TypeCheck')
                # Avoid a duplicate of the existing conservative name check.
                if code == 'unresolved-reference': continue
                level = item.get('level', 'warning')
                result.append(dict(file=filename, line=region.get('startLine', 1),
                    column=region.get('startColumn', 1), end_line=region.get('endLine', region.get('startLine', 1)),
                    end_column=region.get('endColumn', region.get('startColumn', 1) + 1),
                    severity='error' if level == 'error' else 'warning', code=code,
                    message=item.get('message', {}).get('text', ''), hint=hints.get(code, '结合对象类型、函数声明和当前执行路径检查标记处。'),
                    engine='ty', blocking=False, fixes=[]))
        return result


def inspect_source(source, filename, project=None, buffers=None):
    diagnostics, failures = [], []
    with ThreadPoolExecutor(2) as pool:
        futures = [('Ruff', pool.submit(lint, source, filename)),
                   ('ty', pool.submit(type_check, source, filename, project, buffers))]
        for name, future in futures:
            try: diagnostics.extend(future.result())
            except Exception as error: failures.append(f'{name}: {error}')
    return diagnostics, failures
