import http.client
import json
from pathlib import Path
import threading
import time
import unittest
import uuid
from urllib.error import HTTPError
from urllib.parse import parse_qs
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import download_gateway as gateway


class GatewayTests(unittest.TestCase):
    def setUp(self):
        self.received = []
        self.tracker = gateway.DownloadTracker(2, "test-server-token", self.received.append)
        self.server = gateway.make_server("127.0.0.1", 0, {"windows": "https://downloads.example/game.zip"}, self.tracker)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.tracker.close()

    def request(self, path, method="GET", headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=2)
        connection.request(method, path, headers=headers or {})
        response = connection.getresponse()
        result = response.status, dict(response.getheaders()), response.read()
        connection.close()
        return result

    def wait_tracking(self):
        self.tracker.pending.join()

    def test_redirect_records_download_and_never_exposes_token(self):
        status, headers, body = self.request("/downloads/windows", headers={"User-Agent": "test-device", "Accept-Language": "zh-CN", "X-Forwarded-For": "203.0.113.5"})
        self.assertEqual(status, 302)
        self.assertEqual(headers["Location"], "https://downloads.example/game.zip")
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(body, b"")
        self.assertNotIn("test-server-token", repr(headers))
        self.wait_tracking()
        self.assertEqual(len(self.received), 1)
        event = self.received[0]
        self.assertEqual(event["download"], headers["Location"])
        self.assertEqual(event["idsite"], "2")
        self.assertEqual(event["cip"], "127.0.0.1")
        self.assertEqual(event["ua"], "test-device")
        self.assertEqual(event["lang"], "zh-CN")

    def test_head_health_unknown_and_query_do_not_track(self):
        self.assertEqual(self.request("/downloads/windows", "HEAD")[0], 302)
        self.assertEqual(json.loads(self.request("/health")[2])["ok"], True)
        for path in ("/downloads/missing", "/downloads/windows?target=https://evil.example", "/downloads/%77indows", "/downloads/windows/", "//downloads/windows"):
            self.assertEqual(self.request(path)[0], 404)
        self.wait_tracking()
        self.assertEqual(self.received, [])

    def test_blocked_transport_does_not_delay_redirect(self):
        entered, release = threading.Event(), threading.Event()
        def blocked(payload):
            entered.set()
            release.wait(timeout=2)
        self.tracker.transport = blocked
        try:
            started = time.monotonic()
            self.assertEqual(self.request("/downloads/windows")[0], 302)
            self.assertLess(time.monotonic() - started, 1)
            self.assertTrue(entered.wait(timeout=1))
        finally:
            release.set()
            self.wait_tracking()

    def test_tracker_failure_does_not_fail_redirect_or_kill_worker(self):
        def fail(payload):
            raise OSError("do not log payload")
        self.tracker.transport = fail
        with self.assertLogs(gateway.LOG, level="WARNING") as captured:
            self.assertEqual(self.request("/downloads/windows")[0], 302)
            self.wait_tracking()
        self.assertNotIn("test-server-token", str(captured.output))
        self.tracker.transport = self.received.append
        self.assertEqual(self.request("/downloads/windows")[0], 302)
        self.wait_tracking()
        self.assertEqual(len(self.received), 1)

    def test_trusted_proxy_resolves_last_untrusted_address(self):
        self.server.trusted_proxies = gateway.proxy_addresses("127.0.0.1, 192.0.2.10")
        self.request("/downloads/windows", headers={"X-Forwarded-For": "198.51.100.8, 203.0.113.5, 192.0.2.10"})
        self.wait_tracking()
        self.assertEqual(self.received[0]["cip"], "203.0.113.5")
        self.assertEqual(gateway.visitor_ip("127.0.0.1", "garbage", self.server.trusted_proxies), "127.0.0.1")

    def test_queue_is_bounded_and_headers_are_limited(self):
        tracker = gateway.DownloadTracker(2, "test-token", lambda payload: None, start_worker=False)
        for _ in range(gateway.QUEUE_CAPACITY):
            self.assertTrue(tracker.submit("https://example.org/a.zip", "127.0.0.1", "x" * 800, "y" * 200))
        self.assertFalse(tracker.submit("https://example.org/a.zip", "127.0.0.1", "", ""))
        payload = tracker.pending.get_nowait()
        self.assertEqual(len(payload["ua"]), 512)
        self.assertEqual(len(payload["lang"]), 128)
        tracker.pending.put_nowait(payload)
        self.server.tracker = tracker
        self.assertEqual(self.request("/downloads/windows")[0], 302)
        self.assertEqual(tracker.pending.qsize(), gateway.QUEUE_CAPACITY)


class ConfigurationTests(unittest.TestCase):
    def test_invalid_links_rejected_at_startup(self):
        temporary_root = Path(__file__).resolve().parents[2] / "temp" / "analytics-tests"
        temporary_root.mkdir(parents=True, exist_ok=True)
        path = temporary_root / ("downloads-" + uuid.uuid4().hex + ".json")
        try:
            for config in ('{}', '{"x":"http://example.org/a.zip"}', '{"../x":"https://example.org/a.zip"}', '{"x":"https://user:secret@example.org/a.zip"}', '{"x":"https://example.org/a\\r\\nInjected: yes"}', '{"x":"https://example.org","x":"https://example.org/other"}'):
                path.write_text(config, encoding="utf-8")
                with self.assertRaises(ValueError):
                    gateway.load_links(path)
            path.write_text('{"windows":"https://example.org/a.zip"}', encoding="utf-8")
            self.assertEqual(gateway.load_links(path)["windows"], "https://example.org/a.zip")
        finally:
            path.unlink(missing_ok=True)

    def test_internal_http_requires_explicit_switch_and_private_host(self):
        for url in ("http://matomo/matomo.php", "http://127.0.0.1:8081/matomo.php"):
            with self.assertRaises(ValueError):
                gateway.checked_url(url)
            self.assertEqual(gateway.checked_url(url, True), url)
        with self.assertRaises(ValueError):
            gateway.checked_url("http://public.example/matomo.php", True)
        for url in ("https://example.org:0/a", "https://example.org:99999/a", "https://example.org/#fragment", "https://example.org\\@evil.org/a"):
            with self.assertRaises(ValueError):
                gateway.checked_url(url)

    def test_site_token_and_proxy_configuration_validation(self):
        for site_id in (None, 0, -1, True, "garbage"):
            with self.assertRaises(ValueError):
                gateway.DownloadTracker(site_id, "test-token", lambda payload: None)
        with self.assertRaises(ValueError):
            gateway.DownloadTracker(2, "", lambda payload: None)
        with self.assertRaises(ValueError):
            gateway.proxy_addresses("not-an-ip")

    def test_transport_posts_form_with_timeout_and_rejects_redirect(self):
        observed = []
        class EmptyResponse:
            status = 204
            def __enter__(self):
                return self
            def __exit__(self, *args):
                pass
            def read(self, limit):
                observed.append(limit)
                return b""
        class RecordingOpener:
            def open(self, request, timeout):
                observed.append((request.get_method(), timeout, request.headers["Content-type"]))
                return EmptyResponse()
        transport = gateway.MatomoTransport("https://stats.example.org/matomo.php")
        transport.opener = RecordingOpener()
        transport({"idsite": "2", "rec": "1"})
        self.assertEqual(observed, [("POST", 2, "application/x-www-form-urlencoded"), 1024])
        received = []
        class MockHandler(BaseHTTPRequestHandler):
            def do_POST(self):
                received.append(parse_qs(self.rfile.read(int(self.headers["Content-Length"])).decode()))
                self.send_response(302)
                self.send_header("Location", "/must-not-follow")
                self.send_header("Content-Length", "0")
                self.end_headers()
            def do_GET(self):
                received.append("redirect-followed")
                self.send_response(200)
                self.end_headers()
            def log_message(self, *args):
                pass
        server = ThreadingHTTPServer(("127.0.0.1", 0), MockHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            # This loopback-only mock intentionally avoids an external collector.
            transport = gateway.MatomoTransport("http://127.0.0.1:%s/matomo.php" % server.server_port)
            with self.assertRaises(HTTPError):
                transport({"token_auth": "test-token", "download": "https://example.org/a.zip"})
            self.assertEqual(len(received), 1)
            self.assertEqual(received[0]["token_auth"], ["test-token"])
            self.assertEqual(gateway.TRACKER_TIMEOUT, 2)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
