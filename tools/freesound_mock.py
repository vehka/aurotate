#!/usr/bin/env python3
# mock Freesound API v2 + plain files, for aurotate's phase 9 device tests
#
# usage: python3 tools/freesound_mock.py <dir with tone.wav tone.mp3 orig.aif prev.ogg big.wav> <this host ip>
# then on the device: dbg.Download.FS.cfg.base = "http://<ip>:8765", api key TESTKEY123,
# client id TESTCID; the authorize link answers with the code GOODCODE. /revoke, /unrevoke,
# /state (tokens and the request log). Remove freesound.lua afterwards.
import base64, hashlib, json, os, sys, time, urllib.parse
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

WWW = sys.argv[1]
HOST = sys.argv[2] if len(sys.argv) > 2 else '10.0.0.36'
PORT = 8765
BASE = f'http://{HOST}:{PORT}'
KEY, CID = 'TESTKEY123', 'TESTCID'
state = {'challenge': None, 'access': set(), 'refresh': None, 'revoked': False, 'log': []}


def b64url(b): return base64.urlsafe_b64encode(b).rstrip(b'=').decode()


SOUND = {
    "id": 12345, "url": "https://freesound.org/people/fieldrec/sounds/12345/", "name": "harbour wind.aif",
    "tags": ["wind", "harbour", "field-recording"],
    "description": "Wind at the <a href=\"x\">harbour</a>.<br />Zoom H5 &amp; windjammer.",
    "geotag": "60.15 24.95", "created": "2024-03-01T10:20:30",
    "license": "http://creativecommons.org/licenses/by-nc/4.0/", "type": "aif", "channels": 1,
    "filesize": 2116888, "bitdepth": 16, "duration": 12.0, "samplerate": 44100, "username": "fieldrec",
    "pack": None, "md5": "abc123",
    "previews": {"preview-hq-ogg": BASE + "/files/prev.ogg", "preview-hq-mp3": BASE + "/files/tone.mp3"},
}


class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *a):
        line = '%s %s auth=%s' % (self.command, self.path, (self.headers.get('Authorization') or '-')[:14])
        state['log'].append(line)
        sys.stderr.write(line + '\n')

    def send(self, code, body=b'', ctype='application/json', extra=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)

    def file(self, name, extra=None, slow=False):
        p = os.path.join(WWW, name)
        data = open(p, 'rb').read()
        ctype = {'wav': 'audio/wav', 'mp3': 'audio/mpeg', 'ogg': 'audio/ogg', 'aif': 'audio/aiff'}.get(
            name.rsplit('.', 1)[-1], 'application/octet-stream')
        self.send_response(200)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Last-Modified', 'Wed, 01 Jan 2025 12:00:00 GMT')
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if slow:
            for i in range(0, len(data), 65536):
                self.wfile.write(data[i:i + 65536])
                time.sleep(0.2)
        else:
            self.wfile.write(data)

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        auth = self.headers.get('Authorization') or ''
        if u.path.startswith('/files/'):
            return self.file(u.path[7:])
        if u.path == '/slow.wav':
            return self.file('big.wav', slow=True)
        if u.path == '/cd':
            return self.file('tone.wav', {'Content-Disposition': 'attachment; filename="Field Take 1.WAV"'})
        if u.path == '/redirect':
            return self.send(302, b'', 'text/plain', {'Location': '/files/tone.wav'})
        if u.path == '/page':
            return self.send(200, b'<!DOCTYPE html><html><body>hi</body></html>', 'text/html')
        if u.path == '/missing.wav':
            return self.send(404, b'nope', 'text/plain')
        if u.path == '/apiv2/oauth2/authorize/':
            state['challenge'] = q['code_challenge'][0]
            assert q['code_challenge_method'][0] == 'S256' and q['client_id'][0] == CID
            return self.send(200, b'Your code: GOODCODE', 'text/plain')
        if u.path.startswith('/apiv2/sounds/'):
            parts = u.path.strip('/').split('/')
            sid = int(parts[2])
            if len(parts) == 3:
                if auth != 'Token ' + KEY:
                    return self.send(401, {'detail': 'Invalid token.'})
                if sid != 12345:
                    return self.send(404, {'detail': 'Not found.'})
                return self.send(200, SOUND)
            if parts[3] == 'download':
                tok = auth[7:] if auth.startswith('Bearer ') else None
                if state['revoked'] or tok not in state['access']:
                    return self.send(401, {'detail': 'Invalid token.'})
                return self.send(302, b'', 'text/plain', {'Location': BASE + '/files/orig.aif'})
        if u.path == '/state':
            return self.send(200, {'challenge': state['challenge'], 'refresh': state['refresh'],
                                   'access': sorted(state['access']), 'log': state['log'][-30:]})
        if u.path == '/revoke':
            state['revoked'] = True
            return self.send(200, {'ok': True})
        if u.path == '/unrevoke':
            state['revoked'] = False
            return self.send(200, {'ok': True})
        self.send(404, b'?', 'text/plain')

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        n = int(self.headers.get('Content-Length') or 0)
        f = {k: v[0] for k, v in urllib.parse.parse_qs(self.rfile.read(n).decode()).items()}
        if u.path != '/apiv2/oauth2/access_token/':
            return self.send(404, b'?', 'text/plain')
        if f.get('client_id') != CID or f.get('client_secret') != KEY:
            return self.send(401, {'error': 'invalid_client'})
        if state['revoked']:
            return self.send(400, {'error': 'invalid_grant'})
        if f.get('grant_type') == 'authorization_code':
            ok = f.get('code') == 'GOODCODE' and state['challenge'] and \
                b64url(hashlib.sha256(f.get('code_verifier', '').encode()).digest()) == state['challenge']
            if not ok:
                return self.send(400, {'error': 'invalid_grant', 'error_description': 'bad code or verifier'})
        elif f.get('grant_type') == 'refresh_token':
            if f.get('refresh_token') != state['refresh']:
                return self.send(400, {'error': 'invalid_grant'})
        else:
            return self.send(400, {'error': 'unsupported_grant_type'})
        acc = 'A' + os.urandom(6).hex()
        state['refresh'] = 'R' + os.urandom(6).hex()
        state['access'].add(acc)
        self.send(200, {'access_token': acc, 'refresh_token': state['refresh'], 'expires_in': 86400,
                        'token_type': 'Bearer', 'scope': 'read write'})


ThreadingHTTPServer(('0.0.0.0', PORT), H).serve_forever()
