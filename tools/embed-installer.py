#!/usr/bin/env python3
"""Embed the single-source Windows installer in the standalone Bash bootstrap."""
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parent.parent
target = root / 'web/install.sh'
marker = '# BEGIN GENERATED WINDOWS INSTALLER\n'
prefix = target.read_text().split(marker)[0]
result = prefix + marker + "windows_installer() {\ncat <<'JVM_POWERSHELL_INSTALLER'\n" + (root / 'web/install.ps1').read_text() + "JVM_POWERSHELL_INSTALLER\n}\nmain \"$@\"\n"
if '--check' in sys.argv:
    if target.read_bytes() != result.encode():
        sys.exit('Run python tools/embed-installer.py')
else:
    target.write_bytes(result.encode())
