# NOTE: Snapshot of server.py BEFORE the ingestion-pipeline integration
# (AWS Event Ingestion Pipeline). Kept for documentation/reference only — it is NOT
# the running code. The active version is server.py.
import os
import ssl
from flask import Flask, request
from werkzeug.serving import run_simple, WSGIRequestHandler

app = Flask(__name__)

@app.route('/')
def echo():
    # Detects the real IP if coming through Ingress/Proxy via X-Forwarded-For
    client_ip = request.headers.get('X-Forwarded-For', request.remote_addr)
    return f'Domain: {request.host}, Client IP: {client_ip}\n', 200

if __name__ == '__main__':
    # Enable the use of env variables over Deployments and default values.
    host = os.getenv('SERVER_HOST', '0.0.0.0')
    port = int(os.getenv('SERVER_PORT', '5000'))
    cert_path = os.getenv('CERT_PATH', 'certs/server.crt')
    key_path = os.getenv('KEY_PATH', 'certs/server.key')

    ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    ctx.load_cert_chain(cert_path, key_path)

    print(f'Starting HTTPS server on {host}:{port}...', flush=True)
    run_simple(host, port, app, request_handler=WSGIRequestHandler, ssl_context=ctx)
