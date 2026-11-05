#!/usr/bin/env python3
"""Offline checks of exact-byte packaging and the Pages allowlist."""
import hashlib
import pathlib
import re
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='jvm-release-test-') as temp:
    temp = pathlib.Path(temp)
    subprocess.run([sys.executable, str(root / 'tools/embed-installer.py'), '--check'], check=True)
    version = re.search(r'^VERSION=(.+)$', (root / 'jvm').read_text(), re.M)[1]
    package = root / 'tools/package-release.py'
    subprocess.run([sys.executable, str(package), version, str(temp / 'assets')], check=True)
    expected = []
    for name in ('jvm', 'jvm.ps1', 'jvm.cmd'):
        content = (root / name).read_bytes()
        assert content == (temp / 'assets' / name).read_bytes()
        expected.append(f'{hashlib.sha256(content).hexdigest()}  {name}\n')
    assert (temp / 'assets/SHA256SUMS').read_bytes() == ''.join(expected).encode()
    latest = (root / 'web/latest.txt').read_text().strip()
    subprocess.run([sys.executable, str(package), latest, str(temp / 'site'), '--site'], check=True)
    assert {p.name for p in (temp / 'site').iterdir()} == {'install.sh', 'install.ps1', 'latest.txt', 'index.html', '.nojekyll'}
    for path in (temp / 'site').iterdir():
        assert path.read_bytes() == (root / 'web' / path.name).read_bytes()
    assert subprocess.run([sys.executable, str(package), 'v' + version, str(temp / 'bad')], capture_output=True).returncode == 2
print('Exact-byte assets, checksums, embedded installer and Pages allowlist passed')
