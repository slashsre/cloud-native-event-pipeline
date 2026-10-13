import os
import ssl
import time
import requests

class Client:
    def __init__(self, server_addresses, cert_path, port=5000, timeout=5):
        self.server_addresses = server_addresses
        self.port = port
        self.timeout = timeout
        self.session = requests.Session()
        self.session.verify = cert_path

    def request(self, url):
        try:
            response = self.session.get(url, timeout=self.timeout)
            print(f'Response from {url}: {response.text}', flush=True)
        except Exception as e:
            print(f'Error while connecting to {url}: {e}', flush=True)

    def run_once(self):
        for server_address in self.server_addresses:
            url = f'https://{server_address}:{self.port}'
            self.request(url)

    def run_loop(self, interval=5):
        print(f'Starting client loop with interval of {interval}s...', flush=True)
        while True:
            self.run_once()
            time.sleep(interval)

if __name__ == '__main__':
    # Environment variables with default values.
    raw_addresses = os.getenv('SERVER_ADDRESSES', 'server,server.example.com,server.local')
    server_addresses = [addr.strip() for addr in raw_addresses.split(',') if addr.strip()]
    cert_path = os.getenv('CERT_PATH', 'certs/server.crt')
    server_port = int(os.getenv('SERVER_PORT', '5000'))

    # Periodic client request loop configuration
    request_interval = int(os.getenv('REQUEST_INTERVAL', '5'))
    request_timeout = int(os.getenv('REQUEST_TIMEOUT', '5'))

    client = Client(
        server_addresses=server_addresses,
        cert_path=cert_path,
        port=server_port,
        timeout=request_timeout
    )

    if request_interval > 0:
        client.run_loop(interval=request_interval)
    else:
        client.run_once()