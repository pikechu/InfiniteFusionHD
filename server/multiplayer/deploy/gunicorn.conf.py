"""A single Store worker. Reload/preload would violate database recovery fencing."""
import os

bind = "127.0.0.1:8765"
workers = 1
worker_class = "gthread"
threads = 4
worker_connections = 32
backlog = 32
preload_app = False
reload = False
max_requests = 0
timeout = 30
graceful_timeout = 25
keepalive = 5
limit_request_line = 2048
limit_request_fields = 32
limit_request_field_size = 4096
forwarded_allow_ips = "127.0.0.1,::1"
accesslog = None  # The WSGI adapter emits only validated path/status/duration.
errorlog = "-"
capture_output = True
loglevel = "info"
wsgi_app = "production:create_app()"


def on_starting(server):
    if server.cfg.workers != 1 or server.cfg.preload_app or server.cfg.reload:
        raise RuntimeError("KIF requires one non-preloaded worker with reload disabled")


def worker_exit(server, worker):
    application = getattr(worker, "wsgi", None)
    if application is not None and hasattr(application, "close"):
        application.close()
