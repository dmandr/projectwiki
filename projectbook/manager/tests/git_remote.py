"""Disposable HTTPS smart Git remote for Docker integration tests; no external accounts."""
import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import ssl
import subprocess
from urllib.parse import urlsplit

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID


def run(*args, cwd=None):
    return subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


root = Path('/repos')
root.mkdir(exist_ok=True)
for name in ('alpha', 'beta'):
    bare = root / (name + '.git')
    if not bare.exists():
        run('git', 'init', '--bare', '--initial-branch=main', str(bare))
        run('git', '--git-dir=' + str(bare), 'config', 'http.receivepack', 'true')
        work = Path('/tmp') / name
        run('git', 'clone', str(bare), str(work))
        run('git', 'config', 'user.name', 'Fixture', cwd=work)
        run('git', 'config', 'user.email', 'fixture@localhost', cwd=work)
        (work / 'Home.md').write_text('# ' + name.title() + '\n\nIntegration test book.\n')
        (work / 'sample.txt').write_text('Attachment from ' + name + '\n')
        run('git', 'add', '.', cwd=work)
        run('git', 'commit', '-m', 'Initial fixture', cwd=work)
        run('git', 'push', 'origin', 'main', cwd=work)

key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'git-fixture')])
now = datetime.datetime.now(datetime.timezone.utc)
cert = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject).public_key(key.public_key())
        .serial_number(x509.random_serial_number()).not_valid_before(now-datetime.timedelta(minutes=1))
        .not_valid_after(now+datetime.timedelta(days=7)).add_extension(x509.SubjectAlternativeName([x509.DNSName('git-fixture')]), critical=False)
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True).sign(key, hashes.SHA256()))
Path('/run/git/ca.crt').write_bytes(cert.public_bytes(serialization.Encoding.PEM))
Path('/tmp/key.pem').write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.serve()

    def do_POST(self):
        self.serve()

    def serve(self):
        url = urlsplit(self.path)
        if Path('/repos/reject-push').exists() and url.path.endswith('/git-receive-pack'):
            self.send_error(403, 'Simulated push rejection')
            return
        env = dict(os.environ, GIT_PROJECT_ROOT='/repos', GIT_HTTP_EXPORT_ALL='1',
                   PATH_INFO=url.path, QUERY_STRING=url.query, REQUEST_METHOD=self.command,
                   CONTENT_TYPE=self.headers.get('Content-Type', ''), REMOTE_USER='fixture')
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        result = subprocess.run(['git', 'http-backend'], env=env, input=body, capture_output=True)
        header, _, content = result.stdout.partition(b'\r\n\r\n')
        headers = dict(line.decode().split(': ', 1) for line in header.split(b'\r\n') if b': ' in line)
        self.send_response(int(headers.pop('Status', '200').split()[0]))
        for key, value in headers.items():
            self.send_header(key, value)
        self.send_header('Content-Length', str(len(content)))
        self.end_headers()
        self.wfile.write(content)


server = ThreadingHTTPServer(('0.0.0.0', 443), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain('/run/git/ca.crt', '/tmp/key.pem')
server.socket = context.wrap_socket(server.socket, server_side=True)
print('Git fixture ready', flush=True)
server.serve_forever()
