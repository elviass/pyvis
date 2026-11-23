"""Fetch pinned public model/runtime artifacts using verified HTTPS and SHA-256."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import tarfile

repo = Path(__file__).resolve().parents[1]
manifest = json.loads((repo / 'tools/local_completion_manifest.json').read_text())
cache = repo / 'runtime/local_completion'


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def fetch(record, path):
    if path.exists() and digest(path) == record['sha256']:
        return
    stage = path.with_suffix(path.suffix + '.part')
    subprocess.run(['curl', '--fail', '--location', '--retry', '2',
                    '--connect-timeout', '15', record['url'], '-o', str(stage)], check=True)
    if digest(stage) != record['sha256']:
        raise RuntimeError('Local completion artifact checksum mismatch: ' + path.name)
    stage.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=manifest['servers'],
                        default='macos-arm64' if platform.machine() == 'arm64' else 'macos-x64')
    args = parser.parse_args()
    cache.mkdir(parents=True, exist_ok=True)
    model = manifest['model']
    fetch(model, cache / model['filename'])
    server = manifest['servers'][args.platform]
    archive = cache / server['url'].rsplit('/', 1)[1]
    fetch(server, archive)
    destination = cache / args.platform
    destination.mkdir(exist_ok=True)
    with tarfile.open(archive) as package:
        # Pinned archive; reject paths/links that escape its extraction folder.
        for member in package.getmembers():
            if member.name.startswith('/') or '..' in Path(member.name).parts:
                raise RuntimeError('Unsafe runtime archive path')
            if member.issym() and ('..' in Path(member.linkname).parts or member.linkname.startswith('/')):
                raise RuntimeError('Unsafe runtime archive link')
        package.extractall(destination)
    print('Local completion model and runtime verified: ' + args.platform)


if __name__ == '__main__':
    main()
