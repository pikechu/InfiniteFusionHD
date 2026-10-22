"""HTTP/SQLite coordination. The room host runs the real Ruby battle engine.

The service validates envelopes, ownership and phase transitions; it does not
claim to validate Pokemon game mechanics or to provide trusted competitive play.
Only bounded JSON is accepted, never pickle/Marshal/eval or executable content.
"""
from __future__ import annotations

import argparse
import copy
from contextlib import contextmanager
import hashlib
import json
import logging
import math
import os
import re
import secrets
import socket
import sqlite3
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

PROTOCOL = 2
RULES = "friendly-singles-v1"
MAX_BODY = 512 * 1024
STATS = {"HP", "ATTACK", "DEFENSE", "SPECIAL_ATTACK", "SPECIAL_DEFENSE", "SPEED"}
APPEARANCE = set("head_shiny body_shiny debug_shiny natural_shiny fakeshiny shinyValue shinyR shinyG shinyB shinyKRS head_shinyhue body_shinyhue head_shinyr head_shinyg head_shinyb body_shinyr body_shinyg body_shinyb head_shinykrs body_shinykrs shinyimprovpif head_shinyimprovpif body_shinyimprovpif spriteform_head spriteform_body sprite_scale size_category head_gender head_nickname kuraygender".split())
COMPATIBILITY = {"protocol", "game_version", "data_hash", "mods_hash", "rules_version"}
MODES = {"friendly_singles", "coop_boss", "rental_singles"}
BOSS_ID = "training-golem"
POKEMON_FIELDS = {"version", "species", "level", "form", "name", "gender", "personal_id", "nature", "nature_for_stats", "iv_maxed", "hidden_power_type", "ability", "ability_index", "ability2", "ability2_index", "item", "moves", "iv", "ev", "happiness", "shiny", "appearance", "owner"}
LOG = logging.getLogger("multiplayer")


@contextmanager
def database_instance_lock(database):
    """Fence service/init processes before Store performs restart recovery.

    Keep the sidecar inode permanently: unlinking a locked file would let a new
    process lock a different inode. Store itself stays usable by isolated tests.
    """
    target = Path(database).resolve()
    target.parent.mkdir(parents=True, exist_ok=True)
    with open(str(target) + ".instance.lock", "a+b") as handle:
        if os.fstat(handle.fileno()).st_size == 0:
            handle.write(b"\0")
            handle.flush()
        handle.seek(0)
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            raise RuntimeError("Database is already in use by another multiplayer service or initializer: " + str(target)) from error
        try:
            yield
        finally:
            handle.seek(0)
            if os.name == "nt":
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


class APIError(Exception):
    def __init__(self, status, code, message, details=None):
        self.status, self.code, self.message, self.details = status, code, message, details
        super().__init__(message)

    def response(self):
        error = {"code": self.code, "message": self.message}
        if self.details is not None:
            error["details"] = self.details
        return {"ok": False, "error": error}


def require(condition, code, message, status=400, details=None):
    if not condition:
        raise APIError(status, code, message, details)


def obj(value, keys=None, required=()):
    require(type(value) is dict, "invalid_json", "Expected a JSON object")
    if keys is not None:
        require(not set(value) - set(keys), "unknown_field", "Unsupported JSON fields", details=sorted(set(value) - set(keys)))
    require(set(required) <= set(value), "missing_field", "Required fields missing", details=sorted(set(required) - set(value)))
    return value


def integer(value, low, high, name):
    require(type(value) is int and low <= value <= high, "invalid_field", "Invalid integer: " + name)
    return value


def string(value, low, high, name, pattern=None):
    require(type(value) is str and low <= len(value) <= high, "invalid_field", "Invalid string: " + name)
    require(not any(ord(c) < 32 for c in value), "invalid_field", "Control character: " + name)
    if pattern:
        require(re.fullmatch(pattern, value) is not None, "invalid_field", "Invalid format: " + name)
    return value


def symbol(value, name):
    return string(value, 1, 80, name, r"[A-Za-z0-9_.:-]+")


def boolean(value, name):
    require(type(value) is bool, "invalid_field", "Invalid boolean: " + name)
    return value


def dumps(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)


def digest(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def validate_compatibility(value):
    obj(value, COMPATIBILITY, COMPATIBILITY)
    require(value["protocol"] == PROTOCOL and type(value["protocol"]) is int, "protocol_mismatch", "Protocol version is incompatible", 409)
    for field in COMPATIBILITY - {"protocol"}:
        string(value[field], 1, 128, field)
    require(value["rules_version"] == RULES, "rules_mismatch", "Unsupported rules version", 409)
    return copy.deepcopy(value)


def validate_appearance(value):
    obj(value, APPEARANCE)
    for key, item in value.items():
        if item is None:
            continue
        if key in {"head_shiny", "body_shiny", "debug_shiny", "natural_shiny", "fakeshiny"}:
            boolean(item, key)
        elif key in {"shinyValue", "head_shinyhue", "body_shinyhue"}:
            integer(item, -360, 360, key)
        elif key in {"shinyR", "shinyG", "shinyB", "head_shinyr", "head_shinyg", "head_shinyb", "body_shinyr", "body_shinyg", "body_shinyb"}:
            integer(item, 0, 25, key)
        elif key in {"shinyKRS", "head_shinykrs", "body_shinykrs"}:
            require(type(item) is list and len(item) == 9, "invalid_appearance", "Color array requires nine integers")
            for index, number in enumerate(item):
                integer(number, -200 if index < 3 else 0, 200 if index < 3 else 4 if index < 6 else 2, key)
        elif key in {"shinyimprovpif", "head_shinyimprovpif", "body_shinyimprovpif"}:
            integer(item, 0, 3, key)
        elif key == "kuraygender":
            integer(item, 0, 65535, key)
        elif key == "head_gender":
            integer(item, 0, 2, key)
        elif key == "head_nickname":
            string(item, 0, 32, key)
            require("/" not in item and "\\" not in item, "invalid_appearance", "Appearance resource paths are unsupported")
        elif key == "sprite_scale":
            require(type(item) in (int, float) and math.isfinite(item) and 0.25 <= item <= 3, "invalid_appearance", "Invalid sprite scale")
        elif key == "size_category":
            require(type(item) is str and item in {"SMALL", "AVERAGE", "LARGE", "SUPER"}, "invalid_appearance", "Invalid size category")
        elif key in {"spriteform_head", "spriteform_body"}:
            require(type(item) is int and 0 <= item <= 999 or type(item) is str and re.fullmatch(r"[A-Za-z0-9_-]{1,12}", item) is not None, "invalid_appearance", "Invalid sprite variant")
        else:
            raise APIError(400, "invalid_appearance", "Unsupported appearance field value: " + key)
    return copy.deepcopy(value)


def validate_pokemon(value):
    obj(value, POKEMON_FIELDS, POKEMON_FIELDS)
    require(value["version"] == 1 and type(value["version"]) is int, "snapshot_version", "Unsupported Pokemon snapshot version", 409)
    symbol(value["species"], "species")
    integer(value["level"], 1, 100, "level")
    require(value["form"] == 0 and type(value["form"]) is int, "unsupported_form", "Only form 0 is supported by this battle adapter", 409)
    string(value["name"], 0, 32, "name")
    integer(value["gender"], 0, 2, "gender")
    integer(value["personal_id"], 0, 4294967295, "personal_id")
    symbol(value["nature"], "nature")
    for field in ("nature_for_stats", "hidden_power_type"):
        if value[field] is not None:
            symbol(value[field], field)
    obj(value["iv_maxed"], STATS, STATS)
    for stat in STATS:
        boolean(value["iv_maxed"][stat], "iv_maxed." + stat)
    symbol(value["ability"], "ability")
    integer(value["ability_index"], 0, 5, "ability_index")
    if value["ability2"] is not None:
        symbol(value["ability2"], "ability2")
    if value["ability2_index"] is not None:
        integer(value["ability2_index"], 0, 5, "ability2_index")
    if value["item"] is not None:
        symbol(value["item"], "item")
    moves = value["moves"]
    require(type(moves) is list and 1 <= len(moves) <= 4, "invalid_moves", "One to four moves required")
    for move in moves:
        obj(move, {"id", "pp", "ppup"}, {"id", "pp", "ppup"})
        symbol(move["id"], "move.id")
        integer(move["pp"], 0, 99, "move.pp")
        integer(move["ppup"], 0, 3, "move.ppup")
    for kind, maximum in (("iv", 31), ("ev", 252)):
        obj(value[kind], STATS, STATS)
        for stat in STATS:
            integer(value[kind][stat], 0, maximum, kind + "." + stat)
    require(sum(value["ev"].values()) <= 510, "invalid_ev", "EV total exceeds 510")
    integer(value["happiness"], 0, 255, "happiness")
    boolean(value["shiny"], "shiny")
    validate_appearance(value["appearance"])
    obj(value["owner"], {"id", "name", "gender", "language"}, {"id", "name", "gender", "language"})
    integer(value["owner"]["id"], 0, 4294967295, "owner.id")
    string(value["owner"]["name"], 0, 32, "owner.name")
    integer(value["owner"]["gender"], 0, 2, "owner.gender")
    integer(value["owner"]["language"], 0, 10, "owner.language")
    return copy.deepcopy(value)


def validate_trade_snapshot(value):
    """Full, versioned local-save exchange format; never a trusted asset."""
    obj(value, {"version", "pokemon", "preserved"}, {"version", "pokemon", "preserved"})
    require(type(value["version"]) is int and value["version"] == 1, "trade_snapshot_version", "Unsupported trade snapshot version", 409)
    validate_pokemon(value["pokemon"])
    ranges = {"exp": (0, 20000000), "hp": (0, 65535), "status_count": (0, 65535), "markings": (0, 65535), "obtain_method": (0, 4), "obtain_map": (0, 1000000), "hatched_map": (0, 1000000), "obtain_level": (1, 100), "kuray_no_evo": (0, 1), "hat_x": (-1000, 1000), "hat_y": (-1000, 1000)}
    for field in ("cool", "beauty", "cute", "smart", "tough", "sheen", "pokerus"):
        ranges[field] = (0, 255)
    nullable_ranges = {"time_form_set": (0, 4294967295), "time_received": (0, 4294967295), "time_egg_hatched": (0, 4294967295), "exp_when_fused_head": (0, 20000000), "exp_when_fused_body": (0, 20000000), "exp_gained_since_fused": (0, 20000000), "body_original_ability_index": (0, 5), "head_original_ability_index": (0, 5)}
    other = {"status", "poke_ball", "first_moves", "ribbons", "obtain_text", "veryunique", "glitter", "force_disobey", "imported", "type1kuray", "type2kuray", "sprite_asset", "old_sprite_asset"}
    fields = set(ranges) | set(nullable_ranges) | other
    preserved = obj(value["preserved"], fields, fields)
    for field, bounds in ranges.items():
        integer(preserved[field], *bounds, field)
    for field, bounds in nullable_ranges.items():
        if preserved[field] is not None:
            integer(preserved[field], *bounds, field)
    require(preserved["status"] in ("NONE", "SLEEP", "POISON", "BURN", "PARALYSIS", "FROZEN"), "invalid_trade_status", "Unsupported status")
    symbol(preserved["poke_ball"], "poke_ball")
    for field, maximum in (("first_moves", 256), ("ribbons", 128)):
        require(type(preserved[field]) is list and len(preserved[field]) <= maximum, "invalid_trade_field", "Invalid " + field)
        for entry in preserved[field]:
            symbol(entry, field)
    for field in ("glitter", "force_disobey"):
        if preserved[field] is not None:
            boolean(preserved[field], field)
    boolean(preserved["imported"], "imported")
    for field in ("type1kuray", "type2kuray"):
        if preserved[field] is not None:
            symbol(preserved[field], field)
    if preserved["obtain_text"] is not None:
        string(preserved["obtain_text"], 0, 256, "obtain_text")
    if preserved["veryunique"] is not None:
        string(preserved["veryunique"], 1, 80, "veryunique", r"[A-Za-z0-9_\-]+")
    for field in ("sprite_asset", "old_sprite_asset"):
        if preserved[field] is not None:
            string(preserved[field], 1, 40, field, r"default|base:[1-9][0-9]{0,2}[A-Za-z_-]{0,12}|fusion:[1-9][0-9]{0,2}\.[1-9][0-9]{0,2}[A-Za-z_-]{0,12}")
    return copy.deepcopy(value)


def validate_runtime_state(value, players, teams=None, previous=None, allowed_items=None):
    obj(value, players, players)
    if teams is not None and allowed_items is None:
        allowed_items = {pokemon["item"] for party in teams.values() for pokemon in party if pokemon["item"] is not None}
    for owner, party in value.items():
        require(type(party) is list and len(party) == 3, "invalid_team_state", "Three temporary party states are required")
        for index, state in enumerate(party):
            fields = {"hp", "totalhp", "status", "status_count", "pp", "total_pp", "item"}
            obj(state, fields, fields)
            integer(state["totalhp"], 1, 100000, "totalhp")
            integer(state["hp"], 0, state["totalhp"], "hp")
            integer(state["status_count"], 0, 65535, "status_count")
            require(state["status"] in ("NONE", "SLEEP", "POISON", "BURN", "PARALYSIS", "FROZEN"), "invalid_team_state", "Unsupported temporary status")
            require(type(state["pp"]) is list and type(state["total_pp"]) is list and 1 <= len(state["pp"]) == len(state["total_pp"]) <= 4, "invalid_team_state", "Invalid temporary move PP arrays")
            for pp, total in zip(state["pp"], state["total_pp"]):
                integer(total, 0, 999, "total_pp")
                integer(pp, 0, total, "pp")
            if state["item"] is not None:
                symbol(state["item"], "item")
            if teams is not None:
                require(len(state["pp"]) == len(teams[owner][index]["moves"]), "invalid_team_state", "Move PP state does not match the frozen team")
                # Trick/Thief/Harvest/Recycle legitimately move or recover a
                # frozen route item. We relay the host's resulting state rather
                # than treating each temporary Pokemon's original item as fixed.
                require(state["item"] is None or state["item"] in allowed_items, "invalid_team_state", "Temporary held item is outside the frozen participant/Boss item set")
    return copy.deepcopy(value)


def validate_visual_pokemon(value, slots):
    fields = {"slot", "species", "level", "name", "hp", "totalhp", "status", "party_index", "form", "gender", "shiny", "appearance"}
    obj(value, fields, fields)
    integer(value["slot"], 0, 3, "visual.slot")
    require(value["slot"] in slots, "invalid_visual_slot", "Visual event references a slot absent from the public battle state")
    symbol(value["species"], "visual.species")
    integer(value["level"], 1, 100, "visual.level")
    string(value["name"], 0, 32, "visual.name")
    integer(value["totalhp"], 1, 100000, "visual.totalhp")
    integer(value["hp"], 0, value["totalhp"], "visual.hp")
    if type(value["status"]) is str:
        symbol(value["status"], "visual.status")
    else:
        integer(value["status"], 0, 100, "visual.status")
    integer(value["party_index"], 0, 2, "visual.party_index")
    integer(value["form"], 0, 999, "visual.form")
    integer(value["gender"], 0, 2, "visual.gender")
    boolean(value["shiny"], "visual.shiny")
    validate_appearance(value["appearance"])


def validate_visuals(value, state):
    obj(value, {"version", "seq", "complete", "battlers", "events"}, {"version", "seq", "complete", "battlers", "events"})
    require(type(value["version"]) is int and value["version"] == 1, "visual_version", "Unsupported cosmetic event version", 409)
    integer(value["seq"], 1, 100000, "visual.seq")
    boolean(value["complete"], "visual.complete")
    slots = {battler["index"] for battler in state["battlers"]}
    require(type(value["battlers"]) is list and len(value["battlers"]) <= 4, "invalid_visuals", "At most four public visual battlers are supported")
    seen = set()
    for pokemon in value["battlers"]:
        validate_visual_pokemon(pokemon, slots)
        require(pokemon["slot"] not in seen, "invalid_visuals", "Duplicate visual battler slot")
        seen.add(pokemon["slot"])
    require(type(value["events"]) is list and len(value["events"]) <= 128, "invalid_visuals", "At most 128 cosmetic events are supported")
    for event in value["events"]:
        obj(event, required={"kind"})
        kind = event["kind"]
        if kind == "move":
            obj(event, {"kind", "move_id", "user", "targets", "hit"}, {"kind", "move_id", "user", "targets", "hit"})
            symbol(event["move_id"], "visual.move_id")
            integer(event["user"], 0, 3, "visual.user")
            require(event["user"] in slots, "invalid_visual_slot", "Move animation user is not in public state")
            integer(event["hit"], 0, 20, "visual.hit")
            require(type(event["targets"]) is list and len(event["targets"]) <= 4 and all(type(slot) is int and slot in slots for slot in event["targets"]) and len(set(event["targets"])) == len(event["targets"]), "invalid_visual_slot", "Invalid resolved animation targets")
        elif kind == "replace":
            obj(event, {"kind", "pokemon"}, {"kind", "pokemon"})
            validate_visual_pokemon(event["pokemon"], slots)
        elif kind == "hp":
            obj(event, {"kind", "slot", "from", "to", "totalhp"}, {"kind", "slot", "from", "to", "totalhp"})
            integer(event["totalhp"], 1, 100000, "visual.totalhp")
            integer(event["from"], 0, event["totalhp"], "visual.from")
            integer(event["to"], 0, event["totalhp"], "visual.to")
            integer(event["slot"], 0, 3, "visual.slot")
            require(event["slot"] in slots, "invalid_visual_slot", "HP event slot is not in public state")
        elif kind in ("recall", "faint"):
            obj(event, {"kind", "slot"}, {"kind", "slot"})
            integer(event["slot"], 0, 3, "visual.slot")
            require(event["slot"] in slots, "invalid_visual_slot", "Cosmetic slot is not in public state")
        else:
            raise APIError(400, "invalid_visual_event", "Unsupported cosmetic event kind")
    return copy.deepcopy(value)


def validate_state(value, players, mode="friendly_singles"):
    fields = {"kind", "battlers", "weather", "terrain", "events", "actions", "phase_owner_ids", "turn_count", "visuals"}
    if mode == "coop_boss":
        fields.add("team_states")
    obj(value, fields, {"kind", "battlers", "events", "actions", "phase_owner_ids"})
    if "team_states" in value:
        validate_runtime_state(value["team_states"], players)
    require(value["kind"] in ("command", "switch"), "invalid_state", "Unknown command phase kind")
    if "turn_count" in value:
        integer(value["turn_count"], 0, 10000, "turn_count")
    for field in ("weather", "terrain"):
        if field in value:
            require(type(value[field]) in (str, int), "invalid_state", "Invalid field: " + field)
            if type(value[field]) is str:
                symbol(value[field], field)
            else:
                integer(value[field], 0, 100000, field)
    battlers = value["battlers"]
    require(type(battlers) is list and len(battlers) <= 4, "invalid_state", "Too many battlers")
    for battler in battlers:
        obj(battler, {"owner_id", "index", "party_index", "species", "hp", "totalhp", "status", "name", "level"}, {"owner_id", "index", "species", "hp", "totalhp", "status"})
        require(battler["owner_id"] in players or mode == "coop_boss" and battler["owner_id"] == "boss", "invalid_state", "Unknown battler owner")
        integer(battler["index"], 0, 3, "battler.index")
        if "party_index" in battler:
            integer(battler["party_index"], 0, 2, "battler.party_index")
        symbol(battler["species"], "battler.species")
        integer(battler["totalhp"], 1, 100000, "battler.totalhp")
        integer(battler["hp"], 0, battler["totalhp"], "battler.hp")
        if type(battler["status"]) is str:
            symbol(battler["status"], "battler.status")
        else:
            integer(battler["status"], 0, 100, "battler.status")
        if "name" in battler:
            string(battler["name"], 0, 32, "battler.name")
        if "level" in battler:
            integer(battler["level"], 1, 100, "battler.level")
    require(type(value["events"]) is list and len(value["events"]) <= 256, "invalid_state", "Too many battle events")
    for event in value["events"]:
        string(event, 0, 2048, "event")
    owners = value["phase_owner_ids"]
    require(type(owners) is list and len(set(owners)) == len(owners) and set(owners) <= set(players), "invalid_state", "Invalid phase owners")
    obj(value["actions"], players)
    for owner, actions in value["actions"].items():
        obj(actions, {"moves", "switches", "can_switch", "forced"}, {"moves", "switches", "can_switch"})
        boolean(actions["can_switch"], "can_switch")
        if "forced" in actions:
            boolean(actions["forced"], "forced")
        require(type(actions["moves"]) is list and len(actions["moves"]) <= 4, "invalid_state", "Invalid move options")
        for move in actions["moves"]:
            obj(move, {"index", "id", "name", "pp", "total_pp", "target", "targets"}, {"index", "id", "name", "pp", "total_pp"})
            integer(move["index"], -1, 3, "move.index")
            symbol(move["id"], "move.id")
            string(move["name"], 1, 80, "move.name")
            integer(move["pp"], 0, 999, "move.pp")
            integer(move["total_pp"], 0, 999, "move.total_pp")
            if "target" in move:
                integer(move["target"], -1, 3, "move.target")
            if "targets" in move:
                require(type(move["targets"]) is list and 1 <= len(move["targets"]) <= 5 and all(type(target) is int and -1 <= target <= 3 for target in move["targets"]) and len(set(move["targets"])) == len(move["targets"]), "invalid_state", "Invalid legal target list")
        require(type(actions["switches"]) is list and len(actions["switches"]) <= 3, "invalid_state", "Invalid switch options")
        for switch in actions["switches"]:
            obj(switch, {"party_index", "species", "hp", "totalhp", "name"}, {"party_index", "species", "hp", "totalhp"})
            integer(switch["party_index"], 0, 2, "switch.party_index")
            symbol(switch["species"], "switch.species")
            integer(switch["totalhp"], 1, 100000, "switch.totalhp")
            integer(switch["hp"], 0, switch["totalhp"], "switch.hp")
            if "name" in switch:
                string(switch["name"], 0, 32, "switch.name")
    if "visuals" in value:
        validate_visuals(value["visuals"], value)
    return copy.deepcopy(value)


try:
    from .backend_v3 import V3Features, bind_api
except ImportError:
    from backend_v3 import V3Features, bind_api
bind_api(globals())
try:
    from .online import OnlineFeatures, bind_api as bind_online_api, MAX_CLOUD_BODY
except ImportError:
    from online import OnlineFeatures, bind_api as bind_online_api, MAX_CLOUD_BODY
bind_online_api(globals())


try:
    from .economy import EconomyFeatures, bind_api as bind_economy_api
    from .trading import TradingFeatures, bind_api as bind_trading_api
except ImportError:
    from economy import EconomyFeatures, bind_api as bind_economy_api
    from trading import TradingFeatures, bind_api as bind_trading_api
bind_economy_api(globals())
bind_trading_api(globals())


class Store(V3Features, OnlineFeatures, EconomyFeatures, TradingFeatures):
    def __init__(self, database, clock=time.time, heartbeat_seconds=8, reconnect_seconds=60, room_ttl=86400,
                 synchronous="NORMAL", create=True, auth_concurrency=2):
        if synchronous not in ("NORMAL", "FULL"):
            raise ValueError("Unsupported SQLite synchronous mode")
        if not isinstance(auth_concurrency, int) or not 1 <= auth_concurrency <= 4:
            raise ValueError("Authentication concurrency must be 1..4")
        self.database = str(database)
        self.clock = clock
        self.heartbeat_seconds = heartbeat_seconds
        self.reconnect_seconds = reconnect_seconds
        self.room_ttl = room_ttl
        self.lock = threading.RLock()
        self.auth_lock = threading.Lock()
        self.auth_slots = threading.BoundedSemaphore(auth_concurrency)
        if create:
            Path(self.database).parent.mkdir(parents=True, exist_ok=True)
        target = self.database if create else Path(self.database).resolve().as_uri() + "?mode=rw"
        self._db = sqlite3.connect(target, uri=not create, timeout=10, check_same_thread=False)
        self._db.row_factory = sqlite3.Row
        with self.connect() as db:
            db.execute("PRAGMA synchronous=" + synchronous)
            db.executescript("""
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS identities(id TEXT PRIMARY KEY,nickname TEXT NOT NULL,friend_code TEXT UNIQUE NOT NULL,token_hash TEXT UNIQUE NOT NULL,recovery_hash TEXT UNIQUE NOT NULL,created REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS rooms(code TEXT PRIMARY KEY,document TEXT NOT NULL,updated REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS battles(id TEXT PRIMARY KEY,document TEXT NOT NULL,updated REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS operations(owner TEXT NOT NULL,request_id TEXT NOT NULL,fingerprint TEXT NOT NULL,status INTEGER NOT NULL,response TEXT NOT NULL,created REAL NOT NULL,PRIMARY KEY(owner,request_id));
                CREATE TABLE IF NOT EXISTS showcases(code TEXT PRIMARY KEY,owner TEXT NOT NULL,document TEXT NOT NULL,active INTEGER NOT NULL,version INTEGER NOT NULL,updated REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS gyms(code TEXT PRIMARY KEY,owner TEXT NOT NULL,document TEXT NOT NULL,updated REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS gym_versions(code TEXT NOT NULL,version INTEGER NOT NULL,document TEXT NOT NULL,PRIMARY KEY(code,version));
                CREATE TABLE IF NOT EXISTS gym_challenges(id TEXT PRIMARY KEY,owner TEXT NOT NULL,document TEXT NOT NULL,updated REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS gym_favorites(owner TEXT NOT NULL,code TEXT NOT NULL,PRIMARY KEY(owner,code));
                CREATE TABLE IF NOT EXISTS rewards(owner TEXT NOT NULL,scope TEXT NOT NULL,document TEXT NOT NULL,PRIMARY KEY(owner,scope));
                CREATE TABLE IF NOT EXISTS trades(code TEXT PRIMARY KEY,document TEXT NOT NULL,updated REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS trade_receipts(transaction_id TEXT NOT NULL,owner TEXT NOT NULL,document TEXT NOT NULL,acked INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(transaction_id,owner));
            """)
            self.init_v3(db)
            self.init_online(db)
            self.init_trading(db)
            # Protocol-1 waiting rooms have no engine-instance handshake. They
            # remain readable history, but cannot be reopened by a v2 client.
            for row in db.execute("SELECT document FROM rooms").fetchall():
                room = json.loads(row["document"])
                if room.get("compatibility", {}).get("protocol") != PROTOCOL and room["status"] != "closed":
                    room["status"] = "closed"
                    if room.get("draft", {}).get("status") == "picking":
                        room["draft"].update({"status": "cancelled", "next_owner_id": None, "deadline": None, "reason": "protocol_mismatch"})
                    self.save_room(db, room)
            # An unfinished old route cannot launch another engine in a closed
            # incompatible room. Retain its frozen teams/history, release its
            # activity binding, and never infer a victory or mint a reward.
            for row in db.execute("SELECT document FROM dungeons").fetchall():
                route = json.loads(row["document"])
                if route["status"] in ("completed", "failed", "abandoned", "expired"):
                    continue
                room_row = db.execute("SELECT document FROM rooms WHERE code=?", (route["room_code"],)).fetchone()
                if room_row and json.loads(room_row["document"]).get("compatibility", {}).get("protocol") != PROTOCOL:
                    route.update({"status": "abandoned", "reason": "protocol_mismatch", "readies": []})
                    self.save_dungeon(db, route)
            # Engine call stacks cannot be reconstructed from JSON. Never accept
            # a host's unconfirmed local victory after service restart.
            for row in db.execute("SELECT id,document FROM battles").fetchall():
                battle = json.loads(row["document"])
                if battle["status"] == "active":
                    self.finish(db, battle, None, "service_restart", abnormal=True)

    @contextmanager
    def connect(self):
        # One guarded connection keeps WAL open instead of expensive Windows
        # close/checkpoint/reopen on every polling request.
        with self.lock, self._db:
            yield self._db

    def close(self):
        with self.lock:
            self._db.close()

    def save_room(self, db, room):
        room["updated_at"] = self.clock()
        db.execute("INSERT OR REPLACE INTO rooms VALUES(?,?,?)", (room["code"], dumps(room), self.clock()))

    def save_battle(self, db, battle):
        db.execute("INSERT OR REPLACE INTO battles VALUES(?,?,?)", (battle["id"], dumps(battle), self.clock()))

    def room(self, db, code):
        row = db.execute("SELECT document FROM rooms WHERE code=?", (code.upper(),)).fetchone()
        require(row is not None, "room_not_found", "Room does not exist", 404)
        room = json.loads(row["document"])
        if room["status"] != "closed" and room["status"] != "playing" and self.clock() - room["updated_at"] > self.room_ttl:
            room["status"] = "closed"
            self.save_room(db, room)
        return room

    def battle(self, db, battle_id):
        row = db.execute("SELECT document FROM battles WHERE id=?", (battle_id,)).fetchone()
        require(row is not None, "battle_not_found", "Battle does not exist", 404)
        return json.loads(row["document"])

    def member(self, room, owner):
        require(owner in room["members"], "not_member", "Identity is not a member of this room", 403)
        return room["members"][owner]

    def room_view(self, room):
        # Never include selected indexes, team ordering, moves, credentials,
        # compatibility documents or private IV/EV values in room responses.
        mode = room.get("mode", "friendly_singles")
        view = {"code": room["code"], "name": room["name"], "host_id": room["host_id"], "status": room["status"], "revision": room["revision"], "battle_id": room.get("battle_id"), "mode": mode, "rules": {"id": RULES, "level": 50, "team_size": 3, "bag_items": False}, "members": [{"id": key, "nickname": member["nickname"], "ready": member["ready"], "candidates": [{"species": pokemon["species"]} for pokemon in member["candidates"]], "selected_count": len(member["selected"])} for key, member in room["members"].items()]}
        if mode == "coop_boss":
            view["boss"] = copy.deepcopy(room["boss"])
            # Cooperative teammates explicitly share their complete entries.
            for member in view["members"]:
                original = room["members"][member["id"]]
                member["team"] = [copy.deepcopy(original["candidates"][index]) for index in original["selected"]]
        if room.get("draft"):
            view["draft"] = copy.deepcopy(room["draft"])
        return view

    def public_state(self, state, owner, host):
        state = copy.deepcopy(state)
        if owner != host:
            state["actions"] = {key: value for key, value in state.get("actions", {}).items() if key == owner}
        return state

    def battle_view(self, battle, owner):
        require(owner in battle["players"], "not_participant", "Identity is not a participant", 403)
        host = battle["host_id"]
        result = {key: copy.deepcopy(battle.get(key)) for key in ("id", "room_code", "host_id", "players", "status", "turn", "phase", "deadline", "result")}
        result["battle_id"] = battle["id"]
        result["mode"] = battle.get("mode", "friendly_singles")
        for key in ("dungeon_id", "node_index", "runtime_state", "draft_id"):
            if key in battle:
                result[key] = copy.deepcopy(battle[key])
        if result["mode"] == "coop_boss":
            result["boss"] = copy.deepcopy(battle["boss"])
            result["ai_controlled_ids"] = list(battle.get("ai_controlled_ids", []))
            result["control_restore_pending_ids"] = list(battle.get("control_restore_pending_ids", []))
            result["signals"] = copy.deepcopy(battle.get("signals", {}))
        result["submitted"] = list(battle["commands"])
        result["team"] = copy.deepcopy(battle["initial_teams"][owner])
        result["snapshot"] = self.public_state(battle.get("state", {}), owner, host)
        result["state"] = result["snapshot"]
        result["updates"] = [{**{key: copy.deepcopy(value) for key, value in update.items() if key != "state"}, "state": self.public_state(update["state"], owner, host)} for update in battle["updates"][-4:]]
        if owner != host:
            for update in result["updates"]:
                update.pop("random_tape", None)
        result["reconnect_remaining"] = {key: max(0, round(value["remaining"], 1)) for key, value in battle["presence"].items()}
        result["disconnected"] = [key for key, value in battle["presence"].items() if value["disconnected"]]
        if owner == host or result["mode"] == "coop_boss":
            result["initial_teams"] = copy.deepcopy(battle["initial_teams"])
        if owner == host:
            if battle["phase"] == "locked":
                result["commands"] = copy.deepcopy(battle["commands"])
        return result

    def finish(self, db, battle, winner, reason, abnormal=False):
        if battle["status"] != "active":
            return
        battle["status"] = "abnormal" if abnormal else "finished"
        battle["phase"] = "finished"
        battle["deadline"] = None
        battle["result"] = {"id": "result_" + battle["id"], "winner_id": winner, "reason": reason, "turns": battle.get("state", {}).get("turn_count", -1) + 1, "phases": battle["turn"], "abnormal": abnormal, "rewards": [], "settled_at": self.clock()}
        if battle.get("mode") == "coop_boss":
            battle["result"]["outcome"] = "abnormal" if abnormal else "win" if winner == battle["host_id"] else "loss"
            battle["result"]["winning_player_ids"] = list(battle["players"]) if winner == battle["host_id"] and not abnormal else []
            battle["result"]["winner_ids"] = battle["result"]["winning_player_ids"]
            battle["result"]["coop_outcome"] = "abnormal" if abnormal else "victory" if winner == battle["host_id"] else "defeat"
            if "team_states" in battle.get("state", {}):
                battle["result"]["team_states"] = copy.deepcopy(battle["state"]["team_states"])
        self.save_battle(db, battle)
        room = self.room(db, battle["room_code"])
        if room["status"] != "closed":
            room["status"] = "settled"
            for member in room["members"].values():
                member["ready"] = False
            room["revision"] += 1
            self.save_room(db, room)

    def advance(self, battle):
        battle["turn"] += 1
        battle["phase"] = "commands"
        owners = battle["state"].get("phase_owner_ids", battle["players"])
        battle["commands"] = {owner: {"action": "wait"} for owner in battle["players"] if owner not in owners}
        if battle.get("mode") == "coop_boss":
            # Returning players recover control only at a new phase boundary.
            for owner in battle.get("control_restore_pending_ids", []):
                presence = battle["presence"][owner]
                if owner in battle.get("ai_controlled_ids", []) and not presence["disconnected"] and self.clock() <= presence["last_seen"] + self.heartbeat_seconds:
                    battle["ai_controlled_ids"].remove(owner)
            battle["control_restore_pending_ids"] = []
            for owner in battle.get("ai_controlled_ids", []):
                battle["commands"].setdefault(owner, {"action": "ai"})
        battle["acks"] = []
        battle["deadline"] = self.clock() + (30 if battle["state"].get("kind") == "switch" else 60)
        if len(battle["commands"]) == 2:
            battle["phase"] = "locked"
            battle["deadline"] = None

    def tick(self, db, battle, owner=None):
        if battle["status"] != "active":
            return
        if battle.get("dungeon_id"):
            row = db.execute("SELECT document FROM dungeons WHERE id=?", (battle["dungeon_id"],)).fetchone()
            if row:
                dungeon = json.loads(row["document"])
                self.expire_dungeon(db, dungeon)
                if dungeon["status"] == "expired":
                    fresh = self.battle(db, battle["id"])
                    battle.clear()
                    battle.update(fresh)
                    return
        now = self.clock()
        had_disconnect = False
        paused_seconds = 0
        exhausted = []
        for participant, presence in battle["presence"].items():
            last_seen = battle.get("authority_last_seen", presence["last_seen"]) if participant == battle["host_id"] else presence["last_seen"]
            absence_start = last_seen + self.heartbeat_seconds
            missing = now > absence_start
            if missing:
                # An exhausted non-host in coop remains under AI; it no longer
                # pauses the host's game or consumes another reconnect budget.
                ai_active = battle.get("mode") == "coop_boss" and participant in battle.get("ai_controlled_ids", [])
                had_disconnect = had_disconnect or not ai_active
                loss = max(0, now - max(battle["last_tick"], absence_start))
                if not ai_active:
                    # Once a cooperative guest exhausts its allowance, the AI
                    # no longer pauses this phase. A late poll cannot add the
                    # entire overdue interval after that takeover boundary.
                    paused_seconds = max(paused_seconds, min(loss, presence["remaining"]))
                presence["remaining"] = max(0, presence["remaining"] - loss)
                presence["disconnected"] = True
                if presence["remaining"] <= 0:
                    exhausted.append(participant)
            if participant == owner:
                presence["last_seen"] = now
                presence["disconnected"] = False
                if participant == battle["host_id"]:
                    battle["authority_last_seen"] = now
                if participant in battle.get("ai_controlled_ids", []) and participant not in battle.setdefault("control_restore_pending_ids", []):
                    battle["control_restore_pending_ids"].append(participant)
        battle["last_tick"] = now
        if exhausted and battle.get("mode") == "coop_boss" and battle["host_id"] not in exhausted:
            for participant in exhausted:
                if participant not in battle.setdefault("ai_controlled_ids", []):
                    battle["ai_controlled_ids"].append(participant)
                if battle["phase"] == "commands":
                    battle["commands"].setdefault(participant, {"action": "ai"})
            if battle["phase"] == "commands" and len(battle["commands"]) == 2:
                battle["phase"], battle["deadline"] = "locked", None
            exhausted = []
        if exhausted:
            if len(exhausted) == 2:
                self.finish(db, battle, None, "both_disconnected", abnormal=True)
            elif battle["host_id"] in exhausted:
                self.finish(db, battle, None, "host_disconnected", abnormal=True)
            else:
                winner = next(key for key in battle["players"] if key not in exhausted)
                self.finish(db, battle, winner, "disconnect_timeout")
            return
        phase_before_auto_ack = (battle["turn"], battle["phase"])
        if battle.get("mode") == "coop_boss" and battle["phase"] == "playback":
            battle["acks"] = list(set(battle["acks"]) | set(battle.get("ai_controlled_ids", [])))
            if len(battle["acks"]) == 2:
                self.advance(battle)
        if had_disconnect and battle["deadline"] is not None and (battle["turn"], battle["phase"]) == phase_before_auto_ack:
            battle["deadline"] += paused_seconds
        still_disconnected = any(p["disconnected"] for key, p in battle["presence"].items() if key not in battle.get("ai_controlled_ids", []))
        if not still_disconnected and battle["phase"] == "commands" and battle["deadline"] is not None and now >= battle["deadline"]:
            for participant in battle["players"]:
                if participant in battle["commands"]:
                    continue
                battle["timeouts"][participant] += 1
                if battle["timeouts"][participant] >= 3 and battle.get("mode") != "coop_boss":
                    winner = next(key for key in battle["players"] if key != participant)
                    self.finish(db, battle, winner, "three_action_timeouts")
                    return
                actions = battle["state"].get("actions", {}).get(participant, {})
                moves = [move for move in actions.get("moves", []) if (move["pp"] > 0 or move["index"] == -1) and move.get("targets", [-1])]
                switches = actions.get("switches", [])
                if battle.get("mode") == "coop_boss":
                    command = {"action": "ai"}
                elif battle["state"].get("kind") == "switch" and switches:
                    command = {"action": "switch", "party_index": switches[0]["party_index"]}
                elif moves:
                    command = {"action": "move", "move_index": moves[0]["index"], "target": moves[0]["targets"][0] if "targets" in moves[0] else moves[0].get("target", 1 if participant == battle["host_id"] else 0)}
                else:
                    command = {"action": "forced"}
                battle["commands"][participant] = command
            battle["phase"] = "locked"
            battle["deadline"] = None
        self.save_battle(db, battle)

    def request(self, method, path, body=None, token=None, peer="local"):
        body = {} if body is None else body
        try:
            obj(body)
            limit = MAX_CLOUD_BODY if path == "/v1/cloud/upload" else MAX_BODY
            require(len(dumps(body).encode("utf-8")) <= limit, "body_too_large", "Request exceeds maximum size", 413)
            if method == "POST" and path in ("/v1/auth/register", "/v1/auth/login"):
                return self.auth_request(path, body, peer)
            with self.lock, self.connect() as db:
                db.execute("BEGIN IMMEDIATE")
                if method == "GET" and path == "/v1/health":
                    return 200, {"ok": True, "protocol": PROTOCOL, "rules_version": RULES, "service": "kuray-multiplayer", "server_time": self.clock()}
                if method == "POST" and path == "/v1/identities":
                    return self.create_identity(db, body)
                if method == "POST" and path == "/v1/identities/recover":
                    return self.recover_identity(db, body)
                row = db.execute("SELECT id,nickname,friend_code FROM identities WHERE token_hash=?", (digest(token or ""),)).fetchone()
                identity = dict(row) if row else self.account_identity(db, token)
                require(identity is not None, "identity_invalid", "Missing or invalid identity token", 401)
                owner = identity["id"]
                if method == "POST" and path == "/v1/auth/logout":
                    obj(body)
                    db.execute("DELETE FROM account_sessions WHERE token_hash=?", (digest(token or ""),))
                    return 200, {"ok": True}
                if method == "GET" and path == "/v1/identity":
                    return 200, {"ok": True, "identity": identity}
                if method == "GET" and path.startswith("/v1/operations/"):
                    request_id = string(path.rsplit("/", 1)[1], 8, 100, "request_id", r"[A-Za-z0-9_\-]+")
                    operation = db.execute("SELECT status,response FROM operations WHERE owner=? AND request_id=?", (owner, request_id)).fetchone()
                    require(operation is not None, "operation_not_found", "No committed operation with this request ID", 404)
                    return 200, {"ok": True, "status": "completed", "http_status": operation["status"], "response": json.loads(operation["response"])}
                # Replay downloads recheck publication/consent on EVERY read;
                # an operation-cache response must not bypass later unpublish.
                transient_heartbeat = path.startswith("/v1/battles/") and path.endswith("/heartbeat") and len(path.strip("/").split("/")) == 4
                transient_online = path.startswith(("/v1/cloud/", "/v1/world/", "/v1/chat/"))
                mutation = method == "POST" and path != "/v1/market/search" and not transient_online and not transient_heartbeat and not (path.startswith("/v1/replays/") and path.endswith("/download"))
                fingerprint = None
                if mutation:
                    request_id = string(body.get("request_id"), 8, 100, "request_id", r"[A-Za-z0-9_\-]+")
                    fingerprint = digest(dumps({"method": method, "path": path, "body": body}))
                    old = db.execute("SELECT * FROM operations WHERE owner=? AND request_id=?", (owner, request_id)).fetchone()
                    if old:
                        require(old["fingerprint"] == fingerprint, "request_id_conflict", "Request ID was already used with a different operation", 409)
                        return old["status"], json.loads(old["response"])
                status, response = self.dispatch(db, identity, method, path, body)
                if mutation:
                    db.execute("INSERT INTO operations VALUES(?,?,?,?,?,?)", (owner, request_id, fingerprint, status, dumps(response), self.clock()))
                return status, response
        except APIError as error:
            return error.status, error.response()
        except (ValueError, TypeError, RecursionError) as error:
            LOG.warning("Rejected malformed JSON structure (%s)", type(error).__name__)
            return 400, {"ok": False, "error": {"code": "invalid_json", "message": "Malformed JSON structure"}}

    def create_identity(self, db, body):
        obj(body, {"nickname", "protocol", "request_id"}, {"nickname", "protocol"})
        require(body["protocol"] == PROTOCOL and type(body["protocol"]) is int, "protocol_mismatch", "Protocol version is incompatible", 409)
        nickname = string(body["nickname"], 1, 32, "nickname")
        token, recovery = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        identity = {"id": "p_" + secrets.token_hex(12), "nickname": nickname, "friend_code": secrets.token_hex(4).upper()}
        db.execute("INSERT INTO identities VALUES(?,?,?,?,?,?)", (identity["id"], nickname, identity["friend_code"], digest(token), digest(recovery), self.clock()))
        return 201, {"ok": True, "identity": identity, "token": token, "recovery_code": recovery}

    def recover_identity(self, db, body):
        obj(body, {"recovery_code", "protocol", "expected_identity_id"}, {"recovery_code", "protocol"})
        string(body["recovery_code"], 20, 100, "recovery_code")
        require(body["protocol"] == PROTOCOL and type(body["protocol"]) is int, "protocol_mismatch", "Protocol version is incompatible", 409)
        row = db.execute("SELECT id,nickname,friend_code FROM identities WHERE recovery_hash=?", (digest(body["recovery_code"]),)).fetchone()
        require(row is not None, "recovery_invalid", "Recovery code is invalid", 401)
        if "expected_identity_id" in body:
            string(body["expected_identity_id"], 1, 80, "expected_identity_id")
            require(body["expected_identity_id"] == row["id"], "identity_switch_pending", "Resolve pending operations before switching identity", 409)
        token = secrets.token_urlsafe(32)
        db.execute("UPDATE identities SET token_hash=? WHERE id=?", (digest(token), row["id"]))
        return 200, {"ok": True, "identity": dict(row), "token": token, "recovery_code": body["recovery_code"]}

    def dispatch(self, db, identity, method, path, body, internal_route_id=None):
        owner = identity["id"]
        parts = path.strip("/").split("/")
        trading = self.dispatch_trading(db, identity, method, parts, body)
        if trading is not None:
            return trading
        online = self.dispatch_online(db, identity, method, parts, body)
        if online is not None:
            return online
        v3 = self.dispatch_v3(db, identity, method, parts, body)
        if v3 is not None:
            return v3
        if method == "GET" and path == "/v1/rooms":
            rooms = []
            for row in db.execute("SELECT code,document FROM rooms ORDER BY updated DESC").fetchall():
                if owner not in json.loads(row["document"])["members"]:
                    continue
                room = self.room(db, row["code"])
                if room.get("draft", {}).get("status") == "picking":
                    self.tick_draft(db, room, owner)
                if room["status"] != "closed":
                    rooms.append(self.room_view(room))
                if len(rooms) == 100:
                    break
            return 200, {"ok": True, "rooms": rooms}
        if method == "POST" and path == "/v1/rooms":
            obj(body, {"request_id", "name", "compatibility", "mode", "boss_id", "difficulty"}, {"request_id", "name", "compatibility"})
            compatibility = validate_compatibility(body["compatibility"])
            name = string(body["name"], 1, 48, "name")
            code = secrets.token_hex(3).upper()
            while db.execute("SELECT 1 FROM rooms WHERE code=?", (code,)).fetchone():
                code = secrets.token_hex(3).upper()
            room = {"code": code, "name": name, "host_id": owner, "compatibility": compatibility, "status": "waiting", "revision": 1, "battle_id": None, "members": {owner: {"nickname": identity["nickname"], "ready": False, "candidates": [], "selected": []}}}
            self.configure_mode(room, body)
            self.save_room(db, room)
            return 201, {"ok": True, "room": self.room_view(room)}
        if len(parts) >= 3 and parts[:2] == ["v1", "rooms"]:
            room = self.room(db, parts[2])
            if room.get("draft", {}).get("status") == "picking":
                self.tick_draft(db, room, owner)
            action = parts[3] if len(parts) == 4 else None
            if method == "POST" and action in ("configure", "team", "ready", "start", "kick", "leave"):
                self.member(room, owner)
                route = self.active_route_for_room(db, room["code"])
                require(route is None or action == "start" and internal_route_id == route["id"], "route_bound", "This room is bound to an active route; use its node readiness or two-player abandonment", 409)
                room = self.room(db, parts[2])  # A timer check may have closed a route battle.
            if method == "GET" and len(parts) == 3:
                self.member(room, owner)
                return 200, {"ok": True, "room": self.room_view(room)}
            require(method == "POST" and action is not None, "not_found", "Unknown room operation", 404)
            require(room.get("draft", {}).get("status") != "picking" or action == "leave", "draft_frozen", "Room configuration is frozen during the rental draft", 409)
            require(room["status"] != "closed", "room_closed", "Room is closed", 409)
            if action == "join":
                obj(body, {"request_id", "compatibility"}, {"request_id", "compatibility"})
                compatibility = validate_compatibility(body["compatibility"])
                differences = [key for key in COMPATIBILITY if compatibility[key] != room["compatibility"][key]]
                require(not differences, "compatibility_mismatch", "Game, data, mods or rules do not match", 409, differences)
                if owner in room["members"]:
                    return 200, {"ok": True, "room": self.room_view(room)}
                require(room["status"] != "playing", "room_playing", "Room is already playing", 409)
                require(len(room["members"]) < 2, "room_full", "Room already has two members", 409)
                room["members"][owner] = {"nickname": identity["nickname"], "ready": False, "candidates": [], "selected": []}
                room["status"] = "configuring"
            else:
                member = self.member(room, owner)
                if action == "start" and room["status"] == "playing":
                    obj(body, {"request_id"}, {"request_id"})
                    require(owner == room["host_id"], "host_only", "Only the host may start", 403)
                    return 200, {"ok": True, "room": self.room_view(room), "battle_id": room["battle_id"]}
                require(room["status"] != "playing", "room_playing", "Room configuration is frozen during battle", 409)
                if action == "team":
                    require(room.get("mode") != "rental_singles", "rental_team_frozen", "Rental teams can only come from the server draft", 409)
                    obj(body, {"request_id", "candidates", "selected"}, {"request_id", "candidates", "selected"})
                    require(type(body["candidates"]) is list and 3 <= len(body["candidates"]) <= 6, "invalid_team", "Three to six candidate Pokemon required")
                    candidates = [validate_pokemon(pokemon) for pokemon in body["candidates"]]
                    selected = body["selected"]
                    require(type(selected) is list and len(selected) == 3 and all(type(index) is int and 0 <= index < len(candidates) for index in selected) and len(set(selected)) == 3, "invalid_selection", "Select exactly three different candidate indexes")
                    member["candidates"], member["selected"] = candidates, selected
                    for item in room["members"].values():
                        item["ready"] = False
                elif action == "ready":
                    require(room.get("mode") != "rental_singles", "rental_team_frozen", "Rental readiness is determined by the completed draft", 409)
                    obj(body, {"request_id", "ready"}, {"request_id", "ready"})
                    boolean(body["ready"], "ready")
                    require(not body["ready"] or len(member["selected"]) == 3, "team_required", "Choose your team before becoming ready", 409)
                    member["ready"] = body["ready"]
                elif action == "configure":
                    obj(body, {"request_id", "name", "rules_version", "mode", "boss_id", "difficulty"}, {"request_id"})
                    require(owner == room["host_id"], "host_only", "Only the host may configure", 403)
                    if "name" in body:
                        room["name"] = string(body["name"], 1, 48, "name")
                    if "rules_version" in body:
                        require(body["rules_version"] == RULES, "rules_mismatch", "Only the fixed friendly rules are supported", 409)
                    self.configure_mode(room, body)
                    for item in room["members"].values():
                        item["ready"] = False
                elif action == "leave":
                    obj(body, {"request_id"}, {"request_id"})
                    if room.get("draft", {}).get("status") == "picking":
                        room["draft"].update({"status": "cancelled", "next_owner_id": None, "deadline": None, "reason": "member_left"})
                    if owner == room["host_id"]:
                        room["status"] = "closed"
                    else:
                        del room["members"][owner]
                        room["status"] = "waiting"
                        for item in room["members"].values():
                            item["ready"] = False
                elif action == "kick":
                    obj(body, {"request_id", "member_id"}, {"request_id", "member_id"})
                    require(owner == room["host_id"], "host_only", "Only the host may remove a member", 403)
                    require(body["member_id"] in room["members"] and body["member_id"] != owner, "invalid_member", "Invalid member to remove")
                    del room["members"][body["member_id"]]
                    room["status"] = "waiting"
                    member["ready"] = False
                elif action == "start":
                    obj(body, {"request_id"}, {"request_id"})
                    require(owner == room["host_id"], "host_only", "Only the host may start", 403)
                    require(room.get("mode") != "rental_singles" or room.get("draft", {}).get("status") == "complete" and not room["draft"].get("battle_id"), "draft_required", "Begin a new server draft before starting a rental match", 409)
                    require(len(room["members"]) == 2 and all(item["ready"] and len(item["selected"]) == 3 for item in room["members"].values()), "not_ready", "Two prepared teams are required", 409)
                    battle_id = "b_" + secrets.token_hex(16)
                    now = self.clock()
                    players = [room["host_id"], next(key for key in room["members"] if key != room["host_id"])]
                    battle = {"id": battle_id, "room_code": room["code"], "host_id": owner, "players": players, "status": "active", "turn": 0, "phase": "initializing", "commands": {}, "initial_teams": {key: [copy.deepcopy(item["candidates"][index]) for index in item["selected"]] for key, item in room["members"].items()}, "state": {}, "updates": [], "result": None, "deadline": None, "last_tick": now, "authority_id": None, "authority_last_seen": now, "presence": {key: {"last_seen": now, "remaining": self.reconnect_seconds, "disconnected": False} for key in room["members"]}, "timeouts": {key: 0 for key in room["members"]}, "acks": []}
                    battle["mode"] = room.get("mode", "friendly_singles")
                    battle["compatibility"] = copy.deepcopy(room["compatibility"])
                    if battle["mode"] == "coop_boss":
                        battle.update({"boss": copy.deepcopy(room["boss"]), "ai_controlled_ids": [], "control_restore_pending_ids": [], "signals": {}})
                    self.save_battle(db, battle)
                    room["battle_id"] = battle_id
                    room["status"] = "playing"
                else:
                    raise APIError(404, "not_found", "Unknown room operation")
            room["revision"] += 1
            if room["status"] not in ("closed", "playing", "waiting"):
                room["status"] = "ready" if len(room["members"]) == 2 and all(item["ready"] for item in room["members"].values()) else "configuring"
            self.save_room(db, room)
            return 200, {"ok": True, "room": self.room_view(room), "battle_id": room.get("battle_id")}
        if len(parts) >= 3 and parts[:2] == ["v1", "battles"]:
            return self.battle_request(db, owner, method, parts, body)
        if parts[:2] in (["v1", "gyms"], ["v1", "gym-challenges"]):
            return self.gym_request(db, identity, method, parts, body)
        if parts[:2] == ["v1", "trades"]:
            return self.trade_request(db, identity, method, parts, body)
        if path == "/v1/showcases" and method == "POST":
            obj(body, {"request_id", "snapshot", "public_fields", "code"}, {"request_id", "snapshot", "public_fields"})
            snapshot = validate_pokemon(body["snapshot"])
            fields = body["public_fields"]
            require(type(fields) is list and all(type(field) is str and field in {"name", "owner", "iv", "ev"} for field in fields) and len(set(fields)) == len(fields), "invalid_visibility", "Unsupported public fields")
            code = body.get("code") or secrets.token_hex(4).upper()
            string(code, 8, 8, "code", r"[A-Fa-f0-9]+")
            code = code.upper()
            old = db.execute("SELECT owner,version,document FROM showcases WHERE code=?", (code,)).fetchone()
            require(old is None or old["owner"] == owner, "not_owner", "Cannot update another identity's showcase", 403)
            require(old is None or json.loads(old["document"]).get("source") != "server_managed", "managed_showcase_fixed", "A server-managed showcase cannot be replaced with a local Pokemon snapshot", 409)
            base_fields = {"version", "species", "level", "form", "moves", "ability", "ability2", "shiny", "appearance"}
            public = {key: snapshot[key] for key in base_fields | set(fields)}
            if "name" not in fields:
                public["appearance"].pop("head_nickname", None)
            version = old["version"] + 1 if old else 1
            showcase = {"code": code, "owner_id": owner, "version": version, "snapshot": public, "public_fields": fields}
            db.execute("INSERT OR REPLACE INTO showcases VALUES(?,?,?,?,?,?)", (code, owner, dumps(showcase), 1, version, self.clock()))
            return 200, {"ok": True, "showcase": showcase}
        if len(parts) >= 3 and parts[:2] == ["v1", "showcases"]:
            row = db.execute("SELECT * FROM showcases WHERE code=?", (parts[2].upper(),)).fetchone()
            require(row is not None and row["active"], "showcase_not_found", "Showcase does not exist or was unpublished", 404)
            if method == "GET" and len(parts) == 3:
                return 200, {"ok": True, "showcase": json.loads(row["document"])}
            if method == "POST" and len(parts) == 4 and parts[3] == "unpublish":
                obj(body, {"request_id"}, {"request_id"})
                require(row["owner"] == owner, "not_owner", "Cannot unpublish another identity's showcase", 403)
                db.execute("UPDATE showcases SET active=0,updated=? WHERE code=?", (self.clock(), row["code"]))
                return 200, {"ok": True, "code": row["code"], "active": False}
        raise APIError(404, "not_found", "Unknown endpoint")

    def battle_request(self, db, owner, method, parts, body):
        battle = self.battle(db, parts[2])
        require(owner in battle["players"], "not_participant", "Identity is not a participant", 403)
        supplied_authority = body.get("authority_id")
        if supplied_authority is not None:
            string(supplied_authority, 16, 100, "authority_id", r"[A-Za-z0-9_\-]+")
        is_host = owner == battle["host_id"]
        matches_authority = is_host and supplied_authority is not None and supplied_authority == battle.get("authority_id")
        self.tick(db, battle, owner if not is_host or matches_authority else None)
        # Timeouts/disconnects are facts independent of a rejected late action.
        # Retain the tick, while rolling back any partial business transition
        # made by that action before its validation error. The resulting error
        # is also queryable through the same operation ID after a lost reply.
        db.execute("SAVEPOINT battle_action")
        try:
            return self.battle_action(db, owner, method, parts, body, battle)
        except APIError as error:
            db.execute("ROLLBACK TO battle_action")
            return error.status, error.response()
        finally:
            db.execute("RELEASE battle_action")

    def battle_action(self, db, owner, method, parts, body, battle):
        action = parts[3] if len(parts) == 4 else None
        supplied_authority = body.get("authority_id")
        is_host = owner == battle["host_id"]
        matches_authority = is_host and supplied_authority is not None and supplied_authority == battle.get("authority_id")
        if method == "GET" and len(parts) == 3:
            return 200, {"ok": True, "battle": self.battle_view(battle, owner)}
        require(method == "POST" and len(parts) == 4, "not_found", "Unknown battle operation", 404)
        if action == "authority":
            obj(body, {"request_id", "authority_id"}, {"request_id", "authority_id"})
            string(supplied_authority, 16, 100, "authority_id", r"[A-Za-z0-9_\-]+")
            require(is_host, "host_only", "Only the host may claim the in-memory engine", 403)
            require(battle["status"] == "active", "battle_finished", "Battle has already ended", 409)
            current = battle.get("authority_id")
            require(current is None or current == supplied_authority, "authority_conflict", "This battle already belongs to another in-memory engine", 409)
            require(current is not None or battle["turn"] == 0 and battle["phase"] == "initializing", "authority_unrecoverable", "An engine cannot be reconstructed or migrated after initialization", 409)
            battle["authority_id"] = supplied_authority
            self.tick(db, battle, owner)
            self.save_battle(db, battle)
            return 200, {"ok": True, "battle": self.battle_view(battle, owner)}
        if action == "heartbeat":
            obj(body, {"request_id", "authority_id"}, {"authority_id"})
            require(matches_authority, "authority_conflict", "Heartbeat must belong to the original in-memory engine", 409)
            return 200, {"ok": True, "battle": self.battle_view(battle, owner)}
        # A lease is not sent to opponents or returned by any public projection.
        # Its body field is checked here, then removed before existing strict
        # per-action schemas; no guest action can acquire authority implicitly.
        body = dict(body)
        body.pop("authority_id", None)
        if action == "claim":
            obj(body, {"request_id"}, {"request_id"})
            require(battle.get("mode") == "coop_boss" and not battle.get("dungeon_id") and battle["status"] == "finished" and battle.get("result", {}).get("outcome") == "win", "reward_unavailable", "A standalone cooperative victory is required; route rewards are claimed only on final completion", 409)
            reward = self.claim_reward(db, owner, "boss:" + battle["id"], {"kind": "boss_medal", "battle_id": battle["id"], "boss_id": battle["boss"]["id"]})
            return 200, {"ok": True, "reward": reward}
        require(battle["status"] == "active", "battle_finished", "Battle has already ended", 409)
        if is_host:
            require(matches_authority, "authority_conflict", "This action must belong to the original in-memory engine", 409)
        else:
            require(supplied_authority is None, "host_only", "Guests cannot supply an engine authority ID", 403)
        if action == "signal":
            obj(body, {"request_id", "signal"}, {"request_id", "signal"})
            require(battle.get("mode") == "coop_boss", "wrong_mode", "Signals are available in cooperative play", 409)
            require(body["signal"] in ("support", "focus", "switch"), "invalid_signal", "Unknown preset signal")
            battle.setdefault("signals", {})[owner] = {"signal": body["signal"], "turn": battle["turn"], "sent_at": self.clock()}
            self.save_battle(db, battle)
            return 200, {"ok": True, "battle": self.battle_view(battle, owner)}
        if action == "abort":
            obj(body, {"request_id", "reason"}, {"request_id"})
            reason = body.get("reason", "client_error")
            string(reason, 1, 80, "reason", r"[A-Za-z0-9_\-]+")
            self.finish(db, battle, None, reason, abnormal=True)
            return 200, {"ok": True, "battle": self.battle_view(battle, owner)}
        require(type(body.get("turn")) is int and body["turn"] == battle["turn"], "turn_mismatch", "This command belongs to a different phase", 409, {"turn": battle["turn"]})
        if action == "commands":
            obj(body, {"request_id", "turn", "command"}, {"request_id", "turn", "command"})
            command = obj(body["command"], {"action", "move_index", "target", "party_index"}, {"action"})
            require(command["action"] in ("move", "switch", "forced", "surrender", "wait"), "invalid_command", "Unknown battle command")
            if command["action"] == "surrender":
                obj(command, {"action"}, {"action"})
                self.finish(db, battle, None if battle.get("mode") == "coop_boss" else next(key for key in battle["players"] if key != owner), "surrender")
            else:
                require(battle["phase"] == "commands", "turn_locked", "This command phase is already locked", 409)
                require(owner not in battle.get("ai_controlled_ids", []), "ai_controlled", "Control returns at the next command phase", 409)
                require(not any(p["disconnected"] for key, p in battle["presence"].items() if key not in battle.get("ai_controlled_ids", [])), "battle_paused", "Waiting for a disconnected participant", 409)
                self.validate_command(battle, owner, command)
                battle["commands"][owner] = copy.deepcopy(command)
                battle["timeouts"][owner] = 0
                if len(battle["commands"]) == 2:
                    battle["phase"], battle["deadline"] = "locked", None
                self.save_battle(db, battle)
        elif action == "withdraw":
            obj(body, {"request_id", "turn"}, {"request_id", "turn"})
            require(battle["phase"] == "commands", "turn_locked", "This command phase is already locked", 409)
            require(owner not in battle.get("ai_controlled_ids", []), "ai_controlled", "Control returns at the next command phase", 409)
            battle["commands"].pop(owner, None)
            self.save_battle(db, battle)
        elif action == "resolve":
            obj(body, {"request_id", "turn", "state", "digest", "state_hash", "random_tape", "decision"}, {"request_id", "turn", "state", "decision"})
            require(owner == battle["host_id"], "host_only", "Only the authority host may resolve", 403)
            require(battle["phase"] == "locked" or battle["turn"] == 0 and battle["phase"] == "initializing", "not_locked", "Both commands must be locked before resolution", 409)
            state = validate_state(body["state"], battle["players"], battle.get("mode", "friendly_singles"))
            if "visuals" in state:
                previous_seq = battle.get("state", {}).get("visuals", {}).get("seq", 0)
                require(state["visuals"]["seq"] > previous_seq, "visual_sequence", "Cosmetic event sequence must increase for each resolution", 409)
            if "team_states" in state:
                previous = battle.get("state", {}).get("team_states", battle.get("runtime_state"))
                allowed_items = {pokemon["item"] for party in battle["initial_teams"].values() for pokemon in party if pokemon["item"] is not None}
                if battle.get("boss", {}).get("item") is not None:
                    allowed_items.add(battle["boss"]["item"])
                if battle.get("dungeon_id"):
                    row = db.execute("SELECT document FROM dungeons WHERE id=?", (battle["dungeon_id"],)).fetchone()
                    if row:
                        route = json.loads(row["document"])
                        allowed_items.update(encounter["item"] for encounter in route["encounters"].values() if encounter.get("item") is not None)
                validate_runtime_state(state["team_states"], battle["players"], battle["initial_teams"], previous, allowed_items)
            state_hash = body.get("digest", body.get("state_hash"))
            string(state_hash, 64, 64, "digest", r"[A-Fa-f0-9]+")
            decision = integer(body["decision"], 0, 5, "decision")
            tape = body.get("random_tape", [])
            require(type(tape) is list and len(tape) <= 10000, "invalid_random_tape", "Random tape too large")
            for entry in tape:
                obj(entry, {"limit", "value"}, {"limit", "value"})
                integer(entry["limit"], 1, 2147483647, "random.limit")
                integer(entry["value"], 0, entry["limit"] - 1, "random.value")
            update = {"turn": battle["turn"], "state": state, "digest": state_hash, "random_tape": tape, "decision": decision}
            update["commands"] = copy.deepcopy(battle["commands"])
            battle["updates"].append(update)
            battle["state"] = state
            battle["acks"] = [owner]
            if battle.get("mode") == "coop_boss":
                battle["acks"] = list(set(battle["acks"]) | set(battle.get("ai_controlled_ids", [])))
            if decision:
                winner = battle["host_id"] if decision == 1 else next(key for key in battle["players"] if key != owner) if decision == 2 else None
                if battle.get("mode") == "coop_boss" and decision != 1:
                    winner = None  # A Boss victory never means the guest won.
                self.finish(db, battle, winner, "battle_decision_" + str(decision))
            elif battle["turn"] == 0 and "visuals" not in state:
                self.advance(battle)
                self.save_battle(db, battle)
            else:
                battle["phase"] = "playback"
                if len(battle["acks"]) == 2:
                    self.advance(battle)
                self.save_battle(db, battle)
        elif action == "ack":
            obj(body, {"request_id", "turn", "digest"}, {"request_id", "turn", "digest"})
            require(battle["phase"] == "playback", "not_playback", "No resolution awaiting acknowledgement", 409)
            require(body["digest"] == battle["updates"][-1]["digest"], "state_divergence", "Acknowledged state hash differs", 409)
            if owner not in battle["acks"]:
                battle["acks"].append(owner)
            if len(battle["acks"]) == 2:
                self.advance(battle)
            self.save_battle(db, battle)
        else:
            raise APIError(404, "not_found", "Unknown battle operation")
        return 200, {"ok": True, "battle": self.battle_view(battle, owner)}

    def validate_command(self, battle, owner, command):
        actions = battle["state"].get("actions", {}).get(owner, {})
        kind = command["action"]
        if kind == "move":
            obj(command, {"action", "move_index", "target"}, {"action", "move_index", "target"})
            integer(command["move_index"], -1, 3, "move_index")
            integer(command["target"], -1, 3, "target")
            move = next((move for move in actions.get("moves", []) if move["index"] == command["move_index"]), None)
            require(battle["state"].get("kind") == "command" and move is not None and (move["pp"] > 0 or move["index"] == -1), "illegal_move", "Move is not one of the host's usable options", 409)
            # Singles only: opposing slot, own slot and -1 (engine auto target).
            valid_targets = (-1, 0, 1, 2, 3) if battle.get("mode") == "coop_boss" else (-1, 0, 1)
            require(command["target"] in move.get("targets", valid_targets), "illegal_target", "Target is not one of this move's legal options", 409)
        elif kind == "switch":
            obj(command, {"action", "party_index"}, {"action", "party_index"})
            integer(command["party_index"], 0, 2, "party_index")
            require(actions.get("can_switch") and any(switch["party_index"] == command["party_index"] for switch in actions.get("switches", [])), "illegal_switch", "Party member is not an available replacement", 409)
        else:
            obj(command, {"action"}, {"action"})
            require(owner not in battle["state"].get("phase_owner_ids", []) or kind == "forced" and actions.get("forced", False), "illegal_wait", "This participant must choose an action", 409)

    def configure_mode(self, room, body):
        mode = body.get("mode", room.get("mode", "friendly_singles"))
        if mode == "boss":
            mode = "coop_boss"
        require(type(mode) is str and mode in MODES, "invalid_mode", "Unknown room mode")
        room["mode"] = mode
        if mode != "coop_boss":
            require("boss_id" not in body and "difficulty" not in body, "wrong_mode", "Boss settings require a cooperative room")
            room.pop("boss", None)
            return
        boss_id = body.get("boss_id", room.get("boss", {}).get("id", BOSS_ID))
        difficulty = body.get("difficulty", room.get("boss", {}).get("difficulty", "normal"))
        require(boss_id == BOSS_ID and type(boss_id) is str, "unknown_boss", "Unknown Boss configuration", 409)
        require(difficulty in ("normal", "hard"), "invalid_difficulty", "Unsupported Boss difficulty")
        hard = difficulty == "hard"
        room["boss"] = {"id": BOSS_ID, "version": 1, "name": "岩钢试炼", "difficulty": difficulty, "species": "B76H95", "level": 60 if hard else 50, "moves": ["ROCKSLIDE", "EARTHQUAKE", "PROTECT", "BODYSLAM"], "ability": "STURDY", "stat_stages": {key: 2 if hard else 1 for key in ("ATTACK", "DEFENSE", "SPECIAL_DEFENSE")}, "hp_multiplier": 4 if hard else 3}

    def claim_reward(self, db, owner, scope, payload):
        old = db.execute("SELECT document FROM rewards WHERE owner=? AND scope=?", (owner, scope)).fetchone()
        if old:
            return json.loads(old["document"])
        reward = {"id": "medal_" + secrets.token_hex(16), "owner_id": owner, "claimed_at": self.clock(), **payload}
        db.execute("INSERT INTO rewards VALUES(?,?,?)", (owner, scope, dumps(reward)))
        return reward

    def gym_document(self, db, code):
        row = db.execute("SELECT document FROM gyms WHERE code=?", (code.upper(),)).fetchone()
        require(row is not None, "gym_not_found", "AI Gym does not exist", 404)
        return json.loads(row["document"])

    def gym_view(self, gym, owner):
        fields = ("code", "owner_id", "owner_name", "name", "description", "intro", "version", "active", "created_at", "updated_at")
        view = {key: copy.deepcopy(gym[key]) for key in fields}
        view["rules"] = {"id": RULES, "level": 50, "team_size": 3, "bag_items": False, "defender": "AI", "result_trust": "client_reported_casual"}
        view["team_preview"] = [{key: copy.deepcopy(pokemon[key]) for key in ("species", "level", "form", "shiny", "appearance")} for pokemon in gym["team"]]
        # Private nickname decoration is not part of the public roster preview.
        for pokemon in view["team_preview"]:
            pokemon["appearance"].pop("head_nickname", None)
        if owner == gym["owner_id"]:
            view["team"] = copy.deepcopy(gym["team"])
        return view

    def save_gym(self, db, gym):
        db.execute("INSERT OR REPLACE INTO gyms VALUES(?,?,?,?)", (gym["code"], gym["owner_id"], dumps(gym), self.clock()))

    def gym_request(self, db, identity, method, parts, body):
        owner = identity["id"]
        if parts[:2] == ["v1", "gym-challenges"]:
            if method == "GET" and len(parts) == 2:
                reports = [json.loads(row["document"]) for row in db.execute("SELECT document FROM gym_challenges WHERE owner=? ORDER BY updated DESC LIMIT 100", (owner,))]
                return 200, {"ok": True, "challenges": reports}
            require(len(parts) in (3, 4), "not_found", "Unknown challenge endpoint", 404)
            row = db.execute("SELECT owner,document FROM gym_challenges WHERE id=?", (parts[2],)).fetchone()
            require(row is not None, "challenge_not_found", "AI Gym challenge does not exist", 404)
            require(row["owner"] == owner, "not_participant", "This challenge belongs to another identity", 403)
            challenge = json.loads(row["document"])
            if method == "GET" and len(parts) == 3:
                return 200, {"ok": True, "challenge": challenge}
            require(method == "POST" and len(parts) == 4, "not_found", "Unknown challenge endpoint", 404)
            if parts[3] == "result":
                obj(body, {"request_id", "outcome", "turns", "summary"}, {"request_id", "outcome", "turns", "summary"})
                require(body["outcome"] in ("win", "loss", "abandon", "abnormal"), "invalid_outcome", "Unsupported challenge outcome")
                integer(body["turns"], 0, 10000, "turns")
                string(body["summary"], 0, 2048, "summary")
                if challenge["status"] != "active":
                    require(all(challenge["result"][key] == body[key] for key in ("outcome", "turns", "summary")), "result_conflict", "The original challenge result is immutable", 409)
                else:
                    challenge["status"] = "finished"
                    challenge["result"] = {"id": "report_" + challenge["id"], "outcome": body["outcome"], "turns": body["turns"], "summary": body["summary"], "reported_at": self.clock(), "trust": "client_reported_casual"}
                    db.execute("UPDATE gym_challenges SET document=?,updated=? WHERE id=?", (dumps(challenge), self.clock(), challenge["id"]))
                return 200, {"ok": True, "challenge": challenge}
            if parts[3] == "claim":
                obj(body, {"request_id"}, {"request_id"})
                require(challenge["status"] == "finished" and challenge["result"]["outcome"] == "win", "reward_unavailable", "A reported victory is required", 409)
                reward = self.claim_reward(db, owner, "gym:" + challenge["gym_code"], {"kind": "gym_medal", "gym_code": challenge["gym_code"], "challenge_id": challenge["id"]})
                return 200, {"ok": True, "reward": reward}
            raise APIError(404, "not_found", "Unknown challenge operation")
        if method == "GET" and len(parts) == 2:
            favorites = {row["code"] for row in db.execute("SELECT code FROM gym_favorites WHERE owner=?", (owner,))}
            gyms = []
            for row in db.execute("SELECT document FROM gyms ORDER BY updated DESC LIMIT 200"):
                gym = json.loads(row["document"])
                if gym["active"] or gym["owner_id"] == owner:
                    view = self.gym_view(gym, owner)
                    view["favorite"] = gym["code"] in favorites
                    gyms.append(view)
            return 200, {"ok": True, "gyms": gyms}
        creating = len(parts) == 2 and method == "POST"
        gym = None if creating else self.gym_document(db, parts[2]) if len(parts) >= 3 else None
        if method == "GET" and len(parts) == 3:
            return 200, {"ok": True, "gym": self.gym_view(gym, owner)}
        require(method == "POST" and (creating or len(parts) == 4), "not_found", "Unknown AI Gym endpoint", 404)
        action = "publish" if creating else parts[3]
        if action == "publish":
            obj(body, {"request_id", "name", "description", "intro", "compatibility", "team"}, {"request_id", "name", "description", "intro", "compatibility", "team"})
            require(creating or gym["owner_id"] == owner, "not_owner", "Only the Gym owner may publish", 403)
            compatibility = validate_compatibility(body["compatibility"])
            string(body["name"], 1, 48, "name")
            string(body["description"], 0, 512, "description")
            string(body["intro"], 0, 256, "intro")
            require(type(body["team"]) is list and 1 <= len(body["team"]) <= 6, "invalid_team", "AI Gyms require one to six defenders")
            team = [validate_pokemon(pokemon) for pokemon in body["team"]]
            if creating:
                code = secrets.token_hex(4).upper()
                while db.execute("SELECT 1 FROM gyms WHERE code=?", (code,)).fetchone():
                    code = secrets.token_hex(4).upper()
                gym = {"code": code, "owner_id": owner, "owner_name": identity["nickname"], "version": 0, "created_at": self.clock()}
            gym.update({key: body[key] for key in ("name", "description", "intro")})
            gym.update({"compatibility": compatibility, "team": team, "version": gym["version"] + 1, "active": True, "updated_at": self.clock()})
            db.execute("INSERT INTO gym_versions VALUES(?,?,?)", (gym["code"], gym["version"], dumps(gym)))
            self.save_gym(db, gym)
            return 201 if creating else 200, {"ok": True, "gym": self.gym_view(gym, owner)}
        if action == "close":
            obj(body, {"request_id"}, {"request_id"})
            require(gym["owner_id"] == owner, "not_owner", "Only the Gym owner may close it", 403)
            gym.update({"active": False, "updated_at": self.clock()})
            self.save_gym(db, gym)
            return 200, {"ok": True, "gym": self.gym_view(gym, owner)}
        if action == "favorite":
            obj(body, {"request_id", "favorite"}, {"request_id", "favorite"})
            boolean(body["favorite"], "favorite")
            if body["favorite"]:
                db.execute("INSERT OR IGNORE INTO gym_favorites VALUES(?,?)", (owner, gym["code"]))
            else:
                db.execute("DELETE FROM gym_favorites WHERE owner=? AND code=?", (owner, gym["code"]))
            return 200, {"ok": True, "gym_code": gym["code"], "favorite": body["favorite"]}
        if action == "challenge":
            obj(body, {"request_id", "compatibility", "team"}, {"request_id", "compatibility", "team"})
            require(gym["active"], "gym_closed", "AI Gym is closed to new challenges", 409)
            compatibility = validate_compatibility(body["compatibility"])
            differences = [key for key in COMPATIBILITY if compatibility[key] != gym["compatibility"][key]]
            require(not differences, "compatibility_mismatch", "Gym game, data, mods or rules differ", 409, differences)
            require(type(body["team"]) is list and len(body["team"]) == 3, "invalid_team", "Choose three challenger Pokemon")
            team = [validate_pokemon(pokemon) for pokemon in body["team"]]
            challenge = {"id": "gc_" + secrets.token_hex(16), "owner_id": owner, "gym_code": gym["code"], "gym_version": gym["version"], "gym_name": gym["name"], "intro": gym["intro"], "team": team, "defender_team": copy.deepcopy(gym["team"]), "rules": self.gym_view(gym, owner)["rules"], "status": "active", "created_at": self.clock(), "result": None}
            db.execute("INSERT INTO gym_challenges VALUES(?,?,?,?)", (challenge["id"], owner, dumps(challenge), self.clock()))
            return 201, {"ok": True, "challenge": challenge}
        raise APIError(404, "not_found", "Unknown AI Gym operation")

    def save_trade(self, db, trade):
        trade["updated_at"] = self.clock()
        db.execute("INSERT OR REPLACE INTO trades VALUES(?,?,?)", (trade["code"], dumps(trade), self.clock()))

    def trade_document(self, db, code):
        row = db.execute("SELECT document FROM trades WHERE code=?", (code.upper(),)).fetchone()
        require(row is not None, "trade_not_found", "Exchange session does not exist", 404)
        trade = json.loads(row["document"])
        if trade["status"] in ("waiting", "offering") and self.clock() >= trade["expires_at"]:
            trade["status"] = "expired"
            trade["confirmations"] = []
            trade["revision"] += 1
            self.save_trade(db, trade)
            if trade["source"] == "server_managed":
                db.execute("DELETE FROM asset_locks WHERE reference=?", ("trade:" + trade["code"],))
        return trade

    def trade_view(self, db, trade, owner):
        require(owner in trade["members"], "not_member", "Identity is not a member of this exchange", 403)
        fields = ("code", "host_id", "members", "status", "revision", "source", "offers", "confirmations", "transaction_id", "created_at", "expires_at", "updated_at")
        view = {key: copy.deepcopy(trade.get(key)) for key in fields}
        view["receipt"] = None
        view["acked"] = []
        if trade.get("transaction_id"):
            for row in db.execute("SELECT owner,document,acked FROM trade_receipts WHERE transaction_id=?", (trade["transaction_id"],)):
                if row["acked"]:
                    view["acked"].append(row["owner"])
                if row["owner"] == owner:
                    view["receipt"] = json.loads(row["document"])
        return view

    def check_free_trade(self, db, owner, exclude=None):
        for row in db.execute("SELECT code FROM trades").fetchall():
            if row["code"] == exclude:
                continue
            trade = self.trade_document(db, row["code"])
            if trade["status"] == "committed" and owner in trade["members"]:
                receipt = db.execute("SELECT acked FROM trade_receipts WHERE transaction_id=? AND owner=?", (trade["transaction_id"], owner)).fetchone()
                if receipt and receipt["acked"]:
                    continue  # The other player's offline receipt cannot lock us forever.
            require(owner not in trade["members"] or trade["status"] in ("completed", "cancelled", "expired"), "trade_pending", "Recover or cancel the current exchange before starting another", 409, {"code": trade["code"]})

    def trade_request(self, db, identity, method, parts, body):
        owner = identity["id"]
        if method == "GET" and len(parts) == 2:
            trades = []
            for row in db.execute("SELECT code FROM trades ORDER BY updated DESC").fetchall():
                trade = self.trade_document(db, row["code"])
                if owner in trade["members"]:
                    trades.append(self.trade_view(db, trade, owner))
            return 200, {"ok": True, "trades": trades[:100]}
        if method == "POST" and len(parts) == 2:
            obj(body, {"request_id", "compatibility", "source"}, {"request_id", "compatibility"})
            require(body.get("source", "local_casual") == "local_casual", "unsupported_source", "Only local casual exchanges are available", 409)
            compatibility = validate_compatibility(body["compatibility"])
            self.check_free_trade(db, owner)
            code = secrets.token_hex(4).upper()
            while db.execute("SELECT 1 FROM trades WHERE code=?", (code,)).fetchone():
                code = secrets.token_hex(4).upper()
            trade = {"code": code, "host_id": owner, "members": {owner: {"id": owner, "nickname": identity["nickname"]}}, "compatibility": compatibility, "source": "local_casual", "status": "waiting", "revision": 1, "offers": {}, "confirmations": [], "transaction_id": None, "created_at": self.clock(), "expires_at": self.clock() + 86400}
            self.save_trade(db, trade)
            return 201, {"ok": True, "trade": self.trade_view(db, trade, owner)}
        require(len(parts) in (3, 4), "not_found", "Unknown exchange endpoint", 404)
        trade = self.trade_document(db, parts[2])
        if method == "GET" and len(parts) == 3:
            return 200, {"ok": True, "trade": self.trade_view(db, trade, owner)}
        require(method == "POST" and len(parts) == 4, "not_found", "Unknown exchange endpoint", 404)
        action = parts[3]
        if action == "join":
            obj(body, {"request_id", "compatibility", "source"}, {"request_id", "compatibility"})
            require("source" not in body or body["source"] == trade["source"], "source_mismatch", "This exchange uses a different asset source", 409)
            compatibility = validate_compatibility(body["compatibility"])
            require(trade["status"] in ("waiting", "offering"), "trade_closed", "Exchange no longer accepts participants", 409)
            require(all(compatibility[key] == trade["compatibility"][key] for key in COMPATIBILITY), "compatibility_mismatch", "Exchange game, data, mods or rules differ", 409)
            if owner not in trade["members"]:
                require(len(trade["members"]) < 2, "trade_full", "Exchange already has two members", 409)
                self.check_free_trade(db, owner, trade["code"])
                trade["members"][owner] = {"id": owner, "nickname": identity["nickname"]}
                trade["status"] = "offering"
                trade["revision"] += 1
                self.save_trade(db, trade)
            return 200, {"ok": True, "trade": self.trade_view(db, trade, owner)}
        require(owner in trade["members"], "not_member", "Identity is not a member of this exchange", 403)
        if action == "ack":
            obj(body, {"request_id", "transaction_id"}, {"request_id", "transaction_id"})
            require(trade["status"] in ("committed", "completed") and body["transaction_id"] == trade["transaction_id"], "transaction_mismatch", "No matching committed transaction", 409)
            db.execute("UPDATE trade_receipts SET acked=1 WHERE transaction_id=? AND owner=?", (trade["transaction_id"], owner))
            pending = db.execute("SELECT COUNT(*) FROM trade_receipts WHERE transaction_id=? AND acked=0", (trade["transaction_id"],)).fetchone()[0]
            if not pending:
                trade["status"] = "completed"
                self.save_trade(db, trade)
            return 200, {"ok": True, "trade": self.trade_view(db, trade, owner)}
        require(trade["status"] in ("waiting", "offering"), "trade_closed", "A committed or closed exchange cannot be changed", 409)
        if action in ("offer", "confirm"):
            require(trade["compatibility"]["protocol"] == PROTOCOL, "protocol_mismatch", "Cancel and restore this older exchange before creating a new one", 409)
        if action == "offer":
            obj(body, {"request_id", "snapshot", "offer_id"}, {"request_id", "snapshot", "offer_id"})
            string(body["offer_id"], 1, 100, "offer_id", r"[A-Za-z0-9_\-]+")
            snapshot = validate_trade_snapshot(body["snapshot"])
            trade["offers"][owner] = {"snapshot": snapshot, "offer_id": body["offer_id"], "hash": digest(dumps(snapshot))}
            trade["confirmations"] = []
            trade["revision"] += 1
        elif action == "cancel":
            obj(body, {"request_id"}, {"request_id"})
            trade["status"] = "cancelled"
            trade["confirmations"] = []
            trade["revision"] += 1
        elif action == "confirm":
            obj(body, {"request_id", "revision", "offer_hashes"}, {"request_id", "revision", "offer_hashes"})
            require(type(body["revision"]) is int and body["revision"] == trade["revision"], "offer_changed", "Exchange offers changed; inspect both offers again", 409)
            require(len(trade["members"]) == 2 and set(trade["offers"]) == set(trade["members"]), "offers_required", "Both participants must submit an offer", 409)
            obj(body["offer_hashes"], trade["members"], trade["members"])
            require(body["offer_hashes"] == {key: offer["hash"] for key, offer in trade["offers"].items()}, "offer_changed", "Offer hashes differ from the inspected snapshots", 409)
            if owner not in trade["confirmations"]:
                trade["confirmations"].append(owner)
            if len(trade["confirmations"]) == 2:
                # Confirmation, transaction ID and both immutable receipts are
                # written under the request's one SQLite write transaction.
                trade["status"] = "committed"
                trade["transaction_id"] = "tx_" + secrets.token_hex(16)
                for participant in trade["members"]:
                    other = next(key for key in trade["members"] if key != participant)
                    receipt = {"transaction_id": trade["transaction_id"], "source": "local_casual", "owner_id": participant, "offered_hash": trade["offers"][participant]["hash"], "received_snapshot": copy.deepcopy(trade["offers"][other]["snapshot"]), "received_hash": trade["offers"][other]["hash"], "committed_at": self.clock()}
                    db.execute("INSERT INTO trade_receipts VALUES(?,?,?,0)", (trade["transaction_id"], participant, dumps(receipt)))
        else:
            raise APIError(404, "not_found", "Unknown exchange operation")
        self.save_trade(db, trade)
        return 200, {"ok": True, "trade": self.trade_view(db, trade, owner)}


class Handler(BaseHTTPRequestHandler):
    server_version = "KurayMultiplayer/1"

    def do_GET(self):
        self.handle_request("GET")

    def do_POST(self):
        self.handle_request("POST")

    def handle_request(self, method):
        try:
            parsed = urlsplit(self.path)
            require(not parsed.query and not parsed.fragment, "invalid_path", "Query strings are not supported")
            body = {}
            if method == "POST":
                length = int(self.headers.get("Content-Length", "0"))
                limit = MAX_CLOUD_BODY if parsed.path == "/v1/cloud/upload" else MAX_BODY
                require(0 < length <= limit, "body_too_large", "Invalid request body length", 413)
                require(not self.headers.get("Transfer-Encoding"), "invalid_encoding", "Chunked requests are not supported")
                # Drain bounded bodies before a media-type rejection. Closing
                # a Windows socket with unread input can reset the connection
                # before the peer receives our structured 415 response.
                raw = self.rfile.read(length)
                require(self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower() == "application/json", "content_type", "Use application/json", 415)
                body = json.loads(raw.decode("utf-8"), parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))
            header = self.headers.get("Authorization", "")
            token = header[7:] if header.startswith("Bearer ") else None
            status, response = self.server.store.request(method, parsed.path, body, token, self.client_address[0])
        except APIError as error:
            status, response = error.status, error.response()
        except (ValueError, UnicodeError, RecursionError):
            status, response = 400, {"ok": False, "error": {"code": "invalid_json", "message": "Invalid UTF-8 JSON request"}}
        except Exception:
            LOG.exception("Request failed (%s %s)", method, urlsplit(self.path).path)
            status, response = 500, {"ok": False, "error": {"code": "internal_error", "message": "Internal service error"}}
        encoded = dumps(response).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        try:
            self.wfile.write(encoded)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass  # Operation remains committed and queryable by request ID.

    def log_message(self, format, *args):
        # Paths contain IDs only; never log request bodies or auth headers.
        LOG.info("%s %s", self.address_string(), format % args)


class ExclusiveHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = False

    def server_bind(self):
        if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        super().server_bind()


def make_server(host, port, store):
    server = ExclusiveHTTPServer((host, port), Handler)
    server.store = store
    server.daemon_threads = True
    return server


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--database", default=str(Path(__file__).parent / "data" / "multiplayer-test.sqlite3"))
    parser.add_argument("--log-file")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", handlers=[logging.StreamHandler()] + ([logging.FileHandler(args.log_file, encoding="utf-8")] if args.log_file else []))
    # Binding must succeed before Store performs restart recovery. A second
    # accidental launch on an occupied port must never abort the live service's
    # active battles before reporting the bind failure.
    server = make_server(args.host, args.port, None)
    try:
        with database_instance_lock(args.database):
            server.store = Store(args.database)
            try:
                LOG.info("Listening on http://%s:%s protocol=%s database=%s", args.host, server.server_port, PROTOCOL, args.database)
                server.serve_forever(poll_interval=0.25)
            finally:
                server.store.close()
                server.store = None
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
