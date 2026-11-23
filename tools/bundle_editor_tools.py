"""Embed verified macOS analyzer executables before Xcode signs the parent app."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile

repo = Path(__file__).resolve().parents[1]
vendor = repo / 'runtime/pyvis_runtime/vendor/tools'
records = json.loads((vendor / 'manifest.json').read_text())
helpers = Path(os.environ['TARGET_BUILD_DIR']) / os.environ['CONTENTS_FOLDER_PATH'] / 'Helpers'
helpers.mkdir(parents=True, exist_ok=True)
identity = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') or '-'
architectures = os.environ.get('ARCHS', 'arm64').split()
with tempfile.TemporaryDirectory(prefix='pyvis-tools-build-') as directory:
    for name in ['ruff', 'ty']:
        slices = []
        for arch in architectures:
            tag = 'macosx_11_0_arm64' if arch == 'arm64' else 'macosx_10_12_x86_64'
            record = next(r for r in records if r['filename'].startswith(name + '-') and tag in r['filename'])
            wheel = vendor / record['filename']
            if hashlib.sha256(wheel.read_bytes()).hexdigest() != record['sha256']:
                raise RuntimeError('Offline tool checksum mismatch: ' + wheel.name)
            with zipfile.ZipFile(wheel) as archive:
                member = next(n for n in archive.namelist() if n.endswith('.data/scripts/' + name))
                binary = Path(directory) / (name + '-' + arch)
                binary.write_bytes(archive.read(member))
                binary.chmod(0o755)
                slices.append(str(binary))
        target = helpers / name
        if len(slices) == 1:
            target.write_bytes(Path(slices[0]).read_bytes())
        else:
            subprocess.run(['/usr/bin/lipo', '-create', *slices, '-output', str(target)], check=True)
        target.chmod(0o755)
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', identity, '--options', 'runtime',
                        '--timestamp=none', '--entitlements', str(repo / 'client/macos/Runner/EditorTool.entitlements'),
                        str(target)], check=True)

from bundle_local_completion import bundle
bundle(repo, helpers, identity, architectures)

# Xcode seals the parent app after all build phases. Remove Finder metadata
# from generated resources before that final signing step.
app = helpers.parent.parent
for attribute in ['com.apple.FinderInfo', 'com.apple.ResourceFork']:
    subprocess.run(['/usr/bin/xattr', '-dr', attribute, str(app)], capture_output=True)
