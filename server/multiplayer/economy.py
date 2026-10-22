"""Integer, double-entry online currency. Called inside Store's write transaction."""
import copy
import json
import secrets

MAX_COINS = 9_999_999_999


def bind_api(api):
    for name in ("obj", "require", "string", "integer", "dumps", "digest"):
        globals()[name] = api[name]


class EconomyFeatures:
    def init_economy(self, db):
        db.executescript("""
            CREATE TABLE IF NOT EXISTS economy_meta(name TEXT PRIMARY KEY,value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS wallet_accounts(owner TEXT PRIMARY KEY,balance INTEGER NOT NULL DEFAULT 0 CHECK(balance>=0 AND balance<=9999999999),version INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS wallet_holds(owner TEXT NOT NULL,reference TEXT NOT NULL,amount INTEGER NOT NULL CHECK(amount>=0),PRIMARY KEY(owner,reference));
            CREATE TABLE IF NOT EXISTS ledger_transactions(id TEXT PRIMARY KEY,kind TEXT NOT NULL,document TEXT NOT NULL,created REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS ledger_entries(transaction_id TEXT NOT NULL,owner TEXT NOT NULL,amount INTEGER NOT NULL,PRIMARY KEY(transaction_id,owner));
            CREATE INDEX IF NOT EXISTS ledger_owner ON ledger_entries(owner,transaction_id);
            CREATE TABLE IF NOT EXISTS trading_grants(event_id TEXT PRIMARY KEY,owner TEXT NOT NULL,fingerprint TEXT NOT NULL,document TEXT NOT NULL);
            INSERT OR IGNORE INTO economy_meta VALUES('schema_version','1');
            INSERT OR IGNORE INTO economy_meta VALUES('enabled','true');
        """)
        require(db.execute("SELECT value FROM economy_meta WHERE name='schema_version'").fetchone()[0] == "1", "economy_schema", "Unsupported economy schema", 503)

    def wallet(self, db, owner):
        row = db.execute("SELECT balance,version FROM wallet_accounts WHERE owner=?", (owner,)).fetchone()
        reserved = db.execute("SELECT COALESCE(SUM(amount),0) FROM wallet_holds WHERE owner=?", (owner,)).fetchone()[0]
        balance, version = (row["balance"], row["version"]) if row else (0, 0)
        require(0 <= reserved <= balance, "wallet_invariant", "Wallet reserves require operator inspection", 503)
        return {"owner_id": owner, "currency": "LINK", "balance": balance, "reserved": reserved, "available": balance - reserved, "version": version}

    def reserve_money(self, db, owner, reference, amount):
        integer(amount, 0, MAX_COINS, "amount")
        old = db.execute("SELECT amount FROM wallet_holds WHERE owner=? AND reference=?", (owner, reference)).fetchone()
        require(amount <= self.wallet(db, owner)["available"] + (old[0] if old else 0), "insufficient_funds", "Not enough available LINK coins", 409)
        db.execute("INSERT OR REPLACE INTO wallet_holds VALUES(?,?,?)", (owner, reference, amount))

    def post_money(self, db, transaction_id, kind, changes, document):
        """Post all net deltas at once: no intermediate over/underflow on barter."""
        require(sum(changes.values()) == 0, "ledger_unbalanced", "Currency entries must balance", 500)
        require(db.execute("SELECT 1 FROM ledger_transactions WHERE id=?", (transaction_id,)).fetchone() is None, "ledger_duplicate", "Settlement already exists", 409)
        for owner, delta in changes.items():
            if owner.startswith("system:"):
                continue
            wallet = self.wallet(db, owner)
            require(0 <= wallet["balance"] + delta <= MAX_COINS, "wallet_limit", "Wallet balance limit exceeded", 409)
            require(wallet["available"] + delta >= 0, "insufficient_funds", "Not enough available LINK coins", 409)
        db.execute("INSERT INTO ledger_transactions VALUES(?,?,?,?)", (transaction_id, kind, dumps(document), self.clock()))
        for owner, delta in changes.items():
            db.execute("INSERT INTO ledger_entries VALUES(?,?,?)", (transaction_id, owner, delta))
            if not owner.startswith("system:"):
                db.execute("INSERT OR IGNORE INTO wallet_accounts(owner) VALUES(?)", (owner,))
                db.execute("UPDATE wallet_accounts SET balance=balance+?,version=version+1 WHERE owner=?", (delta, owner))

    def trading_grant(self, db, owner, amount, catalog_slots, event_id):
        """Trusted operator API, deliberately absent from HTTP dispatch."""
        integer(amount, 0, MAX_COINS, "amount")
        string(event_id, 8, 100, "event_id", r"[A-Za-z0-9_-]+")
        require(db.execute("SELECT 1 FROM accounts WHERE owner=?", (owner,)).fetchone(), "account_required", "A registered account is required", 403)
        require(type(catalog_slots) is list and len(catalog_slots) <= 12 and all(type(slot) is int and 0 <= slot < 12 for slot in catalog_slots), "invalid_grant", "Choose up to twelve installed catalog slots")
        fingerprint = digest(dumps({"owner": owner, "amount": amount, "slots": catalog_slots}))
        previous = db.execute("SELECT fingerprint,document FROM trading_grants WHERE event_id=?", (event_id,)).fetchone()
        if previous:
            require(previous["fingerprint"] == fingerprint, "grant_conflict", "Grant event already used with different parameters", 409)
            return json.loads(previous["document"])
        catalog = self.catalog() if catalog_slots else None
        assets = []
        for slot in catalog_slots:
            asset = {"id": "pkm_" + secrets.token_hex(16), "owner_id": owner, "snapshot": copy.deepcopy(catalog["pokemon"][slot]), "source": "server_catalog", "catalog_version": 1, "catalog_hash": digest(dumps(catalog)), "compatibility": copy.deepcopy(catalog["compatibility"]), "created_at": self.clock()}
            db.execute("INSERT INTO hosted_assets VALUES(?,?,?)", (asset["id"], owner, dumps(asset)))
            assets.append(asset["id"])
        tx = "grant_" + secrets.token_hex(16)
        self.post_money(db, tx, "operator_grant", {owner: amount, "system:issuer": -amount}, {"event_id": event_id, "assets": assets})
        document = {"event_id": event_id, "owner_id": owner, "amount": amount, "asset_ids": assets, "transaction_id": tx}
        db.execute("INSERT INTO trading_grants VALUES(?,?,?,?)", (event_id, owner, fingerprint, dumps(document)))
        return document

    def economy_audit(self, db):
        unbalanced = db.execute("SELECT transaction_id FROM ledger_entries GROUP BY transaction_id HAVING SUM(amount)<>0").fetchall()
        drift = db.execute("SELECT w.owner FROM wallet_accounts w LEFT JOIN ledger_entries e ON e.owner=w.owner GROUP BY w.owner HAVING w.balance<>COALESCE(SUM(e.amount),0)").fetchall()
        overspent = db.execute("SELECT h.owner FROM wallet_holds h LEFT JOIN wallet_accounts w ON w.owner=h.owner GROUP BY h.owner HAVING SUM(h.amount)>COALESCE(w.balance,0)").fetchall()
        return {"ok": not (unbalanced or drift or overspent), "unbalanced": [r[0] for r in unbalanced], "wallet_drift": [r[0] for r in drift], "overreserved": [r[0] for r in overspent]}
