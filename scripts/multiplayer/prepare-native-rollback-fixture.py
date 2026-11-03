"""Round-trip a real isolated Game.exe cloud file through the reviewed restore API."""
import json
from pathlib import Path
import sys
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "server/multiplayer"))
from admin_data import create_administrator, totp
from admin_saves import repair_legacy_money
from service import Store, PROTOCOL, RULES


def main():
    source = ROOT / "temp/multiplayer/controlled-native-save-20261022/saves/native-cloud-save.json"
    original = json.loads(source.read_text(encoding="utf-8"))
    revised = repair_legacy_money(original, 123456)
    directory = ROOT / "temp/native-whole-rollback" / uuid.uuid4().hex
    directory.mkdir(parents=True)
    store = Store(directory / "game.sqlite3")
    try:
        def request(method, path, body=None, token=None):
            status, result = store.request(method, path, body, token)
            assert status < 300, (path, status, result)
            return result
        player = request("POST", "/v1/auth/register", {"username": "native_restore_fixture", "password": "NativeRestoreFixture123", "protocol": PROTOCOL})
        token, owner = player["token"], player["identity"]["id"]
        session = "native_restore_" + uuid.uuid4().hex
        compat = {"protocol": PROTOCOL, "game_version": original["game_version"], "data_hash": "native-restore-fixture", "mods_hash": "none", "rules_version": RULES}
        request("POST", "/v1/cloud/open", {"session_id": session, "compatibility": compat}, token)
        for revision, document in enumerate((original, revised)):
            request("POST", "/v1/cloud/upload", {"session_id": session, "slot": "file-a", "revision": revision, "upload_id": uuid.uuid4().hex, "save": document}, token)
        managed = request("POST", "/v1/controlled/characters", {"request_id": uuid.uuid4().hex, "name": "Preserved role", "catalog_hash": store.controlled_catalog()["hash"]}, token)["character"]
        with store.connect() as db:
            for username in ("restore_initiator", "restore_reviewer"):
                create_administrator(db, username, "NativeRestoreAdmin123", "admin", "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP")
        def admin(username):
            return request("POST", "/admin/v1/login", {"username": username, "password": "NativeRestoreAdmin123", "otp": totp("JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP", store.clock())})["token"]
        initiator, reviewer = admin("restore_initiator"), admin("restore_reviewer")
        maintenance = request("POST", "/admin/v1/commands", {"id": uuid.uuid4().hex, "action": "begin_maintenance", "target": owner,
            "reason": "Native whole snapshot restore fixture", "expected_version": 0, "force": True}, initiator)["detail"]["maintenance_id"]
        proposal = {"id": uuid.uuid4().hex, "action": "request_save_rollback", "target": owner,
            "reason": "Native whole snapshot restore fixture", "expected_version": 1, "maintenance_id": maintenance,
            "slot": "file-a", "expected_revision": 2, "expected_sha256": revised["sha256"], "restore_revision": 1, "restore_sha256": original["sha256"]}
        request("POST", "/admin/v1/commands", proposal, initiator)
        settled = request("POST", "/admin/v1/commands", {"id": uuid.uuid4().hex, "action": "approve_save_rollback", "proposal_id": proposal["id"], "reason": "Independent native restore review"}, reviewer)
        with store.connect() as db:
            current = db.execute("SELECT revision,document FROM cloud_saves WHERE owner=? AND slot='file-a'", (owner,)).fetchone()
            restored = json.loads(current["document"])
            assert current["revision"] == 3 and restored == original
            assert store.shop_wallet(db, managed["id"], "GOLD")["balance"] == 1000
        output = directory / "restored-cloud-save.json"
        output.write_text(json.dumps(restored), encoding="utf-8")
        proof = {"cloud_revision": 3, "exact_historical_bytes": True, "sha256": restored["sha256"], "preserved_gold": 1000, "independent_review": True, "detail": settled["detail"]}
        (directory / "proof.json").write_text(json.dumps(proof, indent=2), encoding="utf-8")
        print("NATIVE_ROLLBACK_FIXTURE=" + str(output))
        print("NATIVE_ROLLBACK_API_PASS revision=3 preserved_gold=1000 exact_history=true")
    finally:
        store.close()


if __name__ == "__main__":
    main()
