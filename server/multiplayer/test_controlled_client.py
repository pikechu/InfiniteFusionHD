from pathlib import Path
import subprocess
import threading
import time
import unittest
from unittest.mock import patch

import test_admin as fixtures
from service import make_server
from test_historical_v1_support import HistoricalV1Store


class ControlledRubyClientTests(unittest.TestCase):
    def setUp(self):
        with patch.object(fixtures, "Store", HistoricalV1Store):
            fixtures.AdminTests.setUp(self)
    tearDown = fixtures.AdminTests.tearDown
    register = fixtures.AdminTests.register
    login = fixtures.AdminTests.login

    def test_original_ruby_client_http_and_legacy_isolation(self):
        from native_rules import NativeRules
        root = Path(__file__).resolve().parents[2]
        ruby = root / "temp/tools/ruby-3.2.9/rubyinstaller-3.2.9-1-x64/bin/ruby.exe"
        if not ruby.is_file():
            self.skipTest("Standalone Ruby required for original client integration")
        self.store._original_engine = NativeRules(ruby=ruby)
        self.store.clock = time.time
        server = make_server("127.0.0.1", 0, self.store)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            result = subprocess.run([str(ruby), "--disable-gems", "tests/multiplayer/original_client_test.rb",
                "http://127.0.0.1:" + str(server.server_port), str(self.directory)], cwd=root, capture_output=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout.decode("utf-8", errors="replace") + result.stderr.decode("utf-8", errors="replace"))
            self.assertIn(b"ORIGINAL_CLIENT_HTTP_OPENING_AND_LEGACY_ISOLATION_PASS", result.stdout)
        finally:
            server.shutdown()
            server.server_close()
            worker.join()

    def test_adventure_ruby_http_cultivation_and_capture(self):
        root = Path(__file__).resolve().parents[2]
        ruby = root / "temp/tools/ruby-3.2.9/rubyinstaller-3.2.9-1-x64/bin/ruby.exe"
        if not ruby.is_file():
            self.skipTest("Standalone Ruby fixture runtime not installed")
        self.store.clock = time.time
        server = make_server("127.0.0.1", 0, self.store)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            with patch("controlled_engine.catch_shakes", return_value=4):
                result = subprocess.run([str(ruby), "--disable-gems", "tests/multiplayer/controlled_adventure_client_test.rb",
                    "http://127.0.0.1:" + str(server.server_port), str(self.directory)], cwd=root, capture_output=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout.decode("utf-8", errors="replace") + result.stderr.decode("utf-8", errors="replace"))
            self.assertIn(b"CONTROLLED_ADVENTURE_CLIENT_PASS checks=11", result.stdout)
        finally:
            server.shutdown()
            server.server_close()
            worker.join()

    def test_real_ruby_client_http_and_legacy_isolation(self):
        root = Path(__file__).resolve().parents[2]
        ruby = root / "temp/tools/ruby-3.2.9/rubyinstaller-3.2.9-1-x64/bin/ruby.exe"
        if not ruby.is_file():
            self.skipTest("Standalone Ruby fixture runtime not installed")
        server = make_server("127.0.0.1", 0, self.store)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            result = subprocess.run([str(ruby), "--disable-gems", "tests/multiplayer/controlled_client_test.rb",
                                     "http://127.0.0.1:" + str(server.server_port), str(self.directory)],
                                    cwd=root, capture_output=True, timeout=45)
            self.assertEqual(result.returncode, 0, result.stdout.decode("utf-8", errors="replace") + result.stderr.decode("utf-8", errors="replace"))
            self.assertIn(b"CONTROLLED_CLIENT_PASS checks=9", result.stdout)
        finally:
            server.shutdown()
            server.server_close()
            worker.join()
