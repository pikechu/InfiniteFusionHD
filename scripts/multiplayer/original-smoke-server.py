"""Loopback-only original-game fixture on a disposable database."""
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid
import argparse
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "server/multiplayer"))
from service import Store, PROTOCOL, make_server
from native_rules import NativeRules


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--pending-rival", action="store_true")
    parser.add_argument("--state", choices=("before_rival","after_capture"), default="before_rival")
    arguments = parser.parse_args()
    directory = ROOT / "temp/original-smoke" / uuid.uuid4().hex
    directory.mkdir(parents=True)
    engine = NativeRules()
    if not engine.ruby:
        raise RuntimeError("Set the explicit standalone Ruby runtime")
    fixture_path = directory / "natural.json"
    subprocess.run([str(engine.ruby), "--disable-gems", "tests/multiplayer/original_world_journey_test.rb", str(fixture_path)],
                   cwd=ROOT, stdout=(directory / "journey.log").open("w", encoding="utf-8"), check=True, timeout=180,
                   creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
    store = Store(directory / "game.sqlite3")
    store._original_engine = engine
    status, account = store.request("POST", "/v1/auth/register", {"username": "original_game", "password": "OriginalNativeFixture123", "protocol": PROTOCOL})
    assert status == 201
    token = account["token"]
    status, created = store.request("POST", "/v1/controlled/characters", {"request_id": uuid.uuid4().hex, "name": "原版原生验证", "catalog_hash": store.controlled_catalog()["hash"]}, token)
    assert status == 200
    character = created["character"]
    status, _ = store.request("POST", "/v1/controlled/characters/" + character["id"] + "/original", {
        "request_id": uuid.uuid4().hex, "expected_revision": character["revision"], "expected_wallet_revision": character["wallet"]["revision"],
        "rules_hash": fixture["rules_hash"], "intent": {"kind": "activate"}}, token)
    assert status == 200
    with store.connect() as db:
        character = store.controlled_character(db, character["id"])
        selected = fixture[arguments.state]
        store.original_project(db, character, {"request_id": "trusted_test_fixture"}, selected)
        db.execute("UPDATE original_states SET state=?,view=? WHERE character_id=?", (selected["state"], json.dumps(selected["view"]), character["id"]))
        db.execute("UPDATE controlled_characters SET revision=revision+1 WHERE id=?", (character["id"],))
    if arguments.pending_rival:
        for direction in fixture["rival_approach"]:
            status,current = store.request("GET", "/v1/controlled/characters/"+character["id"]+"/original",token=token)
            assert status==200
            if current["original"]["prompt"]:
                break
            time.sleep(max(0.06,current["original"]["view"].get("next_move_at",0)-time.time()+0.01))
            current_role = current["character"]
            status,result = store.request("POST", "/v1/controlled/characters/"+character["id"]+"/original",{
                "request_id":uuid.uuid4().hex,"expected_revision":current_role["revision"],"expected_wallet_revision":current_role["wallet"]["revision"],
                "rules_hash":current["original"]["rules_hash"],"intent":{"kind":"move","direction":direction}},token)
            assert status==200,result
        assert result["original"]["view"].get("battle") and result["original"]["prompt"]
    server = make_server("127.0.0.1", 18770, store)
    print("ORIGINAL_FIXTURE_PID=" + str(os.getpid()), flush=True)
    print("ORIGINAL_FIXTURE_DIRECTORY=" + str(directory), flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        store.close()
