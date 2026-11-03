"""Original Ruby rules and the private Python/Ruby process boundary."""
import json
import os
from pathlib import Path
import subprocess
import unittest
import threading
import uuid
import shutil
from unittest.mock import patch

try:
    from .native_rules import NativeRules, NativeRulesError
except ImportError:
    from native_rules import NativeRules, NativeRulesError

ROOT = Path(__file__).resolve().parents[2]
RUBY = os.environ.get("KIF_MULTIPLAYER_RUBY") or str(ROOT / "temp/tools/ruby-3.2.9/rubyinstaller-3.2.9-1-x64/bin/ruby.exe")


class NativeBoundaryTests(unittest.TestCase):
    def test_missing_runtime_fails_closed(self):
        with self.assertRaisesRegex(NativeRulesError, "native_ruby_unavailable"):
            NativeRules(ruby=ROOT / "missing-native-ruby.exe").call("catalog")

    def test_busy_worker_rejects_without_unbounded_queueing(self):
        engine = NativeRules(ruby=RUBY)
        entered,release = threading.Event(),threading.Event()
        def hold():
            with engine._lock:
                entered.set()
                release.wait(5)
        worker = threading.Thread(target=hold)
        worker.start()
        try:
            self.assertTrue(entered.wait(1))
            with self.assertRaisesRegex(NativeRulesError,"native_rules_busy"):
                engine.call("catalog")
            self.assertIsNone(engine._process)
        finally:
            release.set()
            worker.join(2)
            engine.close()

    def test_rulebook_release_pinning_and_missing_history_fail_closed(self):
        from native_rulebooks import NativeRulebooks
        base = ROOT/"temp/native-rulebook-tests"
        directory = base/uuid.uuid4().hex
        archived = directory/"123456789abc-123456789abc"
        archived.mkdir(parents=True)
        historical = "a"*64
        (archived/"release.json").write_text(json.dumps({"format":"kif-mmo-release-v1","native_rules_hash":historical}))
        created = []
        class Engine:
            def __init__(self,ruby=None,root=None):
                self.ruby,self.root,self.closed = ruby,Path(root),False
                created.append(self)
            def call(self,operation,**arguments):
                return {"rules_hash":historical if self.root==archived else "f"*64,"result":{"operation":operation,"root":str(self.root)}}
            def close(self):
                self.closed=True
        try:
            with patch("native_rulebooks.NativeRules",Engine):
                registry = NativeRulebooks(ruby=RUBY,root=ROOT,archives=directory)
                self.assertEqual(registry.call("catalog")["rules_hash"],"f"*64)
                self.assertEqual(registry.call("world_step",rules_hash=historical)["result"]["root"],str(archived))
                self.assertEqual(registry.call("world_step",rules_hash=historical)["rules_hash"],historical)
                with self.assertRaisesRegex(NativeRulesError,"native_rulebook_unavailable"):
                    registry.call("world_step",rules_hash="b"*64)
                registry.close()
                self.assertEqual(len(created),2)
                self.assertTrue(all(engine.closed for engine in created))
        finally:
            assert directory.resolve().parent==base.resolve()
            shutil.rmtree(directory)


@unittest.skipUnless(Path(RUBY).is_file(), "Standalone Ruby required for original rules integration")
class NativeRulesTests(unittest.TestCase):
    def setUp(self):
        self.engine = NativeRules(ruby=RUBY)
        self.addCleanup(self.engine.close)

    def test_original_rules_and_cultivation(self):
        result = subprocess.run([RUBY, "--disable-gems", "tests/multiplayer/original_rules_test.rb"],
                                cwd=ROOT, capture_output=True, text=True, encoding="utf-8", timeout=60,
                                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("ORIGINAL_RULES_PASS checks=", result.stdout)

    def test_native_dialogues_mart_and_blackout(self):
        for name in ("original_ui_test.rb", "original_mart_test.rb", "original_map_client_test.rb", "original_storage_test.rb", "original_slots_test.rb", "original_scale_test.rb", "original_npc_test.rb", "original_field_test.rb", "original_activities_test.rb", "original_recovery_test.rb"):
            with self.subTest(script=name):
                result = subprocess.run([RUBY, "--disable-gems", "tests/multiplayer/" + name],
                                        cwd=ROOT, capture_output=True, text=True, encoding="utf-8", timeout=60,
                                        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_original_mainline_starter_rival_delivery_and_capture(self):
        result = subprocess.run([RUBY, "--disable-gems", "tests/multiplayer/original_world_journey_test.rb"],
                                cwd=ROOT, capture_output=True, text=True, encoding="utf-8", timeout=180,
                                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("ORIGINAL_WORLD_STARTER_RIVAL_DELIVERY_AND_CAPTURE_PASS", result.stdout)

    def test_create_and_resume_are_private_deterministic_state(self):
        created = self.engine.call("create", time=1792713600, seed=1234,
                                   starter="BULBASAUR", name="Original", money=1000)
        state, view = created["result"]["state"], created["result"]["view"]
        self.assertEqual(view["money"], 1000)
        self.assertEqual(view["party"][0]["species"], "BULBASAUR")
        self.assertTrue(view["party"][0]["ability"])
        self.assertNotIn("state", view)
        document = dict(initial=state, time=1792713600, seed=1234,
                        encounter=dict(kind="wild", party=[dict(species="MAGIKARP", level=1)]), inputs=[])
        first = self.engine.call("battle", rules_hash=created["rules_hash"], battle=document)["result"]
        resumed = self.engine.call("battle", rules_hash=created["rules_hash"], battle=document)["result"]
        self.assertEqual(first, resumed)
        self.assertEqual(first["prompt"], {"kind": "command", "battler": 0})
        self.assertIsNone(first["state"])
        document["inputs"].append(dict(prompt=first["prompt"], value=0))
        second = self.engine.call("battle", rules_hash=created["rules_hash"], battle=document)["result"]
        self.assertEqual(second["prompt"]["kind"], "move")
        document["inputs"][0]["prompt"] = {"kind": "item"}
        with self.assertRaisesRegex(NativeRulesError, "native_prompt_conflict"):
            self.engine.call("battle", rules_hash=created["rules_hash"], battle=document)

    def test_changed_rules_are_not_silently_used(self):
        with self.assertRaisesRegex(NativeRulesError, "native_rules_changed"):
            self.engine.call("catalog", rules_hash="0" * 64)

    def test_native_catalog_does_not_filter_moves(self):
        result = self.engine.call("catalog")["result"]
        self.assertEqual(len(result["moves"]), 680)
        self.assertEqual(result["abilities"], 233)
        self.assertEqual(result["evolution_methods"], 60)
        self.assertIn("METRONOME", {move["id"] for move in result["moves"]})

    def test_original_world_opening_replays_and_survives_worker_restart(self):
        created = self.engine.call("world_create", time=1792713600, seed=100,
                                   name="Original", money=1000)
        document = dict(initial=created["result"]["state"], time=1792713600, seed=200,
                        wallet_balance=1000, action=dict(kind="wait"), inputs=[])
        result = self.engine.call("world_step", rules_hash=created["rules_hash"], world=document)["result"]
        for _ in range(30):
            if result["state"]:
                break
            prompt = result["prompt"]
            if prompt["kind"] == "choice":
                choices = prompt["choices"]
                value = choices.index("Confirm") if "Confirm" in choices else choices.index("Normal") if "Normal" in choices else 0
            elif prompt["kind"] == "confirm":
                value = True
            elif prompt["kind"] == "name":
                value = "Original"
            else:
                self.fail("Unexpected original opening prompt: " + str(prompt))
            document["inputs"].append(dict(prompt=prompt, value=value))
            result = self.engine.call("world_step", rules_hash=created["rules_hash"], world=document)["result"]
        self.assertTrue(result["state"])
        self.assertEqual(result["view"]["world"]["map_id"], 157)
        self.assertEqual(result["view"]["money"], 1000)
        self.assertEqual(result["money_delta"], 0)
        self.assertEqual(result["view"]["party"], [])
        self.engine.close()
        replayed = self.engine.call("world_step", rules_hash=created["rules_hash"], world=document)["result"]
        self.assertEqual(replayed, result)


if __name__ == "__main__":
    unittest.main()
