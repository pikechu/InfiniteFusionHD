"""Transactional producer of controlled campaign assets, never cloud imports."""
import copy
import hashlib
import json
from pathlib import Path
import secrets

try:
    from . import controlled_engine as engine
    from .admin_data import day_key
except ImportError:
    import controlled_engine as engine
    from admin_data import day_key


def bind_api(api):
    for name in ("obj", "require", "string", "integer", "dumps", "digest", "APIError"):
        globals()[name] = api[name]


class ControlledAdventureFeatures:
    def init_controlled_adventure(self, db):
        db.executescript("""
          CREATE TABLE IF NOT EXISTS controlled_progress(character_id TEXT PRIMARY KEY,document TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS controlled_monsters(id TEXT PRIMARY KEY,character_id TEXT NOT NULL,status TEXT NOT NULL,document TEXT NOT NULL);
          CREATE INDEX IF NOT EXISTS controlled_monsters_character ON controlled_monsters(character_id,status);
          CREATE TABLE IF NOT EXISTS controlled_battles(id TEXT PRIMARY KEY,character_id TEXT NOT NULL,status TEXT NOT NULL,document TEXT NOT NULL);
          CREATE UNIQUE INDEX IF NOT EXISTS controlled_one_battle ON controlled_battles(character_id) WHERE status='active';
          CREATE TABLE IF NOT EXISTS controlled_rulebooks(hash TEXT PRIMARY KEY,document TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS controlled_captures(battle_id TEXT PRIMARY KEY,monster_id TEXT NOT NULL UNIQUE);
          CREATE TABLE IF NOT EXISTS controlled_encounter_usage(owner TEXT NOT NULL,day TEXT NOT NULL,count INTEGER NOT NULL,PRIMARY KEY(owner,day));
          CREATE TABLE IF NOT EXISTS controlled_creature_events(
            id INTEGER PRIMARY KEY AUTOINCREMENT,monster_id TEXT NOT NULL,character_id TEXT NOT NULL,kind TEXT NOT NULL,
            reference TEXT NOT NULL,document TEXT NOT NULL,created REAL NOT NULL,UNIQUE(monster_id,kind,reference));
          CREATE TRIGGER IF NOT EXISTS controlled_creatures_immutable_update BEFORE UPDATE ON controlled_creature_events BEGIN
            SELECT RAISE(ABORT,'Creature journal is append-only'); END;
          CREATE TRIGGER IF NOT EXISTS controlled_creatures_immutable_delete BEFORE DELETE ON controlled_creature_events BEGIN
            SELECT RAISE(ABORT,'Creature journal is append-only'); END;
        """)
        self._adventure_catalog_cache = None

    def adventure_catalog(self):
        path = Path(__file__).parent / "catalog-controlled-adventure-v1.json"
        try:
            stamp = (path.stat().st_mtime_ns, path.stat().st_size)
            if self._adventure_catalog_cache and self._adventure_catalog_cache[0] == stamp:
                return self._adventure_catalog_cache[1]
            raw = path.read_bytes()
            require(len(raw) <= 4 * 1024 * 1024, "adventure_catalog_unavailable", "Adventure catalog too large", 503)
            catalog = json.loads(raw)
            require(catalog["version"] == 1 and catalog["rules"] == "controlled-adventure-v1" and
                    1 <= len(catalog["species"]) <= 1500 and 1 <= len(catalog["moves"]) <= 1000 and
                    1 <= len(catalog["stages"]) <= 100 and 1 <= len(catalog["regions"]) <= 500,
                    "adventure_catalog_unavailable", "Unsupported adventure catalog", 503)
            catalog["hash"] = hashlib.sha256(raw).hexdigest()
            for stage in catalog["stages"]:
                require(1 <= len(stage["party"]) <= 6, "adventure_catalog_unavailable", "Invalid trainer party", 503)
                for monster in stage["party"]:
                    engine.species_info(catalog, monster["species"])
                    integer(monster["level"], 1, 100, "level")
            self._adventure_catalog_cache = (stamp, catalog)
            return catalog
        except (OSError, ValueError, KeyError, TypeError):
            raise APIError(503, "adventure_catalog_unavailable", "Trusted adventure catalog unavailable")

    def adventure_public_catalog(self):
        catalog = self.adventure_catalog()
        return {key: catalog[key] for key in ("hash", "version", "rules", "policy", "starters", "stages", "moves",
                    "level_max", "daily_encounter_limit", "storage_limit", "training_cost_per_ev", "relearn_cost", "heal_cost",
                    "breed_cost", "hatch_seconds", "fusion_cost", "evolution_cost")} | {
            "regions": [{"id": row["id"], "name": row["name"], "map_id": row["map_id"],
                         "min_level": min(entry["min_level"] for entry in row["encounters"])} for row in catalog["regions"]]}

    def adventure_progress(self, db, character_id):
        row = db.execute("SELECT document FROM controlled_progress WHERE character_id=?", (character_id,)).fetchone()
        return json.loads(row[0]) if row else {"chapter": 0, "party": [], "starter_claimed": False, "last_started": 0}

    def adventure_save_progress(self, db, character_id, progress):
        db.execute("INSERT OR REPLACE INTO controlled_progress VALUES(?,?)", (character_id, dumps(progress)))

    def adventure_monster(self, db, character_id, identifier):
        string(identifier, 35, 35, "monster_id", r"cm_[a-f0-9]{32}")
        row = db.execute("SELECT * FROM controlled_monsters WHERE id=? AND character_id=? AND status='active'", (identifier, character_id)).fetchone()
        require(row is not None, "controlled_monster_not_found", "Creature unavailable or belongs to another character", 404)
        return json.loads(row["document"])

    def adventure_record_monster(self, db, character_id, monster, kind, reference, *, mint=False, status="active"):
        # Only this server produces the document. Revisions and immutable events
        # bind every mutation to a battle turn or persistent player receipt.
        previous = db.execute("SELECT document FROM controlled_monsters WHERE id=?", (monster["id"],)).fetchone()
        require(mint == (previous is None), "creature_journal_conflict", "Creature identity already used or missing", 409)
        clean = {key: copy.deepcopy(value) for key, value in monster.items() if key not in
                 ("stages", "flinch", "protect", "protect_chain", "focus", "seeded", "confusion", "toxic_count")}
        clean["revision"] = 1 if mint else json.loads(previous[0])["revision"] + 1
        monster["revision"] = clean["revision"]
        document = dumps(clean)
        db.execute("INSERT OR REPLACE INTO controlled_monsters VALUES(?,?,?,?)", (monster["id"], character_id, status, document))
        detail = {"before_hash": digest(previous[0]) if previous else None, "after_hash": digest(document),
                  "status": status, "species": clean["species"], "level": clean["level"], "revision": clean["revision"]}
        db.execute("INSERT INTO controlled_creature_events(monster_id,character_id,kind,reference,document,created) VALUES(?,?,?,?,?,?)",
                   (monster["id"], character_id, kind, reference, dumps(detail), self.clock()))

    def adventure_active_battle(self, db, character_id, *, expire=True):
        row = db.execute("SELECT document FROM controlled_battles WHERE character_id=? AND status='active'", (character_id,)).fetchone()
        battle = json.loads(row[0]) if row else None
        if expire and battle and battle["expires"] <= self.clock():
            battle.update(status="expired", outcome="expired")
            self.adventure_save_battle(db, battle)
            return None
        return battle

    def adventure_save_battle(self, db, battle):
        db.execute("INSERT OR REPLACE INTO controlled_battles VALUES(?,?,?,?)", (battle["id"], battle["character_id"], battle["status"], dumps(battle)))

    def adventure_battle_catalog(self, db, battle):
        row = db.execute("SELECT document FROM controlled_rulebooks WHERE hash=?", (battle["catalog_hash"],)).fetchone()
        require(row is not None, "battle_rules_unavailable", "Battle's original rulebook is unavailable", 503)
        return json.loads(row[0])

    def adventure_battle_view(self, db, battle):
        if battle is None:
            return None
        catalog = self.adventure_battle_catalog(db, battle)
        def visible(monster):
            return {"id": monster["id"], "species": monster["species"], "name": engine.species_info(catalog, monster["species"])["real_name"],
                    "level": monster["level"], "hp": monster["hp"], "max_hp": engine.stats(catalog, monster)["HP"], "status": monster["status"]}
        return {key: copy.deepcopy(battle[key]) for key in ("id", "kind", "chapter", "round", "status", "outcome", "expires", "catalog_hash", "log", "result")} | {
            "active": battle["player_active"], "enemy_active": battle["enemy_active"],
            "party": [visible(monster) | {"moves": monster["moves"]} for monster in battle["party"]],
            "enemies": [visible(monster) for monster in battle["enemies"]]}

    def adventure_view(self, db, character, *, expire=True):
        catalog = self.adventure_catalog()
        progress = self.adventure_progress(db, character["id"])
        monsters = []
        for row in db.execute("SELECT document FROM controlled_monsters WHERE character_id=? AND status='active' ORDER BY rowid", (character["id"],)):
            monster = json.loads(row[0])
            info = engine.species_info(catalog, monster["species"])
            monsters.append(monster | {"name": info["real_name"], "stats": engine.stats(catalog, monster),
                                      "learnable_moves": engine.legal_moves(catalog, monster), "evolutions": info["evolutions"]})
        return {"progress": progress, "monsters": monsters,
                "battle": self.adventure_battle_view(db, self.adventure_active_battle(db, character["id"], expire=expire)),
                "level_cap": catalog["stages"][min(progress["chapter"], len(catalog["stages"]) - 1)]["level_cap"], "rules_hash": catalog["hash"]}

    def adventure_limit_storage(self, db, character_id):
        count = db.execute("SELECT count(*) FROM controlled_monsters WHERE character_id=? AND status='active'", (character_id,)).fetchone()[0]
        require(count < self.adventure_catalog()["storage_limit"], "controlled_storage_full", "Creature storage is full", 409)

    def controlled_adventure_request(self, db, identity, method, parts, body):
        if method == "GET" and parts == ["v1", "controlled", "adventure-catalog"]:
            return {"ok": True, "catalog": self.adventure_public_catalog()}
        if len(parts) != 5 or parts[2] != "characters" or parts[4] != "adventure":
            return None
        character = self.controlled_character(db, parts[3], identity["id"])
        require(self.original_row(db, character["id"]) is None, "original_rules_active", "Use the original game interface for this character", 409)
        if method == "GET":
            return {"ok": True, "character": self.controlled_view(db, character), "adventure": self.adventure_view(db, character)}
        require(method == "POST", "invalid_method", "Use GET or POST", 405)
        action = string(body.get("action"), 1, 32, "action")
        common = {"request_id", "expected_revision", "expected_wallet_revision", "action", "rules_hash"}
        extras = {"starter": {"species"}, "party": {"party"}, "heal": set(), "start": {"kind", "entry"},
                  "turn": {"battle_id", "expected_round", "command"}, "train": {"monster_id", "stat", "amount"},
                  "learn": {"monster_id", "move", "slot"}, "evolve": {"monster_id", "species"},
                  "breed": {"parents"}, "hatch": {"monster_id"}, "fuse": {"parents"}, "split": {"monster_id"},
                  "release": {"monster_id"}}
        require(action in extras, "invalid_adventure_action", "Unsupported adventure intent")
        obj(body, common | extras[action], common | extras[action])
        require(self.controlled_v1_action_allowed(db, character["id"], action), "original_migration_required", "New v1 gameplay is closed; migrate this server-owned character to the original game", 409)
        require(character["revision"] == integer(body["expected_revision"], 1, 2**53 - 1, "expected_revision"), "controlled_revision_conflict", "Character changed; refresh", 409)
        require(self.shop_wallet(db, character["id"], "GOLD")["revision"] == integer(body["expected_wallet_revision"], 0, 2**53 - 1, "expected_wallet_revision"), "wallet_version_conflict", "Wallet changed; refresh", 409)
        catalog = self.adventure_catalog()
        battle = self.adventure_active_battle(db, character["id"])
        expected_rules = battle["catalog_hash"] if action == "turn" and battle else catalog["hash"]
        require(body["rules_hash"] == expected_rules, "adventure_rules_changed", "Refresh the published rulebook", 409)
        require(action == "turn" or battle is None, "controlled_in_battle", "Finish or abandon the current battle first", 409)
        progress = self.adventure_progress(db, character["id"])
        reference = body["request_id"]
        result = {}
        if action == "starter":
            require(not progress["starter_claimed"], "starter_already_claimed", "Starter already granted", 409)
            require(body["species"] in catalog["starters"], "invalid_starter", "Choose a published starter")
            self.adventure_limit_storage(db, character["id"])
            monster = engine.make_monster(catalog, body["species"], 5)
            self.adventure_record_monster(db, character["id"], monster, "starter", reference, mint=True)
            progress.update(starter_claimed=True, party=[monster["id"]])
        elif action == "party":
            party = body["party"]
            require(type(party) is list and 1 <= len(party) <= 6 and all(type(key) is str for key in party) and len(set(party)) == len(party), "invalid_party", "Choose 1..6 distinct creatures")
            for identifier in party:
                require(not self.adventure_monster(db, character["id"], identifier)["egg"], "egg_in_party", "Hatch eggs first", 409)
            progress["party"] = party
        elif action == "heal":
            for row in db.execute("SELECT document FROM controlled_monsters WHERE character_id=? AND status='active'", (character["id"],)).fetchall():
                monster = json.loads(row[0])
                monster.update(hp=engine.stats(catalog, monster)["HP"], status="NONE", sleep=0)
                for move in monster["moves"]:
                    move["pp"] = catalog["moves"][move["id"]]["total_pp"]
                self.adventure_record_monster(db, character["id"], monster, "heal", reference)
        elif action == "start":
            result["started_battle"] = self.adventure_start(db, character, progress, catalog, body)
        elif action == "turn":
            require(battle is not None and battle["id"] == body["battle_id"], "controlled_battle_not_found", "Battle is no longer active", 409)
            self.adventure_turn(db, character, progress, battle, body)
            result["settled_battle"] = self.adventure_battle_view(db, battle)
        else:
            result.update(self.adventure_cultivate(db, character, progress, catalog, action, body))
        self.adventure_save_progress(db, character["id"], progress)
        db.execute("UPDATE controlled_characters SET revision=revision+1 WHERE id=?", (character["id"],))
        character = self.controlled_character(db, character["id"], identity["id"])
        return {"ok": True, "character": self.controlled_view(db, character), "adventure": self.adventure_view(db, character), **result}

    def adventure_start(self, db, character, progress, catalog, body):
        require(progress["starter_claimed"] and progress["party"], "starter_required", "Choose a starter and party first", 409)
        require(self.clock() - progress["last_started"] >= 1, "encounter_cooldown", "Wait before starting another encounter", 429)
        party = [self.adventure_monster(db, character["id"], key) for key in progress["party"]]
        require(any(monster["hp"] > 0 and not monster["egg"] for monster in party), "party_fainted", "Heal the party first", 409)
        kind = body["kind"]
        require(kind in ("wild", "trainer"), "invalid_encounter", "Choose wild or trainer")
        cap = catalog["stages"][min(progress["chapter"], len(catalog["stages"]) - 1)]["level_cap"]
        battle = {"id": "cb_" + secrets.token_hex(16), "character_id": character["id"], "kind": kind, "chapter": progress["chapter"],
            "round": 0, "status": "active", "outcome": None, "expires": self.clock() + 1800, "created": self.clock(),
            "random_key": secrets.token_hex(32), "random_counter": 0, "catalog_hash": catalog["hash"], "log": [], "result": {},
            "party": party, "player_active": next(index for index, monster in enumerate(party) if monster["hp"] > 0),
            "enemy_active": 0, "participants": [], "defeated": [], "level_cap": cap}
        rng = engine.BattleRandom(battle)
        if kind == "trainer":
            require(progress["chapter"] < len(catalog["stages"]), "campaign_complete", "All chapters completed", 409)
            stage = catalog["stages"][progress["chapter"]]
            require(body["entry"] == stage["id"], "chapter_locked", "Only the next chapter is available", 403)
            battle["enemies"] = [engine.make_monster(catalog, row["species"], row["level"], rng) for row in stage["party"]]
            battle["gold"] = stage["gold"]
        else:
            region = next((row for row in catalog["regions"] if row["id"] == body["entry"]), None)
            require(region is not None, "region_not_found", "Unknown region", 404)
            encounters = [row for row in region["encounters"] if row["min_level"] <= cap]
            require(encounters, "region_locked", "Progress through more chapters first", 403)
            roll = rng.randrange(sum(row["weight"] for row in encounters))
            for row in encounters:
                roll -= row["weight"]
                if roll < 0:
                    encounter = row
                    break
            level = encounter["min_level"] + rng.randrange(min(cap, encounter["max_level"]) - encounter["min_level"] + 1)
            battle["enemies"] = [engine.make_monster(catalog, encounter["species"], level, rng)]
            battle["gold"] = 0
        for monster in party + battle["enemies"]:
            monster["stages"] = {}
        usage = db.execute("SELECT count FROM controlled_encounter_usage WHERE owner=? AND day=?", (character["owner"], day_key(self.clock()))).fetchone()
        require((usage[0] if usage else 0) < catalog["daily_encounter_limit"], "daily_encounter_limit", "Account's daily encounter limit reached", 429)
        db.execute("INSERT INTO controlled_encounter_usage VALUES(?,?,1) ON CONFLICT(owner,day) DO UPDATE SET count=count+1", (character["owner"], day_key(self.clock())))
        db.execute("INSERT OR IGNORE INTO controlled_rulebooks VALUES(?,?)", (catalog["hash"], dumps(catalog)))
        self.adventure_save_battle(db, battle)
        progress["last_started"] = self.clock()
        return self.adventure_battle_view(db, battle)

    def adventure_defeated(self, catalog, battle, enemy):
        if enemy["id"] in battle["defeated"]:
            return
        battle["defeated"].append(enemy["id"])
        info = engine.species_info(catalog, enemy["species"])
        recipients = [monster for monster in battle["party"] if monster["id"] in battle["participants"] and monster["hp"] > 0]
        total = max(1, info["base_exp"] * enemy["level"] // 7)
        if battle["kind"] == "trainer":
            total = total * 3 // 2
        for monster in recipients:
            amount = max(1, total // len(recipients))
            engine.gain_exp(catalog, monster, amount, battle["level_cap"])
            for stat in engine.STATS:
                space = max(0, 510 - sum(monster["ev"].values()))
                monster["ev"][stat] = min(252, monster["ev"][stat] + min(space, info["evs"][stat]))
            battle["log"].append({"event": "experience", "id": monster["id"], "amount": amount, "level": monster["level"]})

    def adventure_end(self, db, character, progress, battle, outcome):
        require(battle["status"] == "active", "battle_already_settled", "Battle already settled", 409)
        battle.update(status="finished", outcome=outcome)
        reward = 0
        if outcome == "win" and battle["kind"] == "trainer":
            require(progress["chapter"] == battle["chapter"], "chapter_already_settled", "Chapter already settled", 409)
            reward = battle["gold"]
            self.shop_money(db, character["id"], "GOLD", reward, "managed:battle_reward:" + battle["id"])
            progress["chapter"] += 1
        if outcome == "loss":
            balance = self.shop_wallet(db, character["id"], "GOLD")["balance"]
            cost = min(balance, max(monster["level"] for monster in battle["party"]) * 10)
            if cost:
                self.shop_money(db, character["id"], "GOLD", -cost, "managed:battle_loss:" + battle["id"])
        battle["result"].update(outcome=outcome, gold=reward, chapter=progress["chapter"], settled_at=self.clock())

    def adventure_turn(self, db, character, progress, battle, body):
        require(battle["round"] == integer(body["expected_round"], 0, 100, "expected_round"), "battle_round_conflict", "Turn already changed; refresh", 409)
        catalog = self.adventure_battle_catalog(db, battle)
        command = obj(body["command"])
        kind = command.get("kind")
        fields = {"move": {"slot"}, "switch": {"monster_id"}, "item": {"item", "monster_id"}, "catch": {"item"}, "flee": set()}
        require(kind in fields, "invalid_battle_command", "Choose a move, switch, item, catch or flee")
        obj(command, fields[kind] | {"kind"}, fields[kind] | {"kind"})
        player = battle["party"][battle["player_active"]]
        enemy = battle["enemies"][battle["enemy_active"]]
        player_fainted = player["hp"] <= 0
        require(not player_fainted or kind in ("switch", "flee"), "replacement_required", "Replace the fainted creature", 409)
        rng = engine.BattleRandom(battle)
        battle["log"] = []
        for monster in battle["party"] + battle["enemies"]:
            monster["protect"], monster["flinch"] = False, False
        if player["id"] not in battle["participants"] and player["hp"] > 0:
            battle["participants"].append(player["id"])
        enemy_slot = engine.choose_enemy_move(catalog, enemy, player)
        enemy_attacks = not player_fainted
        if kind == "flee":
            self.adventure_end(db, character, progress, battle, "abandoned" if battle["kind"] == "trainer" else "escaped")
            enemy_attacks = False
        elif kind == "switch":
            index = next((index for index, monster in enumerate(battle["party"]) if monster["id"] == command["monster_id"]), None)
            require(index is not None and index != battle["player_active"] and battle["party"][index]["hp"] > 0, "invalid_replacement", "Choose another living party member", 409)
            player["stages"] = {}
            for key in ("confusion", "seeded", "toxic_count", "focus", "protect_chain"):
                player.pop(key, None)
            battle["player_active"] = index
            player = battle["party"][index]
            if player["id"] not in battle["participants"]:
                battle["participants"].append(player["id"])
            enemy_slot = engine.choose_enemy_move(catalog, enemy, player)
        elif kind == "item":
            require(command["item"] == "POTION", "battle_item_unavailable", "Only the published Potion effect is enabled")
            recipient = next((monster for monster in battle["party"] if monster["id"] == command["monster_id"]), None)
            require(recipient is not None and 0 < recipient["hp"] < engine.stats(catalog, recipient)["HP"], "potion_not_needed", "Choose an injured living party member", 409)
            self.controlled_item_change(db, character["id"], "POTION", -1, "managed:battle_item:" + battle["id"] + ":" + str(battle["round"]))
            recipient["hp"] = min(engine.stats(catalog, recipient)["HP"], recipient["hp"] + 20)
            battle["log"].append({"event": "potion", "id": recipient["id"], "hp": recipient["hp"]})
        elif kind == "catch":
            require(battle["kind"] == "wild", "trainer_capture_forbidden", "Trainer creatures cannot be captured", 403)
            require(command["item"] == "POKEBALL", "battle_item_unavailable", "Only Poke Ball is enabled")
            self.adventure_limit_storage(db, character["id"])
            self.controlled_item_change(db, character["id"], "POKEBALL", -1, "managed:catch:" + battle["id"] + ":" + str(battle["round"]))
            shakes = engine.catch_shakes(catalog, enemy, rng)
            battle["log"].append({"event": "capture", "shakes": shakes})
            if shakes == 4:
                captured = copy.deepcopy(enemy)
                captured["id"] = "cm_" + secrets.token_hex(16)
                captured["parents"] = []
                self.adventure_record_monster(db, character["id"], captured, "capture", battle["id"], mint=True)
                db.execute("INSERT INTO controlled_captures VALUES(?,?)", (battle["id"], captured["id"]))
                if len(progress["party"]) < 6:
                    progress["party"].append(captured["id"])
                self.adventure_defeated(catalog, battle, enemy)
                battle["result"]["captured_id"] = captured["id"]
                self.adventure_end(db, character, progress, battle, "captured")
                enemy_attacks = False
        else:
            slot = integer(command["slot"], -1, 3, "slot")
            if slot == -1:
                require(not any(move["pp"] > 0 for move in player["moves"]), "struggle_unavailable", "Use a remaining move", 409)
            else:
                require(slot < len(player["moves"]) and player["moves"][slot]["pp"] > 0, "move_unavailable", "Move has no PP or does not exist", 409)
            player_move = "STRUGGLE" if slot == -1 else player["moves"][slot]["id"]
            enemy_move = "STRUGGLE" if enemy_slot == -1 else enemy["moves"][enemy_slot]["id"]
            order = [(player, enemy, slot), (enemy, player, enemy_slot)]
            player_priority = catalog["moves"][player_move]["priority"]
            enemy_priority = catalog["moves"][enemy_move]["priority"]
            p_speed, e_speed = engine.boosted(catalog, player, "SPEED"), engine.boosted(catalog, enemy, "SPEED")
            if (enemy_priority, e_speed) > (player_priority, p_speed) or (enemy_priority, e_speed) == (player_priority, p_speed) and rng.randrange(2):
                order.reverse()
            for user, target, selected in order:
                if user["hp"] > 0 and target["hp"] > 0:
                    engine.attack(catalog, user, target, selected, rng, battle["log"])
            enemy_attacks = False
        if enemy_attacks and player["hp"] > 0 and enemy["hp"] > 0:
            engine.attack(catalog, enemy, player, enemy_slot, rng, battle["log"])
        if battle["status"] == "active":
            if not player_fainted:
                engine.finish_round(catalog, player, enemy, battle["log"])
            if enemy["hp"] <= 0:
                self.adventure_defeated(catalog, battle, enemy)
                next_enemy = next((index for index, monster in enumerate(battle["enemies"]) if monster["hp"] > 0), None)
                if next_enemy is None:
                    self.adventure_end(db, character, progress, battle, "win" if any(monster["hp"] > 0 for monster in battle["party"]) else "loss")
                else:
                    battle["enemy_active"] = next_enemy
            if battle["status"] == "active" and not any(monster["hp"] > 0 for monster in battle["party"]):
                self.adventure_end(db, character, progress, battle, "loss")
        battle["round"] += 1
        if battle["status"] == "active" and battle["round"] >= 100:
            self.adventure_end(db, character, progress, battle, "turn_limit")
        for monster in battle["party"]:
            self.adventure_record_monster(db, character["id"], monster, "battle", battle["id"] + ":" + str(battle["round"]))
        self.adventure_save_battle(db, battle)

    def adventure_cultivate(self, db, character, progress, catalog, action, body):
        reference = body["request_id"]
        cost = 0
        result = {}
        monster = self.adventure_monster(db, character["id"], body["monster_id"]) if "monster_id" in body else None
        if monster is not None:
            require(action == "hatch" or not monster["egg"], "egg_not_hatched", "Hatch the egg first", 409)
        if action == "train":
            require(body["stat"] in engine.STATS, "invalid_training_stat", "Choose a published stat")
            amount = integer(body["amount"], 1, 252, "amount")
            require(monster["ev"][body["stat"]] + amount <= 252 and sum(monster["ev"].values()) + amount <= 510, "ev_limit", "Training exceeds EV limits", 409)
            cost = amount * catalog["training_cost_per_ev"]
            monster["ev"][body["stat"]] += amount
            monster["hp"] = min(monster["hp"], engine.stats(catalog, monster)["HP"])
        elif action == "learn":
            require(body["move"] in engine.legal_moves(catalog, monster), "move_not_learnable", "Move is not in this creature's unlocked learnset", 403)
            require(body["move"] not in [move["id"] for move in monster["moves"]], "move_already_known", "Move already known", 409)
            slot = integer(body["slot"], 0, 3, "slot")
            require(slot <= len(monster["moves"]), "invalid_move_slot", "Choose an existing slot or the next free slot")
            entry = {"id": body["move"], "pp": catalog["moves"][body["move"]]["total_pp"]}
            if slot == len(monster["moves"]):
                monster["moves"].append(entry)
            else:
                monster["moves"][slot] = entry
            cost = catalog["relearn_cost"]
        elif action == "evolve":
            info = engine.species_info(catalog, monster["species"])
            evolution = next((entry for entry in info["evolutions"] if entry[0] == body["species"] and not entry[3]), None)
            require(evolution is not None and evolution[1] in ("Level", "Item"), "evolution_unavailable", "Choose a supported level or item evolution", 409)
            if evolution[1] == "Level":
                require(monster["level"] >= evolution[2], "evolution_level_required", "Required level not reached", 409)
            else:
                self.controlled_item_change(db, character["id"], evolution[2], -1, "managed:evolve:" + reference)
            old_max = engine.stats(catalog, monster)["HP"]
            old_growth = catalog["growth"][info["growth_rate"]]
            old_exp = monster["exp"]
            monster["species"] = body["species"]
            new_info = engine.species_info(catalog, monster["species"])
            if new_info["growth_rate"] != info["growth_rate"]:
                level = monster["level"]
                growth = catalog["growth"][new_info["growth_rate"]]
                span = old_growth[min(99, level)] - old_growth[level - 1]
                monster["exp"] = growth[level - 1] + (max(0, old_exp - old_growth[level - 1]) * (growth[min(99, level)] - growth[level - 1]) // span if span else 0)
            if monster["hp"] > 0:
                monster["hp"] = max(1, monster["hp"] + engine.stats(catalog, monster)["HP"] - old_max)
            cost = catalog["evolution_cost"]
        elif action in ("breed", "fuse"):
            identifiers = body["parents"]
            require(type(identifiers) is list and len(identifiers) == 2 and all(type(value) is str for value in identifiers) and len(set(identifiers)) == 2, "invalid_parents", "Choose two different owned creatures")
            parents = [self.adventure_monster(db, character["id"], identifier) for identifier in identifiers]
            require(all(not parent["egg"] and not parent.get("components") for parent in parents), "invalid_parents", "Parents must be hatched base creatures", 409)
            if action == "breed":
                self.adventure_limit_storage(db, character["id"])
                require(all(parent.get("breed_ready_at", 0) <= self.clock() for parent in parents), "breeding_cooldown", "Parents are resting", 409)
                infos = [engine.species_info(catalog, parent["species"]) for parent in parents]
                require(all("Undiscovered" not in info["egg_groups"] for info in infos), "breeding_incompatible", "This creature cannot breed", 409)
                ditto = [index for index, parent in enumerate(parents) if parent["species"] == "DITTO"]
                if ditto:
                    require(len(ditto) == 1, "breeding_incompatible", "Two Ditto cannot breed", 409)
                    mother = parents[1 - ditto[0]]
                else:
                    require(set(infos[0]["egg_groups"]) & set(infos[1]["egg_groups"]) and {parent["gender"] for parent in parents} == {"male", "female"}, "breeding_incompatible", "Compatible egg groups and opposite genders required", 409)
                    mother = next(parent for parent in parents if parent["gender"] == "female")
                species = mother["species"]
                # Follow trusted pre-evolution entries, never a client species.
                seen = set()
                while species not in seen:
                    seen.add(species)
                    info = engine.species_info(catalog, species)
                    previous = next((entry[0] for entry in info["evolutions"] if entry[3]), None)
                    if previous is None:
                        break
                    species = previous
                child = engine.make_monster(catalog, species, 1)
                child.update(egg=True, hatch_at=self.clock() + catalog["hatch_seconds"], parents=identifiers)
                inherited = secrets.SystemRandom().sample(list(engine.STATS), 3)
                for stat in inherited:
                    child["iv"][stat] = secrets.choice(parents)["iv"][stat]
                child["hp"] = engine.stats(catalog, child)["HP"]
                for parent in parents:
                    parent["breed_ready_at"] = child["hatch_at"]
                    self.adventure_record_monster(db, character["id"], parent, "breed_parent", reference)
                cost = catalog["breed_cost"]
            else:
                ids = [engine.species_info(catalog, parent["species"])["id_number"] for parent in parents]
                child = engine.make_monster(catalog, "B" + str(ids[0]) + "H" + str(ids[1]), max(parent["level"] for parent in parents))
                child["components"] = copy.deepcopy(parents)
                child["fusion_initial_exp"] = child["exp"]
                for stat in engine.STATS:
                    dominant = 1 if stat in ("HP", "SPECIAL_ATTACK", "SPECIAL_DEFENSE") else 0
                    child["iv"][stat] = parents[dominant]["iv"][stat]
                child["hp"] = engine.stats(catalog, child)["HP"]
                for parent in parents:
                    parent["consumed_by"] = child["id"]
                    self.adventure_record_monster(db, character["id"], parent, "fuse_parent", reference, status="consumed")
                progress["party"] = [identifier for identifier in progress["party"] if identifier not in identifiers]
                if len(progress["party"]) < 6:
                    progress["party"].append(child["id"])
                cost = catalog["fusion_cost"]
            self.adventure_record_monster(db, character["id"], child, action, reference, mint=True)
            result["monster_id"] = child["id"]
        elif action == "hatch":
            require(monster["egg"] and monster["hatch_at"] <= self.clock(), "egg_not_ready", "Egg is not ready to hatch", 409)
            monster["egg"] = False
        elif action == "split":
            require(len(monster.get("components", [])) == 2, "not_fused", "Creature is not a reversible fusion", 409)
            self.adventure_limit_storage(db, character["id"])
            earned = max(0, monster["exp"] - monster["fusion_initial_exp"])
            for index, parent in enumerate(monster["components"]):
                row = db.execute("SELECT character_id,status,document FROM controlled_monsters WHERE id=?", (parent["id"],)).fetchone()
                require(row is not None and row["character_id"] == character["id"] and row["status"] == "consumed" and json.loads(row["document"]).get("consumed_by") == monster["id"], "fusion_ownership_conflict", "A fusion component changed", 409)
                cap = catalog["stages"][min(progress["chapter"], len(catalog["stages"]) - 1)]["level_cap"]
                engine.gain_exp(catalog, parent, earned // 2 + (earned % 2 if index == 0 else 0), cap)
                self.adventure_record_monster(db, character["id"], parent, "split_parent", reference)
            self.adventure_record_monster(db, character["id"], monster, "split", reference, status="consumed")
            progress["party"] = [identifier for identifier in progress["party"] if identifier != monster["id"]]
            progress["party"] = (progress["party"] + [parent["id"] for parent in monster["components"]])[:6]
            cost = catalog["fusion_cost"]
            monster = None
        elif action == "release":
            count = db.execute("SELECT count(*) FROM controlled_monsters WHERE character_id=? AND status='active' AND coalesce(json_extract(document,'$.egg'),0)=0", (character["id"],)).fetchone()[0]
            require(count > 1 and not monster.get("components"), "cannot_release", "Keep one creature and split fused creatures before release", 409)
            self.adventure_record_monster(db, character["id"], monster, "release", reference, status="released")
            progress["party"] = [key for key in progress["party"] if key != monster["id"]]
            if not progress["party"]:
                row = db.execute("SELECT id FROM controlled_monsters WHERE character_id=? AND status='active' AND coalesce(json_extract(document,'$.egg'),0)=0 LIMIT 1", (character["id"],)).fetchone()
                progress["party"] = [row[0]]
            monster = None
        if monster is not None:
            self.adventure_record_monster(db, character["id"], monster, action, reference)
        if cost:
            self.shop_money(db, character["id"], "GOLD", -cost, "managed:" + action + ":" + character["id"] + ":" + reference)
        return result | {"cost": cost}
