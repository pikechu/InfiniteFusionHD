"""Deterministic loopback fixture; never accepts a database or public bind address."""
import os
from pathlib import Path
import sys
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "server/multiplayer"))
import controlled_engine
from service import Store, make_server
from test_historical_v1_support import HistoricalV1Store as Store


def fixture_roll(self, bound):
    self.battle["random_counter"] += 1
    return 0  # Explicit fixture entropy; production retains the secret HMAC stream.


if __name__ == "__main__":
    directory = ROOT / "temp/controlled-adventure-smoke" / uuid.uuid4().hex
    directory.mkdir(parents=True)
    controlled_engine.BattleRandom.randrange = fixture_roll
    store = Store(directory / "game.sqlite3")
    server = make_server("127.0.0.1", 18769, store)
    print("CONTROLLED_ADVENTURE_FIXTURE_PID=" + str(os.getpid()), flush=True)
    print("CONTROLLED_ADVENTURE_FIXTURE_DB=" + str(directory / "game.sqlite3"), flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        store.close()
