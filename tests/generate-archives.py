"""Contributor-only fixture generator; never called by jvm or offline tests."""
import gzip
import io
from pathlib import Path
import tarfile
import zipfile

ROOT = Path(__file__).parent / 'fixtures' / 'archives'
ROOT.mkdir(exist_ok=True)

def tar(name, entries):
    with (ROOT / (name + '.tar.gz')).open('wb') as output:
        with gzip.GzipFile(filename='', mode='wb', fileobj=output, mtime=0) as gz:
            with tarfile.open(fileobj=gz, mode='w') as archive:
                for path, kind, value in entries:
                    item = tarfile.TarInfo(path)
                    item.mode = 0o755
                    if kind == 'file':
                        data = value.encode()
                        item.size = len(data)
                        archive.addfile(item, io.BytesIO(data))
                    else:
                        item.type = {'link': tarfile.SYMTYPE, 'hard': tarfile.LNKTYPE, 'dir': tarfile.DIRTYPE}[kind]
                        item.linkname = value
                        archive.addfile(item)

def zip(name, entries):
    with zipfile.ZipFile(ROOT / (name + '.zip'), 'w') as archive:
        for path, kind, value in entries:
            item = zipfile.ZipInfo(path, date_time=(2020, 1, 1, 0, 0, 0))
            item.create_system = 3
            item.external_attr = ((0o120777 if kind == 'link' else 0o100755) << 16)
            archive.writestr(item, value)

normal = [('jdk/bin/java', 'file', '#!/bin/sh\n# inert fixture runtime\nexit 99\n'),
          ('jdk/bin/javac', 'file', '#!/bin/sh\n# inert fixture compiler\nexit 99\n'),
          ('jdk/lib/data', 'file', 'fixture data\n'),
          ('jdk/lib/internal', 'link', 'data'),
          ('jdk/.home-marker', 'file', 'hidden home file\n'),
          ('jdk/release', 'file', 'JAVA_VERSION="21.0.2"\nOS_ARCH="x86_64"\nOS_NAME="Linux"\n')]
tar('jdk', normal)
zip('jdk', normal)
tar('rootless', [(p.removeprefix('jdk/'), k, v) for p, k, v in normal])
tar('nested', [('outer/wrapper/' + p, k, v) for p, k, v in normal])
tar('macos', [(p.replace('jdk/', 'jdk.jdk/Contents/Home/'), k, v.replace('OS_NAME="Linux"', 'OS_NAME="Darwin"')) for p, k, v in normal])
windows = [('jdk/bin/java.exe', 'file', 'fixture runtime'), ('jdk/bin/javac.exe', 'file', 'fixture compiler')]
zip('windows', windows)
tar('windows', windows)
for name, extension in [('windows-bat', '.bat'), ('windows-cmd', '.cmd'), ('windows-bare', '')]:
    zip(name, [('jdk/bin/java' + extension, 'file', 'fixture runtime'), ('jdk/bin/javac' + extension, 'file', 'fixture compiler')])
tar('hardlink', normal + [('jdk/bin/alias', 'hard', 'jdk/bin/java')])
for name, extra in {
    'traversal': [('../escaped', 'file', 'bad')],
    'absolute': [('/tmp/jvm-escaped', 'file', 'bad')],
    'outside-link': [('jdk/lib/evil', 'link', '../../../escaped')],
    'link-parent': [('jdk/alias', 'link', 'lib'), ('jdk/alias/evil', 'file', 'bad')],
    'duplicate': [('jdk/bin/java', 'file', 'replacement')],
    'cycle': [('jdk/lib/a', 'link', 'b'), ('jdk/lib/b', 'link', 'a')],
}.items():
    zip(name, normal + extra)
