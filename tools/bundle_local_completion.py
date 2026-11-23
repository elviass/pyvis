"""Embed local FIM inference inside the signed sandboxed macOS application."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def bundle(repo, helpers, identity, architectures):
    manifest = json.loads((repo / 'tools/local_completion_manifest.json').read_text())
    cache = repo / 'runtime/local_completion'
    model = manifest['model']
    source_model = cache / model['filename']
    if not source_model.exists():
        raise RuntimeError('Run python3 tools/prepare_local_completion.py before building')
    if digest(source_model) != model['sha256']:
        raise RuntimeError('Local completion model checksum mismatch')
    resources = helpers.parent / 'Resources/Models'
    resources.mkdir(parents=True, exist_ok=True)
    target_model = resources / model['filename']
    if not target_model.exists() or digest(target_model) != model['sha256']:
        shutil.copyfile(source_model, target_model)
    (resources / 'qwen2.5-coder-1.5b-q8_0.gguf').unlink(missing_ok=True)
    destination = helpers / 'local-completion'
    destination.mkdir(exist_ok=True)
    slices = {}
    for arch in architectures:
        key = 'macos-arm64' if arch == 'arm64' else 'macos-x64'
        record = manifest['servers'][key]
        archive = cache / record['url'].rsplit('/', 1)[1]
        if not archive.exists() or digest(archive) != record['sha256']:
            raise RuntimeError('Run tools/prepare_local_completion.py --platform ' + key)
        # Re-extract the verified archive instead of trusting mutable cache files.
        import tarfile
        import tempfile
        with tempfile.TemporaryDirectory(prefix='pyvis-inference-') as temporary:
            with tarfile.open(archive) as package:
                package.extractall(temporary)
            root = Path(temporary) / ('llama-' + manifest['version'])
            queue, seen = ['llama-server'], set()
            while queue:
                name = queue.pop()
                if name in seen:
                    continue
                seen.add(name)
                source = root / name
                dependencies = subprocess.check_output(['/usr/bin/otool', '-L', str(source)], text=True)
                queue.extend(re.findall(r'@rpath/([^\s]+\.dylib)', dependencies))
                slices.setdefault(name, []).append(source.read_bytes())
    for name, binaries in slices.items():
        target = destination / name
        if len(binaries) == 1:
            target.write_bytes(binaries[0])
        else:
            import tempfile
            with tempfile.TemporaryDirectory(prefix='pyvis-inference-fat-') as temporary:
                paths = []
                for i, data in enumerate(binaries):
                    path = Path(temporary) / str(i)
                    path.write_bytes(data)
                    paths.append(str(path))
                subprocess.run(['/usr/bin/lipo', '-create', *paths, '-output', str(target)], check=True)
        target.chmod(0o755)
    for target in sorted(destination.iterdir(), key=lambda path: path.name == 'llama-server'):
        command = ['/usr/bin/codesign', '--force', '--sign', identity, '--timestamp=none']
        # Match Xcode's parent signing mode. Ad-hoc Debug apps have no Team ID;
        # adding hardened-runtime to just the helper would reject their dylibs.
        # A distribution identity retains hardened runtime and library validation.
        if identity != '-':
            command += ['--options', 'runtime']
        if target.name == 'llama-server':
            command += ['--entitlements', str(repo / 'client/macos/Runner/EditorTool.entitlements')]
        subprocess.run([*command, str(target)], check=True)
