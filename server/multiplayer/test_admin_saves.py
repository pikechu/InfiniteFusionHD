import json
import base64
import copy
import hashlib
import zlib
import unittest
import uuid

import test_admin as fixtures
from admin_data import summarize_save
from admin_saves import repair_legacy_money


class AdminSaveTests(unittest.TestCase):
    register = fixtures.AdminTests.register
    login = fixtures.AdminTests.login
    request = fixtures.AdminTests.request
    command = fixtures.AdminTests.command
    game = fixtures.AdminTests.game
    setUp = fixtures.AdminTests.setUp
    tearDown = fixtures.AdminTests.tearDown

    def upload(self, slot="file-a", revision=0, money=12345):
        return self.game("cloud/upload", {"session_id": self.session, "slot": slot, "revision": revision,
            "upload_id": uuid.uuid4().hex, "save": fixtures.save_fixture(money)})

    def open(self):
        self.game("cloud/open", {"session_id": self.session, "compatibility": self.compat})

    def test_maintenance_fences_writers_and_repair_keeps_pinned_before_image(self):
        self.open()
        self.upload()
        self.request("commands", self.command("begin_maintenance"), expected=409)
        begin = self.command("begin_maintenance", force=True)
        maintenance = self.request("commands", begin)
        self.assertEqual(self.request("commands", begin), maintenance)
        maintenance_id = maintenance["detail"]["maintenance_id"]
        self.game("cloud/upload", {}, expected=401)
        status, result = self.store.request("POST", "/v1/auth/login", {"username": "alice", "password": "PlayerPassword123", "protocol": 2})
        self.assertEqual(status, 409, result)
        self.assertEqual(result["error"]["code"], "account_maintenance")
        repair = self.command("repair_save_money", expected_version=1, maintenance_id=maintenance_id, slot="file-a", expected_revision=1, money=999)
        result = self.request("commands", repair)
        self.assertEqual(result["detail"]["revision"], 2)
        self.assertEqual(self.request("commands", repair), result)
        self.store.refresh_admin_summaries()
        detail = self.request("players/" + self.owner)
        self.assertEqual(detail["saves"][0]["summary"]["money"], 999)
        self.assertEqual(self.request("economy")["player_total"], 0)
        history = self.request("save-history?owner=" + self.owner + "&slot=file-a")["versions"]
        self.assertEqual([item["revision"] for item in history], [2, 1])
        self.assertEqual(history[1]["pinned"], 1)
        self.request("commands", self.command("end_maintenance", expected_version=2, maintenance_id=maintenance_id))
        status, self.alice = self.store.request("POST", "/v1/auth/login", {"username": "alice", "password": "PlayerPassword123", "protocol": 2})
        self.assertEqual(status, 200)
        self.open()
        self.assertEqual(self.game("cloud/download", {"session_id": self.session, "slot": "file-a"})["revision"], 2)

    def test_repair_rejects_wrong_session_stale_revision_and_game_money_limit(self):
        self.open()
        self.upload()
        maintenance = self.request("commands", self.command("begin_maintenance", force=True))
        maintenance_id = maintenance["detail"]["maintenance_id"]
        instruction = self.command("repair_save_money", expected_version=1, maintenance_id="wrong", slot="file-a", expected_revision=1, money=999)
        self.request("commands", instruction, expected=409)
        instruction.update(id=uuid.uuid4().hex, maintenance_id=maintenance_id, expected_revision=2)
        self.request("commands", instruction, expected=409)
        instruction.update(expected_revision=1, money=1000000)
        self.request("commands", instruction, expected=400)
        instruction.update(money=999999)
        self.request("commands", instruction)
        self.request("commands", self.command("end_maintenance", expected_version=2, maintenance_id="wrong"), expected=409)

    def test_character_grouping_counts_canonical_snapshot_once(self):
        self.open()
        self.upload(money=100)
        self.upload("auto-1", money=120)
        self.store.refresh_admin_summaries()
        report = self.request("overview")["mainline_gold"]
        self.assertIsNone(report["value"])
        self.assertEqual(report["unresolved_slots"], 2)
        grouped = self.request("commands", self.command("group_character", slots=["file-a", "auto-1"], canonical_slot="file-a"))
        self.assertTrue(grouped["detail"]["character_id"].startswith("char_"))
        report = self.request("overview")["mainline_gold"]
        self.assertEqual((report["value"], report["covered_characters"], report["unresolved_slots"]), (100, 1, 0))
        self.assertEqual(report["source"], "untrusted_cloud_snapshot")
        self.assertEqual(len(self.request("players/" + self.owner)["characters"]), 1)
        self.request("commands", self.command("group_character", expected_version=1, slots=["file-a"], canonical_slot="file-a"), expected=409)

    def test_history_rotates_recent_versions_and_unknown_slots_cannot_be_grouped(self):
        self.open()
        for revision in range(6):
            self.upload(revision=revision)
        history = self.request("save-history?owner=" + self.owner + "&slot=file-a")["versions"]
        self.assertEqual([entry["revision"] for entry in history], [6, 5, 4])
        self.request("commands", self.command("group_character", slots=["file-a", "file-b"], canonical_slot="file-a"), expected=404)
        self.assertEqual(self.request("players/" + self.owner)["characters"], [])

    def test_observer_cannot_maintain_or_repair_and_audit_failure_rolls_back(self):
        self.open()
        self.upload()
        reader = self.login("reader")
        self.request("commands", self.command("begin_maintenance", force=True), person=reader, expected=403)
        with self.store.connect() as db:
            db.execute("CREATE TRIGGER reject_maintenance BEFORE INSERT ON admin_audit WHEN NEW.action='begin_maintenance' BEGIN SELECT RAISE(ABORT,'audit failed'); END")
        import sqlite3
        with self.assertRaises(sqlite3.IntegrityError):
            self.request("commands", self.command("begin_maintenance", force=True))
        self.assertEqual(self.store.request("GET", "/v1/identity", token=self.alice["token"])[0], 200)
        self.assertIsNone(self.request("players/" + self.owner)["maintenance"])

    def test_kuray_player_precedes_vanilla_clone_and_repair_updates_both_views(self):
        document = fixtures.save_fixture(100)
        graph = json.loads(zlib.decompress(base64.b64decode(document["payload"])))
        active = copy.deepcopy(graph["nodes"][1])
        active["ivars"]["@money"] = 500
        active_index = len(graph["nodes"])
        graph["nodes"].append(active)
        graph["nodes"][0]["items"].append([{"symbol": "kuray_player"}, {"ref": active_index}])
        raw = zlib.compress(json.dumps(graph).encode())
        document.update(payload=base64.b64encode(raw).decode(), sha256=hashlib.sha256(raw).hexdigest())
        self.assertEqual(summarize_save(document)["money"], 500)
        repaired = repair_legacy_money(document, 123456)
        restored = json.loads(zlib.decompress(base64.b64decode(repaired["payload"])))
        self.assertEqual(restored["nodes"][1]["ivars"]["@money"], 123456)
        self.assertEqual(restored["nodes"][active_index]["ivars"]["@money"], 123456)
        self.assertEqual(summarize_save(document)["money"], 500, "Repair mutated the caller's original document")


if __name__ == "__main__":
    unittest.main()
