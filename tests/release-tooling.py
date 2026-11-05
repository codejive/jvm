#!/usr/bin/env python3
"""Offline checks of exact-byte release packaging."""
import hashlib
import pathlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='jvm-release-test-') as temp:
    temp = pathlib.Path(temp)
    version = re.search(r'^VERSION=(.+)$', (root / 'jvm').read_text(), re.M)[1]
    package = root / 'tools/package-release.py'
    subprocess.run([sys.executable, str(package), version, str(temp / 'assets')], check=True)
    assert {p.name for p in (temp / 'assets').iterdir()} == {'jvm.tar.gz', 'jvm.tar.gz.sha256', 'latest.txt'}
    assert (temp / 'assets/latest.txt').read_bytes() == (root / 'web/latest.txt').read_bytes() == (version + '\n').encode()
    archive = temp / 'assets/jvm.tar.gz'
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    assert (temp / 'assets/jvm.tar.gz.sha256').read_bytes() == (digest + '\n').encode()
    with tarfile.open(archive, 'r:gz') as tar:
        assert tar.getnames() == ['jvm', 'jvm.ps1', 'jvm.cmd', 'latest.txt']
        for entry in tar.getmembers():
            assert entry.isfile() and entry.mode == (0o755 if entry.name == 'jvm' else 0o644)
            expected = root / ('web/latest.txt' if entry.name == 'latest.txt' else entry.name)
            assert tar.extractfile(entry).read() == expected.read_bytes()
    subprocess.run([sys.executable, str(package), version, str(temp / 'repeat')], check=True)
    assert archive.read_bytes() == (temp / 'repeat/jvm.tar.gz').read_bytes()
    assert subprocess.run([sys.executable, str(package), 'v' + version, str(temp / 'bad')], capture_output=True).returncode == 2
    fixture = temp / 'source'
    (fixture / 'tools').mkdir(parents=True)
    (fixture / 'web').mkdir()
    shutil.copyfile(package, fixture / 'tools/package-release.py')
    for name in ('jvm', 'jvm.ps1', 'jvm.cmd'):
        shutil.copyfile(root / name, fixture / name)
    other_version = str(int(version.split('.')[0]) + 1) + '.0.0'
    for pointer in (other_version + '\n', version + '.1\n', version,
                    version + '\r\n', version + '\n\n'):
        (fixture / 'web/latest.txt').write_bytes(pointer.encode())
        result = subprocess.run([sys.executable, str(fixture / 'tools/package-release.py'), version,
                                 str(temp / 'invalid-pointer')], capture_output=True)
        assert result.returncode == 2 and b'version must match latest.txt' in result.stderr
        assert not (temp / 'invalid-pointer').exists()
print('Reproducible archive, exact bytes, release pointer and checksum passed')
