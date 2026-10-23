"""Package the patched panel against a checksum-pinned upstream release."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request


UPSTREAM_URL = 'https://github.com/MHSanaei/3x-ui/releases/download/v3.9.0/x-ui-linux-amd64.tar.gz'
UPSTREAM_SHA256 = 'd7cbe0bf6358ee0d2117c24fd2efb483502e411d38e2ea59bd0bf5e7a3e39390'


def sha256(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--output', default='release', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    work = output / 'package-work'
    work.mkdir(exist_ok=False)
    archive = work / 'upstream.tar.gz'
    urllib.request.urlretrieve(UPSTREAM_URL, archive)
    if sha256(archive) != UPSTREAM_SHA256:
        raise RuntimeError('official base package checksum mismatch')
    with tarfile.open(archive, 'r:gz') as source:
        # Reject unsafe names and links before extracting the pinned public archive.
        for member in source.getmembers():
            target = (work / member.name).resolve()
            if not target.is_relative_to(work) or member.issym() or member.islnk():
                raise RuntimeError('unsafe upstream archive entry')
        source.extractall(work, filter='data')
    package = work / 'x-ui'
    shutil.copy2(args.binary, package / 'x-ui')
    (package / 'x-ui').chmod(0o755)
    shutil.copy2(root / 'LICENSE', package / 'LICENSE')
    shutil.copy2(root / 'README.md', package / 'README.noad.md')
    provenance = {
        'distribution': '3xui_noAD',
        'version': '3.9.0-noad.1',
        'upstream': 'https://github.com/MHSanaei/3x-ui',
        'upstream_tag': 'v3.9.0',
        'upstream_commit': '3cd4bf504c3cd8ea9b1c1fdb032a9796c5c43ddb',
        'source': 'https://github.com/GG-bonded/3xui_noAD',
        'source_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True, encoding='utf-8').strip(),
        'official_base_sha256': UPSTREAM_SHA256,
        'panel_sha256': sha256(package / 'x-ui'),
        'license': 'GPL-3.0',
    }
    (package / 'NOAD_BUILD.json').write_text(json.dumps(provenance, indent=2) + '\n', encoding='utf-8')
    complete = output / 'x-ui-linux-amd64-noad.tar.gz'
    with tarfile.open(complete, 'w:gz') as target:
        target.add(package, arcname='x-ui')
    panel = output / 'x-ui-panel-linux-amd64-noad.tar.gz'
    with tarfile.open(panel, 'w:gz') as target:
        for name in ['x-ui', 'LICENSE', 'README.noad.md', 'NOAD_BUILD.json']:
            target.add(package / name, arcname='x-ui/' + name)
    source = output / '3xui-noad-source.tar.gz'
    subprocess.run(['git', 'archive', '--format=tar.gz', '--prefix=3xui_noAD/', '-o', str(source), 'HEAD'], cwd=root, check=True)
    sums = ''.join(sha256(path) + '  ' + path.name + '\n' for path in [complete, panel, source])
    (output / 'SHA256SUMS').write_text(sums, encoding='utf-8')
    print(sums, end='')


if __name__ == '__main__':
    main()
