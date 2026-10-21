"""Local non-game endpoint for isolated native HTTP/GVL diagnosis."""
from http.server import BaseHTTPRequestHandler, HTTPServer

BODY = b'{"probe":"ok","padding":"' + b'x' * 32768 + b'"}'


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(BODY)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(BODY)

    def log_message(self, *_args):
        pass


if __name__ == '__main__':
    print('HTTP_GVL_ECHO_READY 127.0.0.1:18785', flush=True)
    HTTPServer(('127.0.0.1', 18785), Handler).serve_forever()
