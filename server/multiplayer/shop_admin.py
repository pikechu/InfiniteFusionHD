"""Offline economy administration. Stop the service before opening its database.

Example: shop_admin.py --database ... --actor operator --reference event-001
         --action credit --data-file private-credit.json
Secrets are supplied in a private JSON file, never command-line flags or logs.
"""
import argparse
import json
from pathlib import Path
from service import Store, database_instance_lock


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--actor", required=True)
    parser.add_argument("--reference", required=True)
    parser.add_argument("--action", choices=("credit", "code", "control", "refund", "audit"), required=True)
    parser.add_argument("--data-file", type=Path)
    args = parser.parse_args()
    if not args.database.is_file():
        raise SystemExit("Database does not exist")
    with database_instance_lock(args.database):
        store = Store(args.database, create=False, synchronous="FULL")
        try:
            if args.action == "audit":
                with store.connect() as db:
                    mismatches = [dict(row) for row in db.execute("""SELECT w.owner,w.currency,w.balance,COALESCE(SUM(l.amount),0) AS ledger_total
                        FROM shop_wallets w LEFT JOIN shop_ledger l ON l.owner=w.owner AND l.currency=w.currency
                        GROUP BY w.owner,w.currency HAVING w.balance!=COALESCE(SUM(l.amount),0)""")]
                print(json.dumps({"ok": not mismatches, "mismatches": mismatches}))
                if mismatches:
                    raise SystemExit(1)
            else:
                if not args.data_file:
                    raise SystemExit("--data-file is required")
                result = store.shop_admin(args.actor, args.action, args.reference, json.loads(args.data_file.read_text(encoding="utf-8-sig")))
                print(json.dumps(result))
        finally:
            store.close()


if __name__ == "__main__":
    main()
