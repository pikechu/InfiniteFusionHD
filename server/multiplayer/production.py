"""Production WSGI adapter. Own one Store/instance lock per application worker."""
import atexit
from collections import deque
from http import HTTPStatus
import ipaddress
import json
import logging
import os
from pathlib import Path
import re
import threading
import time

from production_data import Config, inspect_database
from service import Store, MAX_BODY, MAX_CLOUD_BODY, database_instance_lock, dumps

LOG = logging.getLogger("multiplayer.production")


class RateBudget:
    def __init__(self, seconds=10, max_keys=10000):
        self.seconds, self.max_keys = seconds, max_keys
        self.entries, self.lock = {}, threading.Lock()

    def allow(self, keys, now):
        with self.lock:
            self.entries = {key: item for key, item in self.entries.items() if item[0] > now - self.seconds}
            if len(self.entries) + sum(key not in self.entries for key, _ in keys) > self.max_keys:
                return False
            if any(self.entries.get(key, (now, 0))[1] >= maximum for key, maximum in keys):
                return False
            for key, _ in keys:
                started, count = self.entries.get(key, (now, 0))
                self.entries[key] = (started, count + 1)
            return True


class Application:
    def __init__(self, config):
        self.config = config
        self.data_id = config.data_id()
        # Take the fence before any Store startup recovery. A second worker must
        # fail without clearing the live instance's presence/battle state.
        self.fence = database_instance_lock(config.database)
        self.fence.__enter__()
        try:
            inspect_database(config.database, self.data_id)
            self.store = Store(config.database, synchronous="FULL", create=False)
        except BaseException:
            self.fence.__exit__(None, None, None)
            raise
        self.closed = False
        self.capacity = threading.BoundedSemaphore(8)
        self.budget = RateBudget()
        atexit.register(self.close)

    def close(self):
        if not self.closed:
            self.closed = True
            self.store.close()
            self.fence.__exit__(None, None, None)
            atexit.unregister(self.close)

    def __call__(self, environ, start_response):
        started = time.monotonic()
        status, response, path = 500, {"ok": False}, "invalid"
        acquired = self.capacity.acquire(blocking=False)
        try:
            if self.closed:
                status, response = self.error(503, "service_stopping", "Service is stopping")
            elif not acquired:
                status, response = self.error(503, "service_busy", "Service is busy; retry shortly")
            else:
                status, response, path = self.dispatch(environ)
        except (UnicodeError, ValueError, RecursionError):
            status, response = self.error(400, "invalid_json", "Invalid UTF-8 JSON request")
        except (TimeoutError, OSError):
            status, response = self.error(408, "request_timeout", "Request could not be read")
        except Exception:
            # Do not log exception strings, locals, headers or bodies: an HTTP
            # parser/KDF failure can otherwise expose credentials in tracebacks.
            LOG.error("Unhandled production request failure")
            status, response = self.error(500, "internal_error", "Internal service error")
        finally:
            if acquired:
                self.capacity.release()
        raw = dumps(response).encode("utf-8")
        headers = [("Content-Type", "application/json; charset=utf-8"), ("Content-Length", str(len(raw))),
                   ("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff")]
        if status in (429, 503):
            headers.append(("Retry-After", "5"))
        start_response(str(status) + " " + HTTPStatus(status).phrase, headers)
        LOG.info("request path=%s status=%d duration_ms=%d", path, status, (time.monotonic() - started) * 1000)
        return [raw]

    @staticmethod
    def error(status, code, message):
        return status, {"ok": False, "error": {"code": code, "message": message}}

    def dispatch(self, environ):
        def reject(status, code, message):
            return (*self.error(status, code, message), "invalid")

        try:
            remote = ipaddress.ip_address(environ.get("REMOTE_ADDR", ""))
        except ValueError:
            return reject(403, "proxy_required", "Trusted local proxy required")
        if not remote.is_loopback:
            return reject(403, "proxy_required", "Trusted local proxy required")
        # This single, non-list header is always overwritten by our Caddy
        # configuration. Arbitrary X-Forwarded-For chains are never accepted.
        try:
            peer = str(ipaddress.ip_address(environ.get("HTTP_X_KIF_CLIENT_IP", "")))
        except ValueError:
            return reject(400, "invalid_client_ip", "Validated proxy client address required")
        method, path = environ.get("REQUEST_METHOD", ""), environ.get("PATH_INFO", "")
        if method not in ("GET", "POST"):
            return reject(405, "invalid_method", "Use GET or POST")
        if (len(path) > 2048 or not re.fullmatch(r"/v1/[A-Za-z0-9_/-]+", path) or
                "//" in path or environ.get("QUERY_STRING")):
            return reject(400, "invalid_path", "Invalid API path")
        authorization = environ.get("HTTP_AUTHORIZATION", "")
        if len(authorization) > 520:
            return reject(400, "invalid_authorization", "Invalid authorization header")
        token = authorization[7:] if authorization.startswith("Bearer ") else None
        keys = [("ip:" + peer, 1000)]
        if token:
            import hashlib
            keys.append(("token:" + hashlib.sha256(token.encode()).hexdigest(), 50))
        if not self.budget.allow(keys, time.monotonic()):
            return reject(429, "request_rate_limited", "Request rate exceeded; retry shortly")
        body = {}
        if environ.get("HTTP_TRANSFER_ENCODING"):
            return reject(400, "invalid_encoding", "Use a fixed Content-Length")
        if method == "POST":
            length = environ.get("CONTENT_LENGTH", "")
            if not re.fullmatch(r"[0-9]{1,10}", length):
                return reject(411, "content_length_required", "Content-Length required")
            length = int(length)
            maximum = MAX_CLOUD_BODY if path == "/v1/cloud/upload" else MAX_BODY
            if not 0 < length <= maximum:
                return reject(413, "body_too_large", "Request body exceeds endpoint limit")
            if environ.get("CONTENT_TYPE", "").split(";", 1)[0].strip().lower() != "application/json":
                return reject(415, "content_type", "Use application/json")
            raw = environ["wsgi.input"].read(length)
            if len(raw) != length:
                return reject(400, "truncated_body", "Incomplete request body")
            body = json.loads(raw.decode("utf-8"), parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        elif environ.get("CONTENT_LENGTH", "") not in ("", "0"):
            return reject(400, "unexpected_body", "GET body is not supported")
        status, response = self.store.request(method, path, body, token, peer)
        return status, response, path


def create_app():
    config = Config.load(os.environ.get("KIF_CONFIG", "/etc/kif-mmo/production.json"))
    if not LOG.handlers:
        handler = logging.StreamHandler()
        handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
        LOG.addHandler(handler)
    LOG.setLevel(logging.INFO)
    LOG.propagate = False
    return Application(config)
