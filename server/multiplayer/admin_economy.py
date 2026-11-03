"""Operations views over the shared shop/market wallet, never another wallet.

SQLite posts both sides of every shop ledger entry in the same transaction.
Market buyer/seller legs use a clearing account; issuance, retirement and shop
treasury have distinct classifications. Historical entries are backfilled once.
"""
from datetime import date, datetime, timedelta
import json

try:
    from .admin_data import SHANGHAI, day_key, ROLES
except ImportError:
    from admin_data import SHANGHAI, day_key, ROLES


def bind_api(api):
    for name in ("obj", "require", "string", "integer", "dumps", "digest", "APIError"):
        globals()[name] = api[name]


COUNTER_ACCOUNT = """CASE
  WHEN event LIKE 'managed:original_market_buy:%' OR event LIKE 'managed:original_market_sell:%' OR event LIKE 'managed:original_trade:%' THEN 'system:market_clearing'
  WHEN event LIKE 'managed:original_market_tax:%' THEN 'system:retired'
  WHEN event LIKE 'managed:original_income:%' THEN 'system:issuance'
  WHEN event LIKE 'managed:original_expense:%' THEN 'system:retired'
  WHEN event LIKE 'managed:battle_reward:%' THEN 'system:issuance'
  WHEN event LIKE 'managed:battle_loss:%' OR event LIKE 'managed:train:%' OR event LIKE 'managed:learn:%'
    OR event LIKE 'managed:evolve:%' OR event LIKE 'managed:breed:%' OR event LIKE 'managed:fuse:%' OR event LIKE 'managed:split:%'
    THEN 'system:retired'
  WHEN event LIKE 'managed:npc_buy:%' THEN 'system:retired'
  WHEN event LIKE 'managed:initial:%' OR event LIKE 'managed:daily:%' OR event LIKE 'managed:npc_sell:%' THEN 'system:issuance'
  WHEN event LIKE 'buy:%' OR event LIKE 'sell:%' THEN 'system:market_clearing'
  WHEN substr(event,1,3)='so_' OR event LIKE 'refund:%' THEN 'system:shop_treasury'
  WHEN event LIKE 'admin:%' OR event LIKE 'redeem:%' OR event LIKE 'gm:%'
    THEN CASE WHEN amount>0 THEN 'system:issuance' ELSE 'system:retired' END
  ELSE 'system:unclassified' END"""


class EconomyAdminFeatures:
    def economy_period(self, query, default="today"):
        """Natural-day boundaries are Shanghai dates, regardless of browser timezone."""
        fields = set(query) & {"day", "period", "start", "end"}
        if not fields and default is None:
            return None
        now = self.clock()
        today = date.fromisoformat(day_key(now))
        preset = query.get("period", "custom" if fields & {"start", "end"} else default)
        if "day" in fields:
            require(fields == {"day"}, "invalid_period", "Choose one date or one period")
            first = last = query["day"]
        elif preset == "custom":
            require({"start", "end"} <= fields, "invalid_period", "Choose both start and end dates")
            first, last = query["start"], query["end"]
        else:
            require(preset in ("today", "yesterday", "7d", "30d") and not fields & {"start", "end"}, "invalid_period", "Choose today, yesterday, 7d, 30d or custom")
            end_day = today - timedelta(days=1) if preset == "yesterday" else today
            count = {"today": 1, "yesterday": 1, "7d": 7, "30d": 30}[preset]
            first, last = (end_day - timedelta(days=count - 1)).isoformat(), end_day.isoformat()
        for value in (first, last):
            string(value, 10, 10, "date", r"[0-9]{4}-[0-9]{2}-[0-9]{2}")
        try:
            first_day, last_day = date.fromisoformat(first), date.fromisoformat(last)
        except ValueError:
            require(False, "invalid_period", "Invalid calendar date")
        require(date(1970, 1, 1) <= first_day <= last_day <= today, "invalid_period", "Choose past or current dates in order")
        days = (last_day - first_day).days + 1
        require(days <= 90, "invalid_period", "Choose at most 90 days")
        start = datetime.combine(first_day, datetime.min.time(), SHANGHAI).timestamp()
        end = datetime.combine(last_day + timedelta(days=1), datetime.min.time(), SHANGHAI).timestamp()
        span = days * 86400
        return {"start_day": first, "end_day": last, "start": start, "end": end, "days": days,
                "previous_start_day": (first_day - timedelta(days=days)).isoformat(),
                "previous_end_day": (first_day - timedelta(days=1)).isoformat(),
                "previous_start": start - span, "previous_end": start,
                "as_of": now, "previous_as_of": now - span if now < end else now,
                "partial_day": now < end, "timezone": "Asia/Shanghai"}

    def economy_period_totals(self, db, currency, start, end, as_of):
        row = db.execute("""SELECT
            coalesce(sum(CASE WHEN account='system:issuance' THEN -amount ELSE 0 END),0) AS issued,
            coalesce(sum(CASE WHEN account='system:retired' THEN amount ELSE 0 END),0) AS retired,
            coalesce(sum(CASE WHEN account='system:shop_treasury' THEN amount ELSE 0 END),0) AS shop_net_spend,
            coalesce(sum(CASE WHEN account='system:market_clearing' AND amount>0 THEN amount ELSE 0 END),0) AS market_volume,
            coalesce(sum(CASE WHEN account='system:market_clearing' AND amount>0 THEN 1 ELSE 0 END),0) AS market_trades,
            count(*) AS events FROM economy_entries
            WHERE side='system' AND currency=? AND created>=? AND created<? AND created<=?""", (currency, start, end, as_of)).fetchone()
        return dict(row)

    def init_admin_economy(self, db):
        db.executescript("""
          CREATE TABLE IF NOT EXISTS economy_entries(
            ledger_id INTEGER NOT NULL,side TEXT NOT NULL,account TEXT NOT NULL,currency TEXT NOT NULL,
            amount INTEGER NOT NULL,event TEXT NOT NULL,created REAL NOT NULL,PRIMARY KEY(ledger_id,side));
          CREATE INDEX IF NOT EXISTS economy_entries_account ON economy_entries(account,currency,ledger_id);
          CREATE INDEX IF NOT EXISTS economy_entries_currency ON economy_entries(currency,side,account);
          CREATE INDEX IF NOT EXISTS economy_entries_period ON economy_entries(currency,created,side);
          CREATE INDEX IF NOT EXISTS shop_wallets_distribution ON shop_wallets(currency,balance);
          CREATE TABLE IF NOT EXISTS economy_proposals(
            id TEXT PRIMARY KEY,actor TEXT NOT NULL,document TEXT NOT NULL,status TEXT NOT NULL,
            expires REAL NOT NULL,approved_by TEXT);
          CREATE TABLE IF NOT EXISTS economy_admin_usage(
            actor TEXT NOT NULL,day TEXT NOT NULL,amount INTEGER NOT NULL,PRIMARY KEY(actor,day));
          CREATE TABLE IF NOT EXISTS economy_batches(
            id TEXT PRIMARY KEY,actor TEXT NOT NULL,document TEXT NOT NULL,status TEXT NOT NULL,
            expires REAL NOT NULL,approved_by TEXT);
          CREATE INDEX IF NOT EXISTS shop_ledger_created ON shop_ledger(created,id);
          CREATE INDEX IF NOT EXISTS shop_ledger_owner_id ON shop_ledger(owner,id);
        """)
        account = COUNTER_ACCOUNT.replace("event", "NEW.event").replace("amount", "NEW.amount")
        db.executescript("""
          DROP TRIGGER IF EXISTS economy_post_shop_ledger;
          CREATE TRIGGER IF NOT EXISTS economy_post_shop_ledger AFTER INSERT ON shop_ledger BEGIN
            INSERT INTO economy_entries VALUES(NEW.id,'player',NEW.owner,NEW.currency,NEW.amount,NEW.event,NEW.created);
            INSERT INTO economy_entries VALUES(NEW.id,'system',""" + account + """,NEW.currency,-NEW.amount,NEW.event,NEW.created);
          END;
          CREATE TRIGGER IF NOT EXISTS shop_ledger_immutable_update BEFORE UPDATE ON shop_ledger BEGIN
            SELECT RAISE(ABORT,'Economic ledger is append-only');
          END;
          CREATE TRIGGER IF NOT EXISTS shop_ledger_immutable_delete BEFORE DELETE ON shop_ledger BEGIN
            SELECT RAISE(ABORT,'Economic ledger is append-only');
          END;
        """)
        db.execute("""INSERT OR IGNORE INTO economy_entries SELECT id,'player',owner,currency,amount,event,created FROM shop_ledger""")
        db.execute("INSERT OR IGNORE INTO economy_entries SELECT id,'system'," + COUNTER_ACCOUNT + ",currency,-amount,event,created FROM shop_ledger")

    def economy_read(self, db, actor, path, query):
        if path == "/admin/v1/economy":
            self.admin_permission(actor, "overview")
            require(not set(query) - {"currency", "day", "period", "start", "end"}, "invalid_query", "Unexpected query")
            currency = query.get("currency", "MARKET")
            require(currency in ("MARKET", "RP", "GOLD"), "invalid_currency", "Choose MARKET, RP or GOLD")
            period = self.economy_period(query)
            start, end = period["start"], period["end"]
            scalar = lambda sql, args=(): db.execute(sql, args).fetchone()[0]
            balances = {row["account"]: row["balance"] for row in db.execute("SELECT account,sum(amount) AS balance FROM economy_entries WHERE currency=? AND side='system' GROUP BY account", (currency,))}
            player_total = scalar("SELECT coalesce(sum(balance),0) FROM shop_wallets WHERE currency=?", (currency,))
            wallet_owner = "c.owner" if currency == "GOLD" else "w.owner"
            frozen_total = scalar("SELECT coalesce(sum(w.balance),0) FROM shop_wallets w " +
                ("JOIN controlled_characters c ON c.id=w.owner " if currency == "GOLD" else "") +
                "LEFT JOIN player_controls p ON p.owner=" + wallet_owner +
                " WHERE w.currency=? AND (p.trade_frozen=1 OR p.ban_until>? OR EXISTS(SELECT 1 FROM player_maintenance m WHERE m.owner=" + wallet_owner + "))", (currency, self.clock()))
            issued = -balances.get("system:issuance", 0)
            retired = balances.get("system:retired", 0)
            distribution = [row[0] for row in db.execute("SELECT balance FROM shop_wallets WHERE currency=? ORDER BY balance LIMIT 100001", (currency,))]
            median = None
            if len(distribution) <= 100000 and distribution:
                middle = len(distribution) // 2
                median = distribution[middle] if len(distribution) % 2 else (distribution[middle - 1] + distribution[middle]) / 2
            sources = [dict(row) for row in db.execute("""SELECT CASE
                WHEN event LIKE 'managed:original_market_tax:%' THEN 'original_market_fee'
                WHEN event LIKE 'managed:original_market_buy:%' OR event LIKE 'managed:original_market_sell:%' THEN 'original_market_transfer'
                WHEN event LIKE 'managed:original_trade:%' THEN 'original_direct_trade'
                WHEN event LIKE 'managed:original_income:battle_income:%' THEN 'original_battle_income'
                WHEN event LIKE 'managed:original_expense:battle_loss:%' THEN 'original_battle_loss'
                WHEN event LIKE 'managed:original_income:npc_sale:%' THEN 'original_npc_sale'
                WHEN event LIKE 'managed:original_expense:npc_purchase:%' THEN 'original_npc_purchase'
                WHEN event LIKE 'managed:original_income:quest_reward:%' THEN 'original_quest_reward'
                WHEN event LIKE 'managed:original_expense:tutor_cost:%' THEN 'original_tutor_cost'
                WHEN event LIKE 'managed:original_expense:daycare_cost:%' THEN 'original_daycare_cost'
                WHEN event LIKE 'managed:original_income:%' THEN 'original_world_income'
                WHEN event LIKE 'managed:original_expense:%' THEN 'original_world_expense'
                WHEN event LIKE 'managed:battle_reward:%' THEN 'campaign_reward'
                WHEN event LIKE 'managed:battle_loss:%' THEN 'campaign_loss'
                WHEN event LIKE 'managed:train:%' OR event LIKE 'managed:learn:%' OR event LIKE 'managed:evolve:%'
                  OR event LIKE 'managed:breed:%' OR event LIKE 'managed:fuse:%' OR event LIKE 'managed:split:%' THEN 'cultivation_cost'
                WHEN event LIKE 'managed:initial:%' THEN 'new_character_grant'
                WHEN event LIKE 'managed:daily:%' THEN 'daily_checkin'
                WHEN event LIKE 'managed:npc_sell:%' THEN 'npc_sale'
                WHEN event LIKE 'managed:npc_buy:%' THEN 'npc_purchase'
                WHEN event LIKE 'gm:%' OR event LIKE 'admin:%' THEN 'operator_adjustment'
                WHEN event LIKE 'redeem:%' THEN 'code_redemption'
                WHEN event LIKE 'refund:%' THEN 'shop_refund'
                WHEN substr(event,1,3)='so_' THEN 'shop_purchase'
                WHEN account='system:issuance' THEN 'issuance'
                WHEN account='system:retired' THEN 'retirement' WHEN account='system:shop_treasury' THEN 'shop_treasury'
                WHEN account='system:market_clearing' THEN 'player_transfer' ELSE 'unclassified' END AS source,
                sum(CASE WHEN amount<0 THEN -amount ELSE 0 END) AS to_players,
                sum(CASE WHEN amount>0 THEN amount ELSE 0 END) AS from_players,count(*) AS events
                FROM economy_entries WHERE side='system' AND currency=? AND created>=? AND created<? AND created<=? GROUP BY source ORDER BY to_players+from_players DESC,source""", (currency, start, end, period["as_of"]))]
            current = self.economy_period_totals(db, currency, start, end, period["as_of"])
            previous = self.economy_period_totals(db, currency, period["previous_start"], period["previous_end"], period["previous_as_of"])
            started = float(scalar("SELECT value FROM admin_metadata WHERE key='collection_started'"))
            first_event = scalar("SELECT min(created) FROM shop_ledger WHERE currency=?", (currency,))
            period["known_since"] = min(started, first_event) if first_event is not None else started
            period["coverage_complete"] = start >= period["known_since"]
            period["previous_coverage_complete"] = period["previous_start"] >= period["known_since"]
            anomalies = self.economy_reconciliation(db, currency)
            return {"currency": currency, "day": period["end_day"], "as_of": period["as_of"], "source": "server_ledger",
                    "period": period, "period_totals": current, "previous_totals": previous,
                    "player_total": player_total, "frozen_total": frozen_total, "available_total": player_total - frozen_total,
                    "system_balances": balances, "issued": issued, "retired": retired,
                    "outstanding_supply": issued - retired, "median_funded_wallet": median,
                    "wallet_count": scalar("SELECT count(*) FROM shop_wallets WHERE currency=?", (currency,)),
                    "top_wallets": [dict(row) for row in db.execute(("""SELECT w.owner,w.balance,w.revision,i.nickname,c.name AS character_name,c.owner AS account_id
                        FROM shop_wallets w JOIN controlled_characters c ON c.id=w.owner JOIN identities i ON i.id=c.owner
                        WHERE currency=? ORDER BY balance DESC,w.owner LIMIT 20""" if currency == "GOLD" else """SELECT w.owner,w.balance,w.revision,i.nickname FROM shop_wallets w
                        JOIN identities i ON i.id=w.owner WHERE currency=? ORDER BY balance DESC,w.owner LIMIT 20"""), (currency,))],
                    "sources": sources, "reconciliation": anomalies,
                    "cash_revenue": {"status": "not_connected", "value": None},
                    "proposals": [dict(row) for row in db.execute("SELECT id,actor,status,expires,approved_by,document FROM economy_proposals ORDER BY rowid DESC LIMIT 50")] if "economy" in ROLES[actor["role"]] else []}
        if path == "/admin/v1/ledger":
            self.admin_permission(actor, "players")
            require(not set(query) - {"owner", "currency", "before", "limit", "day", "period", "start", "end"}, "invalid_query", "Unexpected query")
            owner = string(query.get("owner", ""), 0, 80, "owner")
            currency = query.get("currency", "MARKET")
            require(currency in ("MARKET", "RP", "GOLD"), "invalid_currency", "Choose MARKET, RP or GOLD")
            before = integer(int(query.get("before", "0")), 0, 2**53 - 1, "before")
            limit = integer(int(query.get("limit", "50")), 1, 100, "limit")
            period = self.economy_period(query, default=None)
            start, end = (period["start"], period["end"]) if period else (-1e15, 1e15)
            rows = [dict(row) for row in db.execute("""SELECT id,owner,currency,amount,balance,event,created FROM shop_ledger
                WHERE currency=? AND (?='' OR owner=?) AND (?=0 OR id<?) AND created>=? AND created<? AND created<=?
                ORDER BY id DESC LIMIT ?""", (currency, owner, owner, before, before, start, end, self.clock(), limit))]
            return {"entries": rows, "next_cursor": rows[-1]["id"] if len(rows) == limit else None}
        if path == "/admin/v1/transactions":
            self.admin_permission(actor, "players")
            require(not set(query) - {"owner", "kind", "before"}, "invalid_query", "Unexpected query")
            owner = string(query.get("owner", ""), 0, 80, "owner")
            kind = query.get("kind", "shop")
            require(kind in ("shop", "market", "original_market", "original_trade"), "invalid_query", "Choose a supported shop or trade journal")
            before = integer(int(query.get("before", "0")), 0, 2**53 - 1, "before")
            if kind == "original_market":
                rows = db.execute("SELECT m.rowid AS cursor,m.* FROM original_market m JOIN controlled_characters c ON c.id=m.seller WHERE (?='' OR c.owner=?) AND (?=0 OR m.rowid<?) ORDER BY m.rowid DESC LIMIT 50", (owner,owner,before,before)).fetchall()
                return {"transactions": [{"cursor": row["cursor"], "owner": self.controlled_character(db,row["seller"])["owner"], "detail": self.original_market_public(db,row)} for row in rows]}
            if kind == "original_trade":
                rows = db.execute("SELECT o.rowid AS cursor,o.* FROM original_offers o JOIN controlled_characters c ON c.id=o.sender JOIN controlled_characters r ON r.id=o.receiver WHERE (?='' OR c.owner=? OR r.owner=?) AND (?=0 OR o.rowid<?) ORDER BY o.rowid DESC LIMIT 50", (owner,owner,owner,before,before)).fetchall()
                return {"transactions": [{"cursor": row["cursor"], "owner": self.controlled_character(db,row["sender"])["owner"], "detail": self.original_offer_public(row)} for row in rows]}
            table = "shop_orders" if kind == "shop" else "market_receipts"
            rows = db.execute("SELECT rowid AS cursor,owner,document FROM " + table + " WHERE (?='' OR owner=?) AND (?=0 OR rowid<?) ORDER BY rowid DESC LIMIT 50", (owner, owner, before, before)).fetchall()
            return {"transactions": [{"cursor": row["cursor"], "owner": row["owner"], "detail": json.loads(row["document"])} for row in rows]}
        if path == "/admin/v1/batches":
            self.admin_permission(actor, "economy")
            require(not query, "invalid_query", "Unexpected query")
            return {"batches": [dict(row, detail=json.loads(row["document"])) for row in db.execute("SELECT * FROM economy_batches ORDER BY rowid DESC LIMIT 50")], "as_of": self.clock()}
        if path == "/admin/v1/batch-preview":
            self.admin_permission(actor, "economy")
            require(not set(query) - {"owners", "currency", "characters"}, "invalid_query", "Unexpected query")
            currency = query.get("currency", "MARKET")
            require(currency in ("RP", "MARKET", "GOLD"), "invalid_currency", "Choose RP, MARKET or GOLD")
            owners = string(query.get("characters") if currency == "GOLD" else query.get("owners"), 1, 1800, "owners").split(",")
            require(1 <= len(owners) <= 50 and len(set(owners)) == len(owners), "invalid_batch", "Choose 1..50 distinct accounts")
            recipients = []
            for identifier in owners:
                character = self.controlled_character(db, identifier) if currency == "GOLD" else None
                owner = character["owner"] if character else identifier
                string(owner, 1, 80, "owner", r"[A-Za-z0-9_-]+")
                require(db.execute("SELECT 1 FROM accounts WHERE owner=?", (owner,)).fetchone() is not None, "account_required", "Registered account required", 404)
                wallet = self.shop_wallet(db, identifier if character else owner, currency)
                recipients.append({"owner": owner, "expected_control_version": self.controls(db, owner)["version"],
                                   "expected_wallet_revision": wallet["revision"], "balance": wallet["balance"],
                                   **({"character_id": identifier} if character else {})})
            return {"recipients": recipients, "currency": currency, "as_of": self.clock()}
        return None

    def economy_reconciliation(self, db, currency):
        mismatches = [dict(row) for row in db.execute("""SELECT w.owner,w.balance,coalesce(sum(l.amount),0) AS ledger_balance
            FROM shop_wallets w LEFT JOIN shop_ledger l ON w.owner=l.owner AND w.currency=l.currency
            WHERE w.currency=? GROUP BY w.owner HAVING w.balance!=coalesce(sum(l.amount),0) LIMIT 100""", (currency,))]
        unbalanced = [dict(row) for row in db.execute("SELECT ledger_id,sum(amount) AS difference FROM economy_entries WHERE currency=? GROUP BY ledger_id HAVING sum(amount)!=0 OR count(*)!=2 LIMIT 100", (currency,))]
        missing = db.execute("SELECT count(*) FROM shop_ledger l WHERE currency=? AND NOT EXISTS(SELECT 1 FROM economy_entries e WHERE e.ledger_id=l.id AND e.side='player')", (currency,)).fetchone()[0]
        clearing = db.execute("SELECT coalesce(sum(amount),0) FROM economy_entries WHERE currency=? AND account='system:market_clearing'", (currency,)).fetchone()[0]
        unclassified = db.execute("SELECT count(*) FROM economy_entries WHERE currency=? AND account='system:unclassified'", (currency,)).fetchone()[0]
        inconsistent = db.execute("""SELECT count(*) FROM economy_entries e JOIN shop_ledger l ON l.id=e.ledger_id
            WHERE l.currency=? AND e.side='player' AND (e.account!=l.owner OR e.currency!=l.currency OR e.amount!=l.amount)""", (currency,)).fetchone()[0]
        orphan_wallets = db.execute("""SELECT count(DISTINCT l.owner) FROM shop_ledger l LEFT JOIN shop_wallets w
            ON l.owner=w.owner AND l.currency=w.currency WHERE l.currency=? AND w.owner IS NULL""", (currency,)).fetchone()[0]
        orphan_owners = db.execute("SELECT count(*) FROM shop_wallets w LEFT JOIN " +
            ("controlled_characters c ON c.id=w.owner WHERE w.currency=? AND c.id IS NULL" if currency == "GOLD" else
             "accounts a ON a.owner=w.owner WHERE w.currency=? AND a.owner IS NULL"), (currency,)).fetchone()[0]
        return {"ok": not (mismatches or unbalanced or missing or clearing or unclassified or inconsistent or orphan_wallets or orphan_owners), "wallet_mismatches": mismatches,
                "unbalanced_entries": unbalanced, "missing_entries": missing, "clearing_balance": clearing,
                "unclassified_events": unclassified, "inconsistent_postings": inconsistent, "missing_wallets": orphan_wallets, "missing_owners": orphan_owners}

    def economy_command(self, db, actor, body):
        self.admin_permission(actor, "economy")
        obj(body, {"id", "action", "target", "reason", "expected_version", "currency", "amount", "expected_wallet_revision", "proposal_id", "character_id"},
            {"id", "action", "target", "reason", "expected_version"})
        command_id = string(body["id"], 16, 100, "id", r"[A-Za-z0-9_-]+")
        target = string(body["target"], 1, 80, "target", r"[A-Za-z0-9_-]+")
        reason = string(body["reason"], 3, 500, "reason")
        fingerprint = digest(dumps(body))
        old = db.execute("SELECT * FROM admin_commands WHERE id=?", (command_id,)).fetchone()
        if old:
            require(old["actor"] == actor["username"] and old["fingerprint"] == fingerprint, "command_conflict", "Command ID already used", 409)
            return 200, json.loads(old["response"])
        require(db.execute("SELECT 1 FROM accounts WHERE owner=?", (target,)).fetchone() is not None, "account_required", "Registered player account required", 404)
        expected = integer(body["expected_version"], 0, 2**53 - 1, "expected_version")
        require(self.controls(db, target)["version"] == expected, "control_version_conflict", "Player state changed", 409)
        proposal = None
        author = actor["username"]
        instruction = body
        if body["action"] == "approve_wallet":
            require(set(body) == {"id", "action", "target", "reason", "expected_version", "proposal_id"}, "invalid_command", "Invalid approval fields")
            proposal_id = string(body["proposal_id"], 16, 100, "proposal_id", r"[A-Za-z0-9_-]+")
            proposal = db.execute("SELECT * FROM economy_proposals WHERE id=?", (proposal_id,)).fetchone()
            require(proposal is not None and proposal["status"] == "pending" and proposal["expires"] > self.clock(), "proposal_unavailable", "Proposal expired or already processed", 409)
            require(proposal["actor"] != author, "independent_approval_required", "A different administrator must review this operation", 403)
            initiator = db.execute("SELECT role FROM admin_users WHERE username=? AND enabled=1", (proposal["actor"],)).fetchone()
            require(initiator is not None and "economy" in ROLES.get(initiator["role"], ()), "proposal_revoked", "The initiator no longer has economic permissions", 403)
            instruction = json.loads(proposal["document"])
            require(instruction["target"] == target and instruction["expected_version"] == expected, "proposal_changed", "Proposal target state changed", 409)
            author = proposal["actor"]
        else:
            require(body["action"] == "adjust_wallet" and set(body) == {"id", "action", "target", "reason", "expected_version", "currency", "amount", "expected_wallet_revision"} | ({"character_id"} if body.get("currency") == "GOLD" else set()), "invalid_command", "Invalid wallet adjustment fields")
        currency = instruction["currency"]
        require(currency in ("RP", "MARKET", "GOLD"), "invalid_currency", "Choose RP, MARKET or GOLD")
        wallet_owner = self.controlled_character(db, instruction["character_id"], target)["id"] if currency == "GOLD" else target
        amount = integer(instruction["amount"], -1000000000, 1000000000, "amount")
        require(amount != 0, "invalid_amount", "Amount cannot be zero")
        wallet_revision = integer(instruction["expected_wallet_revision"], 0, 2**53 - 1, "expected_wallet_revision")
        wallet = self.shop_wallet(db, wallet_owner, currency)
        require(wallet["revision"] == wallet_revision, "wallet_version_conflict", "Wallet changed; refresh and review", 409)
        require(0 <= wallet["balance"] + amount <= 1000000000, "wallet_limit", "Adjustment exceeds available balance or wallet limit", 409)
        usage = db.execute("SELECT amount FROM economy_admin_usage WHERE actor=? AND day=?", (author, day_key(self.clock()))).fetchone()
        needs_approval = abs(amount) > 10000 or (usage[0] if usage else 0) + abs(amount) > 100000
        if needs_approval and proposal is None:
            db.execute("INSERT INTO economy_proposals VALUES(?,?,?,'pending',?,NULL)", (command_id, author, dumps(body), self.clock() + 86400))
            result = {"ok": True, "command_id": command_id, "status": "pending_approval", "target": target}
            self.audit(db, author, "wallet_proposed", target, reason, {"command_id": command_id, "amount": amount, "currency": currency, "before": wallet})
        else:
            after = self.shop_money(db, wallet_owner, currency, amount, "gm:" + (proposal["id"] if proposal else command_id))
            db.execute("INSERT INTO economy_admin_usage VALUES(?,?,?) ON CONFLICT(actor,day) DO UPDATE SET amount=amount+excluded.amount", (author, day_key(self.clock()), abs(amount)))
            if proposal:
                db.execute("UPDATE economy_proposals SET status='completed',approved_by=? WHERE id=?", (actor["username"], proposal["id"]))
                db.execute("UPDATE admin_commands SET response=? WHERE id=?", (dumps({"ok": True, "command_id": proposal["id"], "status": "completed", "target": target, "wallet": after, "approved_by": actor["username"]}), proposal["id"]))
            result = {"ok": True, "command_id": command_id, "status": "completed", "target": target, "wallet": after}
            self.audit(db, actor["username"], "wallet_adjusted", target, reason,
                       {"command_id": command_id, "proposal_id": proposal["id"] if proposal else None, "initiator": author, "amount": amount, "before": wallet, "after": after, "wallet_owner": wallet_owner})
        db.execute("INSERT INTO admin_commands VALUES(?,?,?,?,?)", (command_id, actor["username"], fingerprint, dumps(result), self.clock()))
        return 200, result

    def validate_batch_targets(self, db, instruction):
        currency = instruction["currency"]
        require(currency in ("RP", "MARKET", "GOLD"), "invalid_currency", "Choose RP, MARKET or GOLD")
        recipients = instruction["recipients"]
        require(type(recipients) is list and 1 <= len(recipients) <= 100, "invalid_batch", "Choose 1..100 recipients")
        seen, total = set(), 0
        for recipient in recipients:
            fields = {"owner", "amount", "expected_control_version", "expected_wallet_revision"} | ({"character_id"} if currency == "GOLD" else set())
            obj(recipient, fields, fields)
            owner = string(recipient["owner"], 1, 80, "owner", r"[A-Za-z0-9_-]+")
            wallet_owner = self.controlled_character(db, recipient["character_id"], owner)["id"] if currency == "GOLD" else owner
            require(wallet_owner not in seen, "duplicate_recipient", "A batch cannot repeat a wallet")
            seen.add(wallet_owner)
            amount = integer(recipient["amount"], -1000000000, 1000000000, "amount")
            require(amount != 0, "invalid_amount", "Amount cannot be zero")
            control = integer(recipient["expected_control_version"], 0, 2**53 - 1, "expected_control_version")
            revision = integer(recipient["expected_wallet_revision"], 0, 2**53 - 1, "expected_wallet_revision")
            require(db.execute("SELECT 1 FROM accounts WHERE owner=?", (owner,)).fetchone() is not None, "account_required", "Registered account required", 404)
            wallet = self.shop_wallet(db, wallet_owner, currency)
            require(self.controls(db, owner)["version"] == control and wallet["revision"] == revision, "batch_version_conflict", "A recipient changed; review the entire batch again", 409)
            require(0 <= wallet["balance"] + amount <= 1000000000, "wallet_limit", "A recipient exceeds balance limits", 409)
            total += abs(amount)
        require(total <= 1000000000, "batch_limit", "Batch total exceeds limit")
        return total

    def economy_batch_command(self, db, actor, body):
        self.admin_permission(actor, "economy")
        approve = body.get("action") == "approve_batch"
        fields = {"id", "action", "reason"} | ({"proposal_id"} if approve else {"currency", "recipients"})
        obj(body, fields, fields)
        command_id = string(body["id"], 16, 100, "id", r"[A-Za-z0-9_-]+")
        reason = string(body["reason"], 3, 500, "reason")
        fingerprint = digest(dumps(body))
        old = db.execute("SELECT * FROM admin_commands WHERE id=?", (command_id,)).fetchone()
        if old:
            require(old["actor"] == actor["username"] and old["fingerprint"] == fingerprint, "command_conflict", "Command ID already used", 409)
            return 200, json.loads(old["response"])
        if not approve:
            total = self.validate_batch_targets(db, body)
            db.execute("INSERT INTO economy_batches VALUES(?,?,?,'pending',?,NULL)", (command_id, actor["username"], dumps(body), self.clock() + 86400))
            result = {"ok": True, "command_id": command_id, "status": "pending_approval", "recipients": len(body["recipients"]), "absolute_total": total}
            self.audit(db, actor["username"], "batch_proposed", command_id, reason, {"currency": body["currency"], "recipients": len(body["recipients"]), "absolute_total": total})
        else:
            proposal_id = string(body["proposal_id"], 16, 100, "proposal_id", r"[A-Za-z0-9_-]+")
            proposal = db.execute("SELECT * FROM economy_batches WHERE id=?", (proposal_id,)).fetchone()
            require(proposal is not None and proposal["status"] == "pending" and proposal["expires"] > self.clock(), "proposal_unavailable", "Batch expired or already processed", 409)
            require(proposal["actor"] != actor["username"], "independent_approval_required", "Another administrator must review this batch", 403)
            initiator = db.execute("SELECT role FROM admin_users WHERE username=? AND enabled=1", (proposal["actor"],)).fetchone()
            require(initiator is not None and "economy" in ROLES.get(initiator["role"], ()), "proposal_revoked", "Batch initiator permissions were revoked", 403)
            instruction = json.loads(proposal["document"])
            total = self.validate_batch_targets(db, instruction)
            results = []
            for recipient in instruction["recipients"]:
                wallet_owner = recipient["character_id"] if instruction["currency"] == "GOLD" else recipient["owner"]
                wallet = self.shop_money(db, wallet_owner, instruction["currency"], recipient["amount"], "gm:batch:" + proposal_id + ":" + wallet_owner)
                results.append({"owner": recipient["owner"], "wallet_owner": wallet_owner, "wallet": wallet})
                self.audit(db, actor["username"], "batch_wallet_adjusted", recipient["owner"], reason,
                           {"proposal_id": proposal_id, "initiator": proposal["actor"], "amount": recipient["amount"], "wallet_owner": wallet_owner, "wallet": wallet})
            db.execute("INSERT INTO economy_admin_usage VALUES(?,?,?) ON CONFLICT(actor,day) DO UPDATE SET amount=amount+excluded.amount", (proposal["actor"], day_key(self.clock()), total))
            db.execute("UPDATE economy_batches SET status='completed',approved_by=? WHERE id=?", (actor["username"], proposal_id))
            result = {"ok": True, "command_id": command_id, "status": "completed", "proposal_id": proposal_id, "results": results}
            db.execute("UPDATE admin_commands SET response=? WHERE id=?", (dumps(dict(result, command_id=proposal_id)), proposal_id))
            self.audit(db, actor["username"], "batch_completed", proposal_id, reason, {"recipients": len(results), "absolute_total": total})
        db.execute("INSERT INTO admin_commands VALUES(?,?,?,?,?)", (command_id, actor["username"], fingerprint, dumps(result), self.clock()))
        return 200, result
