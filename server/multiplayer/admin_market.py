"""Verified paid-sale analytics. Quotes and reciprocal receipts are not volume."""
from collections import defaultdict
import math
import statistics

try:
    from .admin_data import day_key
except ImportError:
    from admin_data import day_key


def bind_api(api):
    for name in ("obj", "require", "string", "integer", "dumps", "digest", "APIError"):
        globals()[name] = api[name]


def price_summary(rows):
    prices = sorted(row["price"] for row in rows)
    quantile = lambda value: prices[max(0, math.ceil(len(prices) * value) - 1)] if prices else None
    return {"trades": len(rows), "volume": sum(prices), "minimum": prices[0] if prices else None,
            "maximum": prices[-1] if prices else None, "median": statistics.median(prices) if prices else None,
            "mean": round(sum(prices) / len(prices), 2) if prices else None,
            "p10": quantile(.10), "p25": quantile(.25), "p75": quantile(.75), "p90": quantile(.90),
            "buyers": len({row["buyer"] for row in rows}), "sellers": len({row["seller"] for row in rows}),
            "distinct_assets": len({row["asset_id"] for row in rows}),
            "median_seconds_to_sell": statistics.median(max(0, row["sold_at"] - row["listed_at"]) for row in rows) if rows else None}


def price_group(row):
    return row["species"], (row["level"] - 1) // 10 * 10 + 1, bool(row["shiny"]), "150-186" if row["iv_total"] >= 150 else "90-149" if row["iv_total"] >= 90 else "0-89"


class MarketAnalyticsFeatures:
    def init_market_analytics(self, db):
        iv_total = "+".join("json_extract(l.document,'$.snapshot.iv." + key + "')" for key in ("HP", "ATTACK", "DEFENSE", "SPECIAL_ATTACK", "SPECIAL_DEFENSE", "SPEED"))
        db.executescript("""
          CREATE TABLE IF NOT EXISTS market_sales(
            listing_id TEXT PRIMARY KEY,asset_id TEXT NOT NULL,seller TEXT NOT NULL,buyer TEXT NOT NULL,
            price INTEGER NOT NULL,currency TEXT NOT NULL,sold_at REAL NOT NULL,listed_at REAL NOT NULL,
            species TEXT NOT NULL,level INTEGER NOT NULL,shiny INTEGER NOT NULL,iv_total INTEGER NOT NULL,
            buyer_ledger_id INTEGER NOT NULL UNIQUE,seller_ledger_id INTEGER NOT NULL UNIQUE);
          CREATE INDEX IF NOT EXISTS market_sales_period ON market_sales(sold_at,listing_id);
          CREATE INDEX IF NOT EXISTS market_sales_species_period ON market_sales(species,sold_at);
          CREATE INDEX IF NOT EXISTS market_sales_asset_time ON market_sales(asset_id,sold_at);
          CREATE INDEX IF NOT EXISTS market_sales_parties_time ON market_sales(asset_id,seller,buyer,sold_at);
          CREATE INDEX IF NOT EXISTS shop_ledger_currency_event ON shop_ledger(currency,event);
          CREATE INDEX IF NOT EXISTS market_listings_status ON market_listings(status,id);
          CREATE VIEW IF NOT EXISTS market_sale_candidates AS
            SELECT l.id AS listing_id,l.asset_id,l.owner AS seller,b.owner AS buyer,l.price,'MARKET' AS currency,
              json_extract(r.document,'$.created_at') AS sold_at,json_extract(l.document,'$.created_at') AS listed_at,
              json_extract(l.document,'$.snapshot.species') AS species,json_extract(l.document,'$.snapshot.level') AS level,
              json_extract(l.document,'$.snapshot.shiny') AS shiny,(""" + iv_total + """) AS iv_total,
              b.id AS buyer_ledger_id,s.id AS seller_ledger_id
            FROM market_listings l
            JOIN market_receipts r ON r.owner=l.owner AND r.request_id='sold_'||l.id
            JOIN shop_ledger b ON b.currency='MARKET' AND b.event='buy:'||l.id AND b.amount=-l.price AND b.owner!=l.owner
            JOIN shop_ledger s ON s.owner=l.owner AND s.currency='MARKET' AND s.event='sell:'||l.id AND s.amount=l.price
            WHERE l.status='sold' AND json_extract(r.document,'$.kind')='sold'
              AND json_extract(r.document,'$.listing_id')=l.id AND json_extract(r.document,'$.asset_id')=l.asset_id
              AND json_extract(r.document,'$.price')=l.price
              AND json_type(r.document,'$.created_at') IN ('integer','real')
              AND json_type(l.document,'$.created_at') IN ('integer','real')
              AND json_type(l.document,'$.snapshot.species')='text'
              AND json_type(l.document,'$.snapshot.level')='integer' AND json_extract(l.document,'$.snapshot.level') BETWEEN 1 AND 100
              AND json_type(l.document,'$.snapshot.shiny') IN ('true','false')
              AND (""" + iv_total + """) BETWEEN 0 AND 186
              AND (SELECT count(*) FROM shop_ledger x WHERE x.currency='MARKET' AND x.event='buy:'||l.id)=1;
          CREATE TRIGGER IF NOT EXISTS market_sale_on_settle AFTER UPDATE OF status ON market_listings WHEN NEW.status='sold' BEGIN
            INSERT OR IGNORE INTO market_sales SELECT * FROM market_sale_candidates WHERE listing_id=NEW.id;
          END;
          CREATE TRIGGER IF NOT EXISTS market_sale_on_receipt AFTER INSERT ON market_receipts BEGIN
            INSERT OR IGNORE INTO market_sales SELECT * FROM market_sale_candidates WHERE listing_id=json_extract(NEW.document,'$.listing_id');
          END;
          CREATE TRIGGER IF NOT EXISTS market_sales_immutable_update BEFORE UPDATE ON market_sales BEGIN
            SELECT RAISE(ABORT,'Paid-sale journal is append-only'); END;
          CREATE TRIGGER IF NOT EXISTS market_sales_immutable_delete BEFORE DELETE ON market_sales BEGIN
            SELECT RAISE(ABORT,'Paid-sale journal is append-only'); END;
        """)
        if db.execute("SELECT 1 FROM admin_metadata WHERE key='market_sales_backfill_v1'").fetchone() is None:
            db.execute("INSERT OR IGNORE INTO market_sales SELECT * FROM market_sale_candidates")
            db.execute("INSERT INTO admin_metadata VALUES('market_sales_backfill_v1','1')")
            db.execute("INSERT INTO admin_metadata VALUES('market_sales_started',?)", (str(self.clock()),))

    def market_prices_integrity(self, db, currency="MARKET"):
        if currency == "GOLD":
            missing = db.execute("SELECT count(*) FROM original_market l WHERE l.status='sold' AND NOT EXISTS(SELECT 1 FROM original_sales s WHERE s.listing_id=l.id)").fetchone()[0]
            mismatched = db.execute("""SELECT count(*) FROM original_sales s
                LEFT JOIN shop_ledger b ON b.id=s.buyer_ledger LEFT JOIN shop_ledger p ON p.id=s.seller_ledger
                LEFT JOIN original_ownership o ON o.id=s.ownership_id
                WHERE b.id IS NULL OR p.id IS NULL OR o.id IS NULL OR b.owner!=s.buyer OR p.owner!=s.seller
                  OR b.currency!='GOLD' OR p.currency!='GOLD' OR b.amount!=-(s.price-s.fee) OR p.amount!=s.price-s.fee
                  OR b.event!='managed:original_market_buy:'||s.listing_id OR p.event!='managed:original_market_sell:'||s.listing_id
                  OR o.monster_id!=s.monster_id OR o.source!=s.seller OR o.target!=s.buyer
                  OR (s.fee>0 AND NOT EXISTS(SELECT 1 FROM shop_ledger t WHERE t.owner=s.buyer AND t.currency='GOLD'
                      AND t.event='managed:original_market_tax:'||s.listing_id AND t.amount=-s.fee))""").fetchone()[0]
            return {"ok": not (missing or mismatched), "unprojected_sales": missing, "ledger_mismatches": mismatched}
        missing = db.execute("SELECT count(*) FROM market_listings l WHERE l.status='sold' AND NOT EXISTS(SELECT 1 FROM market_sales s WHERE s.listing_id=l.id)").fetchone()[0]
        mismatched = db.execute("""SELECT count(*) FROM market_sales s
            LEFT JOIN shop_ledger b ON b.id=s.buyer_ledger_id LEFT JOIN shop_ledger p ON p.id=s.seller_ledger_id
            WHERE b.id IS NULL OR p.id IS NULL OR b.owner!=s.buyer OR p.owner!=s.seller OR b.currency!='MARKET'
              OR p.currency!='MARKET' OR b.amount!=-s.price OR p.amount!=s.price
              OR b.event!='buy:'||s.listing_id OR p.event!='sell:'||s.listing_id""").fetchone()[0]
        return {"ok": not (missing or mismatched), "unprojected_sales": missing, "ledger_mismatches": mismatched}

    def market_price_filters(self, query):
        require(not set(query) - {"period", "start", "end", "day", "species", "min_level", "max_level", "shiny", "min_iv", "currency"}, "invalid_query", "Unexpected query")
        species = string(query.get("species", ""), 0, 64, "species", r"[A-Z0-9_]*")
        require(all(type(query[key]) in (str, int) for key in ("min_level", "max_level", "min_iv") if key in query), "invalid_price_filter", "Integer level and IV filters required")
        try:
            low = integer(int(query.get("min_level", "1")), 1, 100, "min_level")
            high = integer(int(query.get("max_level", "100")), low, 100, "max_level")
            iv = integer(int(query.get("min_iv", "0")), 0, 186, "min_iv")
        except (ValueError, TypeError):
            raise APIError(400, "invalid_price_filter", "Invalid level or IV filter")
        shiny = query.get("shiny", "any")
        require(shiny in ("any", "0", "1"), "invalid_price_filter", "Choose any, 0 or 1 for shiny")
        return {"species": species, "min_level": low, "max_level": high, "min_iv": iv, "shiny": shiny}

    def market_prices_read(self, db, actor, path, query):
        if path != "/admin/v1/market-prices":
            return None
        self.admin_permission(actor, "overview")
        filters = self.market_price_filters(query)
        currency = query.get("currency", "MARKET")
        require(currency in ("MARKET", "GOLD"), "invalid_currency", "Choose MARKET or GOLD")
        sales_table = "original_paid_sales" if currency == "GOLD" else "market_sales"
        period = self.economy_period(query, default="30d")
        clause = "(?='' OR species=?) AND level BETWEEN ? AND ? AND iv_total>=? AND (?='any' OR shiny=?)"
        args = (filters["species"], filters["species"], filters["min_level"], filters["max_level"], filters["min_iv"], filters["shiny"], int(filters["shiny"]) if filters["shiny"] != "any" else -1)
        def read(start, end, as_of):
            rows = [dict(row) for row in db.execute("SELECT * FROM " + sales_table + " WHERE sold_at>=? AND sold_at<? AND sold_at<=? AND " + clause + " ORDER BY sold_at,listing_id LIMIT 10001", (start, end, as_of, *args))]
            require(len(rows) <= 10000, "price_report_too_large", "More than 10000 sales; narrow the dates or species", 413)
            return rows
        rows = read(period["start"], period["end"], period["as_of"])
        previous = read(period["previous_start"], period["previous_end"], period["previous_as_of"])
        grouped, daily = defaultdict(list), defaultdict(list)
        for row in rows:
            grouped[price_group(row)].append(row)
            daily[day_key(row["sold_at"])].append(row)
        groups = []
        for (species, level, shiny, iv_band), values in grouped.items():
            summary = price_summary(values)
            groups.append({"species": species, "min_level": level, "max_level": min(100, level + 9), "shiny": shiny, "iv_band": iv_band,
                           **summary, "sufficient_sample": summary["trades"] >= 5 and summary["distinct_assets"] >= 3 and summary["buyers"] >= 3})
        groups.sort(key=lambda row: (-row["volume"], row["species"], row["min_level"], row["shiny"], row["iv_band"]))
        first_sale = db.execute("SELECT min(sold_at) FROM " + sales_table).fetchone()[0]
        started = float(db.execute("SELECT value FROM admin_metadata WHERE key=?", ("original_market_started" if currency == "GOLD" else "market_sales_started",)).fetchone()[0])
        period["known_since"] = min(started, first_sale) if first_sale is not None else started
        period["coverage_complete"] = period["start"] >= period["known_since"]
        period["previous_coverage_complete"] = period["previous_start"] >= period["known_since"]
        # Current asks are a separate projection, not historical paid prices.
        ask_clause = "status='active' AND expires>? AND (?='' OR json_extract(document,'$.snapshot.species')=?) AND json_extract(document,'$.snapshot.level') BETWEEN ? AND ? AND (" + "+".join("json_extract(document,'$.snapshot.iv." + key + "')" for key in ("HP", "ATTACK", "DEFENSE", "SPECIAL_ATTACK", "SPECIAL_DEFENSE", "SPEED")) + ")>=? AND (?='any' OR json_extract(document,'$.snapshot.shiny')=?)"
        ask_args = (self.clock(), *args)
        ask_table = "market_listings"
        if currency == "GOLD":
            ask_table = "original_market"
            ask_clause = ask_clause.replace("document,'$.snapshot.", "snapshot,'$.")
        asks = [row[0] for row in db.execute("SELECT price FROM " + ask_table + " WHERE " + ask_clause + " ORDER BY price LIMIT 10001", ask_args)]
        ask_count = db.execute("SELECT count(*) FROM " + ask_table + " WHERE " + ask_clause, ask_args).fetchone()[0]
        return {"currency": currency, "basis": "one_verified_paid_listing", "period": period, "filters": filters,
                "summary": price_summary(rows), "previous_summary": price_summary(previous),
                "groups": groups[:100], "group_count": len(groups), "groups_limited": len(groups) > 100,
                "daily": [{"day": day, **price_summary(values)} for day, values in sorted(daily.items())],
                "active_asks": {"count": ask_count, "median": statistics.median(asks) if asks and len(asks) <= 10000 else None,
                                "median_status": "available" if len(asks) <= 10000 else "too_many_quotes"},
                "integrity": self.market_prices_integrity(db, currency), "quantiles": "nearest_rank", "as_of": period["as_of"],
                "recent_sales": [{key: row[key] for key in ("listing_id", "asset_id", "species", "level", "shiny", "iv_total", "price", "sold_at")} for row in reversed(rows[-50:])]}

    def market_price_risks(self, db):
        return self.market_currency_risks(db, "MARKET") + self.market_currency_risks(db, "GOLD")

    def market_currency_risks(self, db, currency):
        observations = []
        source = "SELECT s.rowid AS sequence,v.* FROM original_sales s JOIN original_paid_sales v ON v.listing_id=s.listing_id" if currency == "GOLD" else "SELECT rowid AS sequence,* FROM market_sales"
        with_sales = "WITH sales AS ("+source+") "
        integrity = self.market_prices_integrity(db, currency)
        if not integrity["ok"]:
            observations.append(("market-paid-sales:"+currency, "market_sale_journal_gap", "error", dict(integrity, currency=currency)))
        cycles = db.execute(with_sales + """SELECT a.asset_id,a.listing_id AS first_listing,b.listing_id AS return_listing,
                a.seller,a.buyer,a.price AS first_price,b.price AS return_price
            FROM sales b JOIN sales a ON a.sequence=(SELECT p.sequence FROM sales p
                WHERE p.asset_id=b.asset_id AND p.seller=b.buyer AND p.buyer=b.seller AND p.sold_at<=b.sold_at
                  AND (p.sold_at<b.sold_at OR p.sequence<b.sequence) AND b.sold_at-p.sold_at<=3600
                ORDER BY p.sold_at DESC,p.sequence DESC LIMIT 1)
            WHERE b.sold_at>=? ORDER BY b.sold_at DESC,b.sequence DESC LIMIT 100""", (self.clock() - 86400,)).fetchall()
        for row in cycles:
            observations.append(("market-cycle:" + row["return_listing"], "market_asset_round_trip", "warning", dict(row, window_seconds=3600)))
        recent = [dict(row) for row in db.execute(with_sales + "SELECT * FROM sales WHERE sold_at>=? ORDER BY sold_at DESC LIMIT 10001", (self.clock() - 86400,))]
        if len(recent) <= 10000:
            grouped = defaultdict(list)
            for row in recent:
                grouped[price_group(row)].append(row)
            price_alerts = 0
            for values in grouped.values():
                if price_alerts >= 100:
                    break
                summary = price_summary(values)
                if summary["trades"] < 6 or summary["distinct_assets"] < 3 or summary["buyers"] < 3:
                    continue
                prices = sorted(row["price"] for row in values)
                positions = {}
                for index, price in enumerate(prices):
                    positions.setdefault(price, index)
                for row in values:
                    removed = positions[row["price"]]
                    left, right = (len(prices) - 2) // 2, (len(prices) - 1) // 2
                    baseline = (prices[left + int(left >= removed)] + prices[right + int(right >= removed)]) / 2
                    if row["price"] > baseline * 5 or row["price"] * 5 < baseline:
                        observations.append(("market-price:" + row["listing_id"], "market_price_deviation", "warning", {
                            "listing_id": row["listing_id"], "species": row["species"], "price": row["price"], "peer_median": baseline,
                            "peer_trades": len(values) - 1, "group": list(price_group(row)), "multiple": 5, "window_seconds": 86400}))
                        price_alerts += 1
                        if price_alerts >= 100:
                            break
        else:
            observations.append(("market-price-scan-limit:"+currency, "market_price_scan_limit", "warning", {"limit": 10000, "window_seconds": 86400}))
        owner_join = "JOIN controlled_characters c ON c.id=s.buyer JOIN accounts a ON a.owner=c.owner" if currency == "GOLD" else "JOIN accounts a ON a.owner=s.buyer"
        for row in db.execute(with_sales + """SELECT s.buyer,count(*) AS trades,sum(s.price) AS volume,i.created AS account_created
            FROM sales s """ + owner_join + """ JOIN identities i ON i.id=a.owner WHERE s.sold_at>=? AND i.created>=?
            GROUP BY s.buyer HAVING count(*)>=5 AND sum(s.price)>=100000 LIMIT 100""", (self.clock() - 86400, self.clock() - 604800)):
            observations.append(("market-new-buyer:" + row["buyer"], "new_account_market_concentration", "warning", dict(row, window_seconds=86400)))
        return [(key, rule, severity, dict(evidence, currency=currency)) for key, rule, severity, evidence in observations]
