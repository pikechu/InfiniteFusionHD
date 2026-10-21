"""Read-only final audit of one isolated native pool test, without credentials."""
from pathlib import Path
import argparse
import json
import sqlite3

parser = argparse.ArgumentParser()
parser.add_argument("database", type=Path)
parser.add_argument("output", type=Path)
args = parser.parse_args()
with sqlite3.connect(args.database.resolve().as_uri() + "?mode=ro", uri=True) as db:
    deposits = [json.loads(row[0]) for row in db.execute("SELECT document FROM pool_deposits ORDER BY id")]
    identities = db.execute("SELECT COUNT(*) FROM identities").fetchone()[0]
    locks = db.execute("SELECT COUNT(*) FROM asset_locks").fetchone()[0]
    trades = db.execute("SELECT COUNT(*) FROM trades").fetchone()[0]
    operations = db.execute("SELECT COUNT(*) FROM operations").fetchone()[0]
transactions = {value.get("transaction_id") for value in deposits}
assert identities == 2 and len(deposits) == 2, "Expected exactly two identities and two deposits"
assert len(transactions) == 1 and None not in transactions, "Expected one unique transaction"
assert len({value["owner_id"] for value in deposits}) == 2, "Cannot self-match"
assert all(value["status"] == "completed" and value["final_status"] == "matched" and value["acked"] for value in deposits), "Both deposits must be acknowledged and completed"
assert all(value["source"] == "local_casual" and value["receipt"]["kind"] == "exchange" for value in deposits), "Expected only local casual exchange receipts"
assert all(value["receipt"]["owner_id"] == value["owner_id"] and value["receipt"]["transaction_id"] == value["transaction_id"] for value in deposits), "Receipt identity or transaction mismatch"
assert deposits[0]["receipt"]["received_snapshot"] == deposits[1]["snapshot"] and deposits[1]["receipt"]["received_snapshot"] == deposits[0]["snapshot"], "Receipts must exchange original deposits"
assert locks == 0 and trades == 0, "No remaining asset locks or unrelated friend trades"
result = {"passed": True, "readonly_audit": True, "identity_count": identities, "deposit_count": len(deposits),
          "transaction_count": len(transactions), "transaction_id": next(iter(transactions)), "asset_locks": locks,
          "friend_trade_count": trades, "operation_count": operations,
          "deposits": [{key: value[key] for key in ("deposit_id", "owner_id", "status", "final_status", "acked", "transaction_id")} for value in deposits]}
args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print("POOL_RESTART_DB_AUDIT_PASS deposits=2 transactions=1 completed=2 locks=0")
