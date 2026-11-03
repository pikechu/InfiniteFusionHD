"""Run existing characters with their immutable installed rulebook release."""
import json
import os
from pathlib import Path
import re
import threading

try:
    from .native_rules import NativeRules, NativeRulesError
except ImportError:
    from native_rules import NativeRules, NativeRulesError


class NativeRulebooks:
    def __init__(self, ruby=None, root=None, archives=None):
        self.current = NativeRules(ruby=ruby, root=root)
        self.current_hash = None
        self.archives = archives or os.environ.get("KIF_MULTIPLAYER_RULEBOOKS")
        self.engines = {}
        self.lock = threading.RLock()

    def archived(self, rules_hash):
        with self.lock:
            if rules_hash in self.engines:
                return self.engines[rules_hash]
            if not self.archives:
                raise NativeRulesError("native_rulebook_unavailable")
            base = Path(self.archives).resolve()
            if not base.is_dir():
                raise NativeRulesError("native_rulebook_unavailable")
            for root in sorted(base.iterdir(), reverse=True):
                if not re.fullmatch(r"[a-f0-9]{12}-[a-f0-9]{12}", root.name) or not root.is_dir():
                    continue
                root = root.resolve()
                if not root.is_relative_to(base) or root == self.current.root.resolve():
                    continue
                metadata = root / "release.json"
                try:
                    if metadata.stat().st_size > 4*1024*1024:
                        continue
                    record = json.loads(metadata.read_text(encoding="utf-8"))
                except (OSError, ValueError):
                    continue
                if record.get("format") != "kif-mmo-release-v1" or record.get("native_rules_hash") != rules_hash:
                    continue
                if len(self.engines) >= 4:
                    raise NativeRulesError("native_rulebook_capacity")
                engine = NativeRules(ruby=self.current.ruby, root=root)
                # Releases are administrator-installed, read-only code. The
                # worker checks its actual source hash before any role state.
                self.engines[rules_hash] = engine
                return engine
            raise NativeRulesError("native_rulebook_unavailable")

    def call(self, operation, *, rules_hash=None, **arguments):
        if self.current_hash is None:
            catalog = self.current.call("catalog")
            self.current_hash = catalog["rules_hash"]
            if operation == "catalog" and not rules_hash:
                return catalog
        engine = self.current if not rules_hash or rules_hash == self.current_hash else self.archived(rules_hash)
        return engine.call(operation, rules_hash=rules_hash, **arguments)

    def close(self):
        self.current.close()
        with self.lock:
            engines = list(self.engines.values())
            self.engines.clear()
        for engine in engines:
            engine.close()
