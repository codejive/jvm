#!/usr/bin/env python3
"""Verify latest.txt against complete, public release assets before deploying Pages."""
import hashlib
import io
import pathlib
import re
import tarfile
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


assert get('latest.txt') == version.encode('ascii'), 'Release latest.txt mismatch'
checksum = get('jvm.tar.gz.sha256').decode('ascii')
assert re.fullmatch(r'[0-9a-f]{64}\n', checksum), 'Invalid archive checksum'
archive = get('jvm.tar.gz')
assert hashlib.sha256(archive).hexdigest() == checksum.strip(), 'Archive checksum mismatch'
with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as tar:
    members = tar.getmembers()
    assert len(members) == 4 and {m.name for m in members} == {'jvm', 'jvm.ps1', 'jvm.cmd', 'latest.txt'}, 'Invalid archive contents'
    assert all(m.isfile() and m.size > 0 for m in members), 'Invalid archive entry type or size'
    assert tar.extractfile('latest.txt').read() == version.encode('ascii'), 'Archive latest.txt mismatch'
    for member in members:
        assert len(tar.extractfile(member).read()) == member.size, 'Truncated archive payload'
print(f'Complete verified public release: v{version.strip()}')
