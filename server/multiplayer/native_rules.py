"""Private adapter to the original Ruby rules. Never accepts client save blobs.

The Ruby executable is an operator setting, not a request parameter. Workers
have bounded input/lifetime, fresh globals, no network listener and use only
trusted repository scripts and local data. Public routes must validate intents
before invoking this class and must not expose its private state or seed.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import queue
import threading


class NativeRulesError(RuntimeError):
    pass


class NativeRules:
    def __init__(self, ruby=None, root=None, timeout=20):
        self.root = Path(root) if root else Path(__file__).resolve().parents[2]
        self.ruby = ruby or os.environ.get("KIF_MULTIPLAYER_RUBY") or shutil.which("ruby")
        self.timeout = timeout
        self._process = None
        self._responses = None
        self._lock = threading.RLock()

    def close(self):
        with self._lock:
            process, self._process = self._process, None
            self._responses = None
            if process is not None:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=5)
                process.stdin.close()
                # Reader threads own their pipes. Closing a buffered stream
                # concurrently can deadlock on its outstanding read lock.

    def _start(self):
        if self._process is not None and self._process.poll() is None:
            return
        self.close()
        environment = {key: value for key, value in os.environ.items()
                       if key.upper() in ("SYSTEMROOT", "WINDIR", "TEMP", "TMP", "LANG", "TZ")}
        environment.update(RUBYOPT="", RUBYLIB="", LANG="C.UTF-8", TZ="Asia/Shanghai")
        process = subprocess.Popen([str(self.ruby), "--disable-gems", str(self.root / "server/multiplayer/native/worker.rb"), "--stdio-loop"],
                                   cwd=self.root, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env=environment, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        responses = queue.Queue(maxsize=2)
        self._process, self._responses = process, responses

        def read_responses():
            try:
                while True:
                    line = process.stdout.readline(16 * 1024 * 1024 + 1)
                    try:
                        responses.put(line, timeout=1)
                    except queue.Full:
                        if process.poll() is None:
                            process.kill()
                        return
                    if not line or len(line) > 16 * 1024 * 1024 or not line.endswith(b"\n"):
                        return
            finally:
                process.stdout.close()

        def drain_diagnostics():
            try:
                while process.stderr.read(4096):
                    pass  # never log private native state or player data
            finally:
                process.stderr.close()

        threading.Thread(target=read_responses, daemon=True).start()
        threading.Thread(target=drain_diagnostics, daemon=True).start()

    def call(self, operation, *, rules_hash=None, **arguments):
        if not self.ruby or not Path(self.ruby).is_file():
            raise NativeRulesError("native_ruby_unavailable")
        request = dict(arguments, operation=operation, protocol=1)
        if rules_hash:
            request["rules_hash"] = rules_hash
        payload = json.dumps(request, ensure_ascii=False, allow_nan=False).encode("utf-8")
        if len(payload) > 16 * 1024 * 1024:
            raise NativeRulesError("native_request_limit")
        if not self._lock.acquire(timeout=1):
            raise NativeRulesError("native_rules_busy")
        try:
            try:
                self._start()
                self._process.stdin.write(payload + b"\n")
                self._process.stdin.flush()
                raw = self._responses.get(timeout=self.timeout)
                if len(raw) > 16 * 1024 * 1024:
                    raise NativeRulesError("native_response_limit")
                result = json.loads(raw)
                if result.get("protocol") != 1 or not result.get("ok"):
                    raise NativeRulesError(result.get("message", "native_rules_failed"))
                if rules_hash and result["rules_hash"] != rules_hash:
                    raise NativeRulesError("native_rules_changed")
                return result
            except queue.Empty as error:
                self.close()
                raise NativeRulesError("native_rules_timeout") from error
            except (OSError, BrokenPipeError) as error:
                self.close()
                raise NativeRulesError("native_ruby_unavailable") from error
            except (ValueError, KeyError, TypeError) as error:
                self.close()
                raise NativeRulesError("native_invalid_response") from error
        finally:
            self._lock.release()
