import os
import ssl
import threading
from datetime import datetime, timezone

import requests
from flask import Flask, request
from werkzeug.serving import run_simple, WSGIRequestHandler

app = Flask(__name__)

# --- Ingestion pipeline wiring (AWS Event Ingestion Pipeline) ----------------------
# Every access event this frontend produces is shipped to the serverless
# ingestion endpoint (nginx TLS -> API Gateway -> SQS -> Lambda -> DynamoDB/S3).
# Everything is configured via env vars; the API key comes from a Secret and is
# never hardcoded. Shipping is best-effort and asynchronous, so an ingestion
# outage never affects the response returned to the client.
INGEST_ENABLED = os.getenv('INGEST_ENABLED', 'false').lower() == 'true'
INGEST_URL = os.getenv('INGEST_URL', '')
INGEST_API_KEY = os.getenv('INGEST_API_KEY', '')
# Path to the ingestion endpoint's CA so TLS is *validated*, not disabled. If
# empty, falls back to INGEST_VERIFY (true -> system CA bundle).
INGEST_CA_PATH = os.getenv('INGEST_CA_PATH', '')
INGEST_VERIFY = os.getenv('INGEST_VERIFY', 'true').lower() == 'true'
INGEST_TIMEOUT = float(os.getenv('INGEST_TIMEOUT', '2'))

_session = requests.Session()


def _verify_opt():
    # requests accepts either a CA bundle path or a bool for `verify`.
    return INGEST_CA_PATH if INGEST_CA_PATH else INGEST_VERIFY


def _ship_event(event):
    if not (INGEST_ENABLED and INGEST_URL and INGEST_API_KEY):
        return
    try:
        _session.post(
            INGEST_URL,
            json=event,
            headers={'x-api-key': INGEST_API_KEY, 'Content-Type': 'application/json'},
            verify=_verify_opt(),
            timeout=INGEST_TIMEOUT,
        )
    except Exception as exc:  # best-effort: log and move on, never break the response
        print(f'[ingest] failed to ship event: {exc}', flush=True)


@app.route('/')
def echo():
    # Detects the real IP if coming through Ingress/Proxy via X-Forwarded-For
    client_ip = request.headers.get('X-Forwarded-For', request.remote_addr)

    # Ship this access event to the ingestion pipeline (async, best-effort).
    # `ts` (per-request timestamp) makes each hit a distinct payload, so the
    # pipeline stores one record per access instead of deduping identical
    # domain/client_ip pairs into a single item.
    event = {
        'domain': request.host,
        'client_ip': client_ip,
        'ts': datetime.now(timezone.utc).isoformat(),
    }
    threading.Thread(target=_ship_event, args=(event,), daemon=True).start()

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
