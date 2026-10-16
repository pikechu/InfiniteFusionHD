"""Local real-socket TLS rejection/timeout fixtures; never install their CA.

Run with the bundled Python plus cryptography. Ephemeral key/cert and logs are
written under this checkout's temp directory, never into APK assets or source.
"""
from pathlib import Path
import datetime as dt
import ipaddress
import json
import socketserver
import ssl
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "temp/network-fixture"


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    mutex = threading.Lock()

    def event(kind, **details):
        record = {"timeUtc": dt.datetime.now(dt.timezone.utc).isoformat(), "event": kind, **details}
        with mutex, (OUTPUT / "events.jsonl").open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(record, ensure_ascii=False) + "\n")

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "KIF local network test")])
    now = dt.datetime.now(dt.timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
            .public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now - dt.timedelta(minutes=5)).not_valid_after(now + dt.timedelta(days=1))
            .add_extension(x509.SubjectAlternativeName([
                x509.IPAddress(ipaddress.ip_address("10.0.2.2")),
                x509.IPAddress(ipaddress.ip_address("127.0.0.1")),
            ]), critical=False).sign(key, hashes.SHA256()))
    key_file, cert_file = OUTPUT / "self-signed-key.pem", OUTPUT / "self-signed-cert.pem"
    key_file.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                          serialization.NoEncryption()))
    cert_file.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert_file, key_file)

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            event("HTTP_REQUEST", port=self.server.server_port, method="GET", path=self.path)
            body = b"KIF local network fixture"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            pass

    class TLSFixture(ThreadingHTTPServer):
        daemon_threads = True

        def get_request(self):
            client, address = super().get_request()
            client.settimeout(10)
            event("TLS_TCP_ACCEPT", peer=address[0])
            try:
                tls = context.wrap_socket(client, server_side=True)
                event("TLS_HANDSHAKE_ACCEPTED", protocol=tls.version())
                return tls, address
            except ssl.SSLError as failure:
                event("TLS_HANDSHAKE_REJECTED", reason=str(failure))
                client.close()
                raise

    class StallHandler(socketserver.BaseRequestHandler):
        def handle(self):
            started = time.monotonic()
            event("STALL_TCP_ACCEPT", peer=self.client_address[0])
            self.request.settimeout(30)
            try:
                while self.request.recv(65536):
                    # Receive the actual TLS ClientHello, deliberately send no ServerHello.
                    pass
                event("STALL_CLIENT_CLOSED", elapsed=round(time.monotonic() - started, 3))
            except TimeoutError:
                event("STALL_SERVER_TIMEOUT", elapsed=round(time.monotonic() - started, 3))

    class StallServer(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
        daemon_threads = True

    servers = [TLSFixture(("127.0.0.1", 8443), Handler),
               StallServer(("127.0.0.1", 8444), StallHandler),
               ThreadingHTTPServer(("127.0.0.1", 8445), Handler)]
    for server in servers:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    metadata = {"bind": "127.0.0.1", "selfSignedTlsPort": 8443, "stalledTlsPort": 8444,
                "forbiddenHttpPort": 8445, "certificateSha256": cert.fingerprint(hashes.SHA256()).hex(),
                "certificateInstalledInGuest": False}
    (OUTPUT / "ready.json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")
    event("FIXTURE_READY", **metadata)
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        pass
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
