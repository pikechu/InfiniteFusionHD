"""Allowlisted download redirects; Matomo owns analytics storage and reports.

The redirect never waits for tracking. Delivery is best effort and a full queue
or Matomo outage drops measurements instead of interrupting a download.
"""

import argparse
import ipaddress
import json
import logging
import os
from pathlib import Path
import queue
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


LOG = logging.getLogger("kif.downloads")
KEY = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}\Z")
QUEUE_CAPACITY = 256
TRACKER_TIMEOUT = 2


def checked_url(value, allow_internal_http=False):
    if not isinstance(value, str) or len(value) > 4096 or not value.isascii():
        raise ValueError("URLs must be ASCII strings of at most 4096 characters")
    if any(ord(char) <= 32 or ord(char) == 127 for char in value) or "\\" in value:
        raise ValueError("URL contains invalid characters")
    parsed = urlsplit(value)
    try:
        port = parsed.port
    except ValueError as exc:
        raise ValueError("URL contains an invalid port") from exc
    if not parsed.hostname or parsed.username is not None or parsed.password is not None or parsed.fragment:
        raise ValueError("URL needs a host and cannot contain credentials or a fragment")
    if port is not None and not 1 <= port <= 65535:
        raise ValueError("URL contains an invalid port")
    if parsed.scheme == "https":
        return value
    loopback = parsed.hostname == "localhost"
    try:
        loopback = loopback or ipaddress.ip_address(parsed.hostname).is_loopback
    except ValueError:
        pass
    if allow_internal_http and parsed.scheme == "http" and (loopback or parsed.hostname == "matomo"):
        return value
    raise ValueError("Use HTTPS; explicit internal HTTP only permits loopback or the matomo service")


def load_links(path):
    path = Path(path)
    if path.stat().st_size > 65536:
        raise ValueError("Download configuration is too large")
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Duplicate download key")
            result[key] = value
        return result
    links = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    if not isinstance(links, dict) or not links or len(links) > 128:
        raise ValueError("downloads.json must contain 1 to 128 named HTTPS URLs")
    for key, target in links.items():
        if not isinstance(key, str) or not KEY.fullmatch(key):
            raise ValueError("Invalid download key")
        checked_url(target)
    return links


class RejectRedirects(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        return None


class MatomoTransport:
    def __init__(self, endpoint):
        # urllib's default HTTPS handler verifies certificate chains and hostnames.
        self.endpoint = endpoint
        self.opener = build_opener(RejectRedirects())

    def __call__(self, payload):
        request = Request(self.endpoint, data=urlencode(payload).encode("utf-8"), method="POST",
                          headers={"Content-Type": "application/x-www-form-urlencoded", "User-Agent": "KIF-Download-Gateway/1"})
        with self.opener.open(request, timeout=TRACKER_TIMEOUT) as response:
            if not 200 <= response.status < 300:
                raise HTTPError(self.endpoint, response.status, "Tracker rejected request", {}, None)
            # Only success/failure matters; do not buffer an unbounded response.
            response.read(1024)


class DownloadTracker:
    def __init__(self, site_id, token, transport, start_worker=True):
        if isinstance(site_id, bool) or not str(site_id).isdigit() or int(site_id) < 1:
            raise ValueError("MATOMO_DOWNLOAD_SITE_ID must be a positive integer")
        if not token or len(token) > 512 or any(ord(char) < 33 or ord(char) > 126 for char in token):
            raise ValueError("MATOMO_DOWNLOAD_TOKEN_AUTH is required")
        self.site_id, self.token, self.transport = str(int(site_id)), token, transport
        self.pending = queue.Queue(maxsize=QUEUE_CAPACITY)
        self.stopped = threading.Event()
        self.worker = None
        if start_worker:
            self.worker = threading.Thread(target=self._run, name="matomo-download-tracker", daemon=True)
            self.worker.start()

    def submit(self, target, client_ip, user_agent, language):
        payload = {"idsite": self.site_id, "rec": "1", "apiv": "1", "send_image": "0",
                   "url": target, "download": target, "cip": client_ip,
                   "ua": user_agent[:512], "lang": language[:128], "token_auth": self.token}
        try:
            self.pending.put_nowait(payload)
            return True
        except queue.Full:
            return False

    def _run(self):
        while not self.stopped.is_set():
            try:
                payload = self.pending.get(timeout=0.2)
            except queue.Empty:
                continue
            try:
                self.transport(payload)
            except Exception as exc:
                # URLs, visitor IPs and tokens are deliberately absent from logs.
                LOG.warning("Matomo delivery failed (%s)", type(exc).__name__)
            finally:
                self.pending.task_done()

    def close(self):
        self.stopped.set()
        if self.worker is not None:
            self.worker.join(timeout=TRACKER_TIMEOUT + 1)


def proxy_addresses(text):
    return frozenset(str(ipaddress.ip_address(part.strip())) for part in text.split(",") if part.strip())


def visitor_ip(socket_ip, forwarded_for, trusted_proxies):
    socket_ip = str(ipaddress.ip_address(socket_ip))
    if socket_ip not in trusted_proxies or not forwarded_for or len(forwarded_for) > 1024:
        return socket_ip
    try:
        parts = forwarded_for.split(",")
        if len(parts) > 16:
            return socket_ip
        chain = [str(ipaddress.ip_address(part.strip())) for part in parts]
    except ValueError:
        return socket_ip
    # Walk back from the peer we actually authenticated by socket address.
    for address in reversed(chain):
        if address not in trusted_proxies:
            return address
    return chain[0]


class DownloadHandler(BaseHTTPRequestHandler):
    server_version = "KIFDownloadGateway/1"

    def do_GET(self):
        self.respond(track=True)

    def do_HEAD(self):
        self.respond(track=False)

    def respond(self, track):
        # Query strings and percent-encoded/partial paths cannot select targets.
        # BaseHTTPRequestHandler normalizes a leading //; route the original
        # request target so only the documented exact path is accepted.
        path = self.requestline.split()[1]
        if path == "/health":
            self.reply(200, b'{"ok":true,"service":"kif-download-gateway"}', track)
            return
        prefix = "/downloads/"
        key = path[len(prefix):] if path.startswith(prefix) else ""
        target = self.server.links.get(key) if KEY.fullmatch(key) else None
        if target is None:
            self.reply(404, b'{"ok":false,"error":"not_found"}', track)
            return
        if track:
            ip = visitor_ip(self.client_address[0], self.headers.get("X-Forwarded-For"), self.server.trusted_proxies)
            self.server.tracker.submit(target, ip, self.headers.get("User-Agent", ""), self.headers.get("Accept-Language", ""))
        self.send_response(302)
        self.send_header("Location", target)
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def reply(self, status, body, include_body):
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if include_body:
            self.wfile.write(body)

    def log_message(self, format, *args):
        # Even unknown paths may contain attacker-supplied secrets; omit them.
        pass


def make_server(host, port, links, tracker, trusted_proxies=frozenset()):
    server = ThreadingHTTPServer((host, port), DownloadHandler)
    server.daemon_threads = True
    server.links, server.tracker, server.trusted_proxies = dict(links), tracker, trusted_proxies
    return server


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default=os.environ.get("GATEWAY_BIND", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("GATEWAY_PORT", "8080")))
    parser.add_argument("--links", default=os.environ.get("DOWNLOAD_LINKS_FILE", str(Path(__file__).with_name("downloads.json"))))
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    try:
        links = load_links(args.links)
        endpoint = checked_url(os.environ.get("MATOMO_TRACKER_URL", ""), os.environ.get("MATOMO_ALLOW_INTERNAL_HTTP") == "1")
        if urlsplit(endpoint).query:
            raise ValueError("Matomo endpoint cannot contain a query string")
        proxies = proxy_addresses(os.environ.get("TRUSTED_PROXY_IPS", ""))
        tracker = DownloadTracker(os.environ.get("MATOMO_DOWNLOAD_SITE_ID", ""), os.environ.get("MATOMO_DOWNLOAD_TOKEN_AUTH", ""), MatomoTransport(endpoint))
    except (OSError, ValueError):
        parser.exit(2, "Invalid gateway configuration. Check links, Matomo endpoint/site/token and proxy IPs.\n")
    try:
        server = make_server(args.host, args.port, links, tracker, proxies)
        try:
            LOG.info("Download gateway listening; %s allowlisted links", len(links))
            server.serve_forever(poll_interval=0.25)
        finally:
            server.server_close()
    except KeyboardInterrupt:
        pass
    finally:
        tracker.close()


if __name__ == "__main__":
    main()
