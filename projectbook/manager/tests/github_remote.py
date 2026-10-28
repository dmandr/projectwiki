"""Isolated GitHub-shaped HTTPS Git fixture. Never publish outside its Docker network."""
import base64
import datetime
import json
import os
from pathlib import Path
import re
import ssl
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

root=Path('/repos/owner');root.mkdir(parents=True,exist_ok=True)
certpath=Path('/certs/ca.crt');keypath=Path('/certs/key.pem');certpath.parent.mkdir(exist_ok=True)
if not certpath.exists():
    key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
    subject=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'github.com')]);now=datetime.datetime.now(datetime.timezone.utc)
    cert=(x509.CertificateBuilder().subject_name(subject).issuer_name(subject).public_key(key.public_key())
        .serial_number(x509.random_serial_number()).not_valid_before(now-datetime.timedelta(minutes=1))
        .not_valid_after(now+datetime.timedelta(days=7)).add_extension(x509.SubjectAlternativeName([x509.DNSName('github.com')]),critical=False)
        .add_extension(x509.BasicConstraints(ca=True,path_length=None),critical=True).sign(key,hashes.SHA256()))
    certpath.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    keypath.write_bytes(key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))

class Handler(BaseHTTPRequestHandler):
    def log_message(self,*_): pass
    def do_GET(self):self.serve()
    def do_POST(self):self.serve()
    def serve(self):
        url=urlsplit(self.path)
        if url.path=='/__fixture/create':
            value=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))))
            name=value['name']
            if not re.fullmatch(r'[A-Za-z0-9_-]+',name):self.send_error(400);return
            bare=root/(name+'.git')
            if not bare.exists():
                subprocess.run(['git','init','--bare','--initial-branch=main',str(bare)],check=True,capture_output=True)
                subprocess.run(['git','--git-dir='+str(bare),'config','http.receivepack','true'],check=True)
            self.send_response(200);self.end_headers();return
        try:auth=base64.b64decode(self.headers.get('Authorization','').split(' ',1)[-1]).decode()
        except Exception:auth=''
        if not auth.startswith('x-access-token:ghu_fixture'):
            self.send_response(401);self.send_header('WWW-Authenticate','Basic realm="fixture"');self.end_headers();return
        if Path('/repos/reject-push').exists() and url.path.endswith('/git-receive-pack'):
            self.send_error(403);return
        env=dict(os.environ,GIT_PROJECT_ROOT='/repos',GIT_HTTP_EXPORT_ALL='1',PATH_INFO=url.path,
                 QUERY_STRING=url.query,REQUEST_METHOD=self.command,CONTENT_TYPE=self.headers.get('Content-Type',''),REMOTE_USER='owner')
        body=self.rfile.read(int(self.headers.get('Content-Length','0')))
        result=subprocess.run(['git','http-backend'],env=env,input=body,capture_output=True)
        header,_,content=result.stdout.partition(b'\r\n\r\n')
        headers=dict(line.decode().split(': ',1) for line in header.split(b'\r\n') if b': ' in line)
        self.send_response(int(headers.pop('Status','200').split()[0]))
        for k,v in headers.items():self.send_header(k,v)
        self.send_header('Content-Length',str(len(content)));self.end_headers();self.wfile.write(content)
server=ThreadingHTTPServer(('0.0.0.0',443),Handler)
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(certpath,keypath);server.socket=ctx.wrap_socket(server.socket,server_side=True)
print('Isolated GitHub Git fixture ready',flush=True);server.serve_forever()
