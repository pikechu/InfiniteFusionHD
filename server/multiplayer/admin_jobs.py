"""Bounded exports, observed retention cohorts and evidence-based risk cases."""
from contextlib import closing
import csv
from datetime import date, timedelta
import io
import json
import sqlite3

try:
    from .admin_data import day_key, readonly
except ImportError:
    from admin_data import day_key, readonly


def bind_api(api):
    for name in ("obj", "require", "string", "integer", "dumps", "digest", "APIError"):
        globals()[name] = api[name]


def csv_text(columns, rows):
    output = io.StringIO(newline="")
    writer = csv.writer(output)
    writer.writerow(columns)
    for row in rows:
        cleaned = []
        for value in row:
            if isinstance(value, str) and value.lstrip().startswith(("=", "+", "-", "@")):
                value = "'" + value
            cleaned.append(value)
        writer.writerow(cleaned)
    return "\ufeff" + output.getvalue()


class AdminJobFeatures:
    def init_admin_jobs(self, db):
        db.executescript("""
          CREATE TABLE IF NOT EXISTS admin_exports(
            id TEXT PRIMARY KEY,actor TEXT NOT NULL,fingerprint TEXT NOT NULL,
            status TEXT NOT NULL,document TEXT NOT NULL,result TEXT,created REAL NOT NULL,expires REAL NOT NULL);
          CREATE TABLE IF NOT EXISTS admin_alerts(
            id TEXT PRIMARY KEY,rule TEXT NOT NULL,severity TEXT NOT NULL,version INTEGER NOT NULL,
            status TEXT NOT NULL,present INTEGER NOT NULL,evidence TEXT NOT NULL,updated REAL NOT NULL);
          CREATE TABLE IF NOT EXISTS player_first_activity(owner TEXT PRIMARY KEY,day TEXT NOT NULL,first REAL NOT NULL);
          CREATE INDEX IF NOT EXISTS player_first_activity_day ON player_first_activity(day,owner);
        """)
        if not db.execute("SELECT 1 FROM admin_metadata WHERE key='first_activity_backfill'").fetchone():
            db.execute("INSERT OR IGNORE INTO player_first_activity SELECT owner,min(day),min(first) FROM player_activity GROUP BY owner")
            db.execute("INSERT INTO admin_metadata VALUES('first_activity_backfill','1')")
        db.execute("UPDATE admin_exports SET status='pending' WHERE status='working'")
        self.admin_last_risk_scan = 0

    def admin_job_read(self, db, actor, path, query):
        if path == "/admin/v1/retention":
            self.admin_permission(actor, "overview")
            require(not set(query) - {"day"}, "invalid_query", "Unexpected query")
            end = date.fromisoformat(query.get("day", day_key(self.clock())))
            require(end <= date.fromisoformat(day_key(self.clock())), "invalid_day", "Future cohorts are not available")
            rows = db.execute("""WITH cohorts AS (SELECT owner,day AS cohort FROM player_first_activity)
                SELECT cohort,count(*) AS accounts,
                  sum(EXISTS(SELECT 1 FROM player_activity a WHERE a.owner=c.owner AND a.day=date(c.cohort,'+1 day'))) AS d1,
                  sum(EXISTS(SELECT 1 FROM player_activity a WHERE a.owner=c.owner AND a.day=date(c.cohort,'+7 day'))) AS d7,
                  sum(EXISTS(SELECT 1 FROM player_activity a WHERE a.owner=c.owner AND a.day=date(c.cohort,'+30 day'))) AS d30
                FROM cohorts c WHERE cohort BETWEEN ? AND ? GROUP BY cohort ORDER BY cohort DESC""",
                ((end - timedelta(days=30)).isoformat(), end.isoformat())).fetchall()
            result = []
            for row in rows:
                item = dict(row)
                for delta in (1, 7, 30):
                    if date.fromisoformat(item["cohort"]) + timedelta(days=delta) > end:
                        item["d" + str(delta)] = None
                result.append(item)
            return {"cohorts": result, "as_of_day": end.isoformat(), "basis": "first_observed_game_activity", "timezone": "Asia/Shanghai"}
        if path == "/admin/v1/alerts":
            self.admin_permission(actor, "overview")
            require(not query, "invalid_query", "Unexpected query")
            rows = db.execute("SELECT * FROM admin_alerts ORDER BY present DESC,updated DESC LIMIT 100")
            return {"alerts": [dict(row, evidence=json.loads(row["evidence"])) for row in rows],
                    "as_of": self.clock(), "automatic_enforcement": False,
                    "last_scan": self.admin_last_risk_scan or None}
        if path.startswith("/admin/v1/exports/"):
            self.admin_permission(actor, "export")
            require(not query, "invalid_query", "Unexpected query")
            row = db.execute("SELECT * FROM admin_exports WHERE id=?", (path.rsplit("/", 1)[1],)).fetchone()
            require(row is not None, "export_not_found", "Export does not exist", 404)
            require(row["actor"] == actor["username"], "admin_forbidden", "Export belongs to another administrator", 403)
            expired = row["expires"] <= self.clock()
            return {"id": row["id"], "status": "expired" if expired else row["status"],
                    "result": json.loads(row["result"]) if not expired and row["result"] else None,
                    "expires_at": row["expires"]}
        if path == "/admin/v1/exports":
            self.admin_permission(actor, "export")
            require(not query, "invalid_query", "Unexpected query")
            jobs = []
            for row in db.execute("SELECT id,document,status,created,expires FROM admin_exports WHERE actor=? ORDER BY created DESC LIMIT 50", (actor["username"],)):
                instruction = json.loads(row["document"])
                jobs.append({"id": row["id"], "kind": instruction["kind"],
                             "status": "expired" if row["expires"] <= self.clock() else row["status"],
                             "filters": {key: instruction[key] for key in ("currency", "target", "start", "end", "species", "min_level", "max_level", "shiny", "min_iv") if key in instruction},
                             "created": row["created"], "expires": row["expires"]})
            return {"exports": jobs}
        return None

    def create_admin_export(self, db, actor, body):
        self.admin_permission(actor, "export")
        price_fields = {"species", "min_level", "max_level", "shiny", "min_iv"}
        obj(body, {"id", "kind", "currency", "target", "period", "start", "end"} | price_fields, {"id", "kind"})
        export_id = string(body["id"], 16, 100, "id", r"[A-Za-z0-9_-]+")
        require(body["kind"] in ("players", "ledger", "audit", "market_sales"), "invalid_export", "Unsupported export")
        target = string(body.get("target", ""), 0, 80, "target")
        require(body.get("currency", "MARKET") in ("RP", "MARKET", "GOLD"), "invalid_currency", "Choose RP, MARKET or GOLD")
        require(body["kind"] in ("ledger", "market_sales") or not set(body) & {"period", "start", "end"}, "invalid_export", "Dates apply to financial exports")
        require(body["kind"] == "market_sales" or not set(body) & price_fields, "invalid_export", "Price filters apply to paid sales")
        require(body["kind"] != "market_sales" or body.get("currency", "MARKET") in ("MARKET", "GOLD"), "invalid_currency", "Paid market sales use MARKET or GOLD")
        fingerprint = digest(dumps(body))
        old = db.execute("SELECT * FROM admin_exports WHERE id=?", (export_id,)).fetchone()
        if old:
            require(old["actor"] == actor["username"] and old["fingerprint"] == fingerprint, "export_conflict", "Export ID already used", 409)
            return 200, {"ok": True, "id": export_id, "status": "expired" if old["expires"] <= self.clock() else old["status"]}
        instruction = dict(body)
        period = self.economy_period(body, default="30d" if body["kind"] == "market_sales" else None) if body["kind"] in ("ledger", "market_sales") else None
        if period:
            instruction.update(period="custom", start=period["start_day"], end=period["end_day"])
        if body["kind"] == "market_sales":
            instruction.update(self.market_price_filters({key: value for key, value in body.items() if key in price_fields}))
            instruction["currency"] = body.get("currency", "MARKET")
        pending = db.execute("SELECT count(*) FROM admin_exports WHERE actor=? AND status IN ('pending','working')", (actor["username"],)).fetchone()[0]
        require(pending < 2, "export_busy", "Finish current exports first", 429)
        db.execute("INSERT INTO admin_exports VALUES(?,?,?,'pending',?,NULL,?,?)", (export_id, actor["username"], fingerprint, dumps(instruction), self.clock(), self.clock() + 86400))
        self.audit(db, actor["username"], "export_requested", target, detail={"id": export_id, "kind": body["kind"], "currency": body.get("currency"), "start": instruction.get("start"), "end": instruction.get("end")})
        return 202, {"ok": True, "id": export_id, "status": "pending"}

    def process_admin_export(self):
        with self.connect() as db:
            db.execute("UPDATE admin_exports SET status='expired',result=NULL WHERE expires<=? AND status!='expired'", (self.clock(),))
            row = db.execute("SELECT * FROM admin_exports WHERE status='pending' ORDER BY created LIMIT 1").fetchone()
            if row is None:
                return
            job = dict(row)
            db.execute("UPDATE admin_exports SET status='working' WHERE id=?", (job["id"],))
        instruction = json.loads(job["document"])
        try:
            with closing(readonly(self.database)) as db:
                db.execute("BEGIN")
                target = instruction.get("target", "")
                if instruction["kind"] == "players":
                    columns = ("id", "nickname", "friend_code", "username", "created")
                    rows = db.execute("""SELECT i.id,i.nickname,i.friend_code,a.username,i.created FROM identities i
                        LEFT JOIN accounts a ON a.owner=i.id WHERE (?='' OR i.id=?) ORDER BY i.id LIMIT 5001""", (target, target)).fetchall()
                elif instruction["kind"] == "ledger":
                    columns = ("id", "owner", "currency", "amount", "balance", "event", "created")
                    period = self.economy_period(instruction, default=None)
                    start, end = (period["start"], period["end"]) if period else (-1e15, 1e15)
                    rows = db.execute("""SELECT id,owner,currency,amount,balance,event,created FROM shop_ledger WHERE currency=?
                        AND (?='' OR owner=?) AND created>=? AND created<? AND created<=? ORDER BY id DESC LIMIT 5001""",
                        (instruction.get("currency", "MARKET"), target, target, start, end, self.clock())).fetchall()
                elif instruction["kind"] == "market_sales":
                    columns = ("listing_id", "asset_id", "seller", "buyer", "price", "currency", "sold_at", "species", "level", "shiny", "iv_total")
                    period = self.economy_period(instruction)
                    filters = self.market_price_filters({key: instruction[key] for key in ("species", "min_level", "max_level", "shiny", "min_iv") if key in instruction})
                    sales_table = "original_paid_sales" if instruction["currency"] == "GOLD" else "market_sales"
                    rows = db.execute("SELECT " + ",".join(columns) + " FROM " + sales_table + " WHERE sold_at>=? AND sold_at<? AND sold_at<=? AND (?='' OR species=?) AND level BETWEEN ? AND ? AND iv_total>=? AND (?='any' OR shiny=?) AND (?='' OR buyer=? OR seller=?) ORDER BY sold_at DESC,listing_id LIMIT 5001",
                        (period["start"], period["end"], self.clock(), filters["species"], filters["species"], filters["min_level"], filters["max_level"], filters["min_iv"], filters["shiny"], int(filters["shiny"]) if filters["shiny"] != "any" else -1, target, target, target)).fetchall()
                else:
                    columns = ("id", "actor", "action", "target", "reason", "created")
                    rows = db.execute("SELECT id,actor,action,target,reason,created FROM admin_audit WHERE (?='' OR target=?) ORDER BY id DESC LIMIT 5001", (target, target)).fetchall()
                as_of = self.clock()
                if len(rows) > 5000:
                    result, status = {"error": "row_limit_exceeded", "message": "More than 5000 rows; narrow the target filter"}, "failed"
                else:
                    content = csv_text(columns, rows)
                    if len(content.encode("utf-8")) > 4 * 1024 * 1024:
                        result, status = {"error": "size_limit_exceeded"}, "failed"
                    else:
                        result, status = {"csv": content, "rows": len(rows), "as_of": as_of,
                                          "filters": {key: instruction[key] for key in ("currency", "target", "start", "end", "species", "min_level", "max_level", "shiny", "min_iv") if key in instruction},
                                          "filename": instruction["kind"] + "-" + job["id"] + ".csv"}, "ready"
        except (sqlite3.Error, ValueError, OSError, APIError):
            result, status = {"error": "export_query_failed"}, "failed"
        with self.connect() as db:
            db.execute("UPDATE admin_exports SET status=?,result=? WHERE id=?", (status, dumps(result), job["id"]))
            self.audit(db, job["actor"], "export_" + status, instruction.get("target", ""), detail={"id": job["id"], "rows": result.get("rows")})

    def scan_admin_risks(self):
        observations = []
        with closing(readonly(self.database)) as db:
            observations.extend(self.market_price_risks(db))
            for currency in ("MARKET", "RP", "GOLD"):
                report = self.economy_reconciliation(db, currency)
                if not report["ok"]:
                    observations.append(("reconciliation:" + currency, "ledger_reconciliation", "error", dict(report, currency=currency)))
            inventory = self.controlled_inventory_audit(db)
            if not inventory["ok"]:
                observations.append(("controlled-inventory", "controlled_inventory_reconciliation", "error", inventory))
            rows = db.execute("""SELECT id,owner,json_extract(document,'$.owner_id') AS embedded_owner FROM hosted_assets
                WHERE coalesce(json_extract(document,'$.owner_id'),'')!=owner LIMIT 100""").fetchall()
            for row in rows:
                observations.append(("asset-owner:" + row["id"], "asset_owner_mismatch", "error", dict(row)))
            rows = db.execute("""SELECT currency,sum(amount) AS amount,count(*) AS events FROM shop_ledger
                WHERE created>? AND amount>0 AND (event LIKE 'gm:%' OR event LIKE 'admin:%' OR event LIKE 'redeem:%')
                GROUP BY currency HAVING sum(amount)>100000""", (self.clock() - 3600,)).fetchall()
            for row in rows:
                observations.append(("issuance:" + row["currency"], "concentrated_issuance", "warning", dict(row, window_seconds=3600)))
        with self.connect() as db:
            previous = {row["id"]: dict(row) for row in db.execute("SELECT id,present,evidence FROM admin_alerts")}
            db.execute("UPDATE admin_alerts SET present=0 WHERE present=1")
            for key, rule, severity, evidence in observations:
                serialized = dumps(dict(evidence, rule_version=1))
                old = previous.get(key)
                changed = old is not None and (old["evidence"] != serialized or not old["present"])
                if old:
                    db.execute("UPDATE admin_alerts SET present=1,updated=?,version=version+?,evidence=?,status=CASE WHEN ? THEN 'open' ELSE status END WHERE id=?",
                               (self.clock(), int(changed), serialized, int(changed), key))
                else:
                    db.execute("INSERT INTO admin_alerts VALUES(?,?,?,1,'open',1,?,?)", (key, rule, severity, serialized, self.clock()))
            db.execute("INSERT OR REPLACE INTO admin_metadata VALUES('last_risk_scan',?)", (str(self.clock()),))
        self.admin_last_risk_scan = self.clock()

    def admin_alert_command(self, db, actor, body):
        self.admin_permission(actor, "moderate")
        obj(body, {"id", "action", "target", "reason", "expected_version", "status"}, {"id", "action", "target", "reason", "expected_version", "status"})
        command_id = string(body["id"], 16, 100, "id", r"[A-Za-z0-9_-]+")
        target = string(body["target"], 1, 120, "target")
        reason = string(body["reason"], 3, 500, "reason")
        require(body["status"] in ("investigating", "resolved", "open"), "invalid_status", "Unsupported case state")
        version = integer(body["expected_version"], 1, 2**53 - 1, "expected_version")
        fingerprint = digest(dumps(body))
        old = db.execute("SELECT * FROM admin_commands WHERE id=?", (command_id,)).fetchone()
        if old:
            require(old["actor"] == actor["username"] and old["fingerprint"] == fingerprint, "command_conflict", "Command ID already used", 409)
            return 200, json.loads(old["response"])
        alert = db.execute("SELECT * FROM admin_alerts WHERE id=?", (target,)).fetchone()
        require(alert is not None, "alert_not_found", "Alert does not exist", 404)
        require(alert["version"] == version, "alert_version_conflict", "Evidence changed; review the case again", 409)
        db.execute("UPDATE admin_alerts SET status=?,version=version+1 WHERE id=?", (body["status"], target))
        result = {"ok": True, "status": "completed", "command_id": command_id, "alert_id": target}
        self.audit(db, actor["username"], "alert_status", target, reason, {"before": alert["status"], "after": body["status"], "version": version + 1})
        db.execute("INSERT INTO admin_commands VALUES(?,?,?,?,?)", (command_id, actor["username"], fingerprint, dumps(result), self.clock()))
        return 200, result
