#!/usr/bin/env python3
"""Offline exact-byte release packaging and public-site staging (contributor tool)."""
import argparse
import gzip
import hashlib
import io
import pathlib
import re
import shutil
import tarfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
ASSETS = ('jvm', 'jvm.ps1', 'jvm.cmd', 'latest.txt')
VERSION = r'(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('version')
    parser.add_argument('destination', type=pathlib.Path)
    parser.add_argument('--site', action='store_true')
    args = parser.parse_args()
    if not re.fullmatch(VERSION, args.version):
        parser.error('version must be numeric major.minor.patch without leading zeros')
    if not args.site:
        for name, pattern in [('jvm', r'^VERSION=([^\n]+)$'),
                              ('jvm.ps1', r"^\$script:Version = '([^']+)'$")]:
            match = re.search(pattern, (ROOT / name).read_text(), re.M)
            if not match or match[1] != args.version:
                parser.error(f'{name} version does not match {args.version}')
    if (ROOT / 'web/latest.txt').read_bytes() != (args.version + '\n').encode():
        parser.error('version must match latest.txt (with one final LF)')
    if args.destination.exists():
        parser.error('destination must not exist')
    args.destination.mkdir(parents=True)
    if args.site:
        for name in ('install.sh', 'install.ps1', 'latest.txt', 'index.html', '.nojekyll'):
            shutil.copyfile(ROOT / 'web' / name, args.destination / name)
    else:
        archive = args.destination / 'jvm.tar.gz'
        with archive.open('wb') as output:
            with gzip.GzipFile(filename='', mode='wb', fileobj=output, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode='w', format=tarfile.USTAR_FORMAT) as tar:
                    for name in ASSETS:
                        content = (ROOT / ('web/latest.txt' if name == 'latest.txt' else name)).read_bytes()
                        entry = tarfile.TarInfo(name)
                        entry.size = len(content)
                        entry.mode = 0o755 if name == 'jvm' else 0o644
                        tar.addfile(entry, io.BytesIO(content))
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        (args.destination / 'jvm.tar.gz.sha256').write_bytes((digest + '\n').encode('ascii'))
        shutil.copyfile(ROOT / 'web/latest.txt', args.destination / 'latest.txt')


if __name__ == '__main__':
    main()
