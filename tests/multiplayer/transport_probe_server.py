"""Local-only delayed response for checking native HTTPLite Ruby GVL behavior."""
from http.server import BaseHTTPRequestHandler, HTTPServer
import time


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        time.sleep(2)
        body = b'{"probe":"ok"}'
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    print("TRANSPORT_PROBE_READY 127.0.0.1:18766", flush=True)
    HTTPServer(("127.0.0.1", 18766), Handler).serve_forever()
