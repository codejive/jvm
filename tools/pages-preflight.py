#!/usr/bin/env python3
"""Verify latest.txt against complete, public release assets before deploying Pages."""
import hashlib
import pathlib
import re
import urllib.request

root = pathlib.Path(__file__).resolve().parent.parent
version = (root / 'web/latest.txt').read_text()
assert re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\n', version), 'Invalid latest.txt'
base = f'https://github.com/codejive/jvm/releases/download/v{version.strip()}'


class HttpsRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not newurl.startswith('https://'):
            raise ValueError('HTTPS downgrade')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


opener = urllib.request.build_opener(HttpsRedirect())


def get(name):
    with opener.open(f'{base}/{name}', timeout=60) as response:
        assert response.status == 200
        return response.read()


lines = get('SHA256SUMS').decode('ascii').splitlines()
hashes = {}
for line in lines:
    match = re.fullmatch(r'([0-9a-f]{64})  (jvm|jvm\.ps1|jvm\.cmd)', line)
    assert match and match[2] not in hashes, 'Invalid SHA256SUMS'
    hashes[match[2]] = match[1]
assert set(hashes) == {'jvm', 'jvm.ps1', 'jvm.cmd'}, 'Incomplete release'
for name, digest in hashes.items():
    assert hashlib.sha256(get(name)).hexdigest() == digest, f'Invalid {name}'
print(f'Complete verified public release: v{version.strip()}')
