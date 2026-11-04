#!/usr/bin/env python3
"""Offline exact-byte release packaging and public-site staging (contributor tool)."""
import argparse
import hashlib
import pathlib
import re
import shutil

ROOT = pathlib.Path(__file__).resolve().parent.parent
ASSETS = ('jvm', 'jvm.ps1', 'jvm.cmd')
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
    elif (ROOT / 'web/latest.txt').read_bytes() != (args.version + '\n').encode():
        parser.error('site version must match latest.txt')
    if args.destination.exists():
        parser.error('destination must not exist')
    args.destination.mkdir(parents=True)
    if args.site:
        for name in ('install.sh', 'install.ps1', 'latest.txt', 'index.html', '.nojekyll'):
            shutil.copyfile(ROOT / 'web' / name, args.destination / name)
    else:
        lines = []
        for name in ASSETS:
            content = (ROOT / name).read_bytes()
            (args.destination / name).write_bytes(content)
            lines.append(f'{hashlib.sha256(content).hexdigest()}  {name}\n')
        (args.destination / 'SHA256SUMS').write_bytes(''.join(lines).encode('ascii'))


if __name__ == '__main__':
    main()
