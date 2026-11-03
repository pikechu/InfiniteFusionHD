"""Pure, versioned controlled-campaign mechanics. No client result is evaluated.

The v1 policy deliberately disables abilities, held items and weather and only
publishes moves implemented here. It is separate from the legacy Ruby rules.
"""
import copy
import hashlib
import hmac
import math
import re
import secrets

STATS = ("HP", "ATTACK", "DEFENSE", "SPECIAL_ATTACK", "SPECIAL_DEFENSE", "SPEED")
BOOSTS = {
    "GROWL": (False, {"ATTACK": -1}), "LEER": (False, {"DEFENSE": -1}),
    "TAILWHIP": (False, {"DEFENSE": -1}), "SANDATTACK": (False, {"accuracy": -1}),
    "SMOKESCREEN": (False, {"accuracy": -1}), "STRINGSHOT": (False, {"SPEED": -2}),
    "SCARYFACE": (False, {"SPEED": -2}), "GROWTH": (True, {"ATTACK": 1, "SPECIAL_ATTACK": 1}),
    "SWORDSDANCE": (True, {"ATTACK": 2}), "NASTYPLOT": (True, {"SPECIAL_ATTACK": 2}),
    "CALMMIND": (True, {"SPECIAL_ATTACK": 1, "SPECIAL_DEFENSE": 1}),
    "AGILITY": (True, {"SPEED": 2}), "DEFENSECURL": (True, {"DEFENSE": 1}),
    "HARDEN": (True, {"DEFENSE": 1}), "WITHDRAW": (True, {"DEFENSE": 1}),
    "AMNESIA": (True, {"SPECIAL_DEFENSE": 2}), "IRONDEFENSE": (True, {"DEFENSE": 2}),
    "DOUBLETEAM": (True, {"evasion": 1})}


class BattleRandom:
    def __init__(self, battle):
        self.battle = battle

    def randrange(self, bound):
        # Secret HMAC stream survives restarts; never disclose its key/counter.
        while True:
            counter = self.battle["random_counter"]
            self.battle["random_counter"] += 1
            value = int.from_bytes(hmac.new(bytes.fromhex(self.battle["random_key"]),
                counter.to_bytes(8, "big"), hashlib.sha256).digest(), "big")
            limit = (1 << 256) // bound * bound
            if value < limit:
                return value % bound


def species_info(catalog, identifier):
    if identifier in catalog["species"]:
        return catalog["species"][identifier]
    match = re.fullmatch(r"B([1-9][0-9]{0,2})H([1-9][0-9]{0,2})", identifier)
    if not match:
        raise ValueError("Unknown species")
    numbers = {row["id_number"]: row for row in catalog["species"].values()}
    body, head = (numbers.get(int(number)) for number in match.groups())
    if body is None or head is None:
        raise ValueError("Unknown fusion component")
    result = copy.deepcopy(body)
    result["real_name"] = head["real_name"] + "/" + body["real_name"]
    result["type1"] = head["type2"] if head["type1"] == "NORMAL" and head["type2"] == "FLYING" else head["type1"]
    result["type2"] = body["type1"] if body["type2"] == result["type1"] else body["type2"]
    for stat in STATS:
        major, minor = (head, body) if stat in ("HP", "SPECIAL_ATTACK", "SPECIAL_DEFENSE") else (body, head)
        result["base_stats"][stat] = 2 * major["base_stats"][stat] // 3 + minor["base_stats"][stat] // 3
        result["evs"][stat] = (body["evs"][stat] + head["evs"][stat]) // 2
    result["catch_rate"] = min(body["catch_rate"], head["catch_rate"])
    result["base_exp"] = (body["base_exp"] + head["base_exp"]) // 2
    result["moves"] = sorted({(level, move) for level, move in body["moves"] + head["moves"]})
    result["tutor_moves"] = sorted(set(body["tutor_moves"] + head["tutor_moves"]))
    priority = ["Fast", "Medium", "Parabolic", "Fluctuating", "Erratic", "Slow"]
    result["growth_rate"] = next(rate for rate in priority if rate in (body["growth_rate"], head["growth_rate"]))
    result["evolutions"] = []
    result["egg_groups"] = ["Undiscovered"]
    return result


def stats(catalog, monster):
    info = species_info(catalog, monster["species"])
    level = monster["level"]
    values = {}
    for stat in STATS:
        base = (2 * info["base_stats"][stat] + monster["iv"][stat] + monster["ev"][stat] // 4) * level // 100
        values[stat] = base + level + 10 if stat == "HP" else base + 5
    if monster["species"] == "SHEDINJA":
        values["HP"] = 1
    return values


def legal_moves(catalog, monster):
    return list(dict.fromkeys(move for level, move in species_info(catalog, monster["species"])["moves"] if level <= monster["level"]))


def make_monster(catalog, species, level, rng=None):
    rng = rng or secrets.SystemRandom()
    info = species_info(catalog, species)
    monster = {"id": "cm_" + secrets.token_hex(16), "species": species, "level": level,
        "exp": catalog["growth"][info["growth_rate"]][level - 1],
        "iv": {stat: rng.randrange(32) for stat in STATS}, "ev": {stat: 0 for stat in STATS},
        "gender": "female" if rng.randrange(2) == 0 else "male", "status": "NONE", "sleep": 0,
        "egg": False, "hatch_at": None, "parents": [], "revision": 1}
    ratio = info["gender_ratio"]
    monster["gender"] = {"AlwaysMale": "male", "AlwaysFemale": "female", "Genderless": "none"}.get(ratio)
    if monster["gender"] is None:
        female = {"FemaleOneEighth": 32, "Female25Percent": 64, "Female50Percent": 128, "Female75Percent": 192, "FemaleSevenEighths": 224}[ratio]
        monster["gender"] = "female" if rng.randrange(256) < female else "male"
    monster["moves"] = [{"id": move, "pp": catalog["moves"][move]["total_pp"]} for move in legal_moves(catalog, monster)[-4:]]
    monster["hp"] = stats(catalog, monster)["HP"]
    return monster


def gain_exp(catalog, monster, amount, cap):
    info = species_info(catalog, monster["species"])
    thresholds = catalog["growth"][info["growth_rate"]]
    before = stats(catalog, monster)["HP"]
    old_level = monster["level"]
    monster["exp"] = min(thresholds[cap - 1], monster["exp"] + amount) if monster["level"] <= cap else monster["exp"]
    monster["level"] = max(old_level, max(level for level, needed in enumerate(thresholds, 1) if monster["exp"] >= needed))
    if monster["hp"] > 0:
        monster["hp"] += stats(catalog, monster)["HP"] - before
    # Learning is explicit and never silently overwrites one of the four moves.
    return monster["level"] - old_level


def type_multiplier(catalog, attack_type, target):
    multiplier = 1
    for kind in set(species_info(catalog, target["species"])[key] for key in ("type1", "type2")):
        row = catalog["types"][kind]
        if attack_type in row["immunities"]:
            return 0
        if attack_type in row["weaknesses"]:
            multiplier *= 2
        if attack_type in row["resistances"]:
            multiplier /= 2
    return multiplier


def boosted(catalog, monster, key):
    value = stats(catalog, monster)[key]
    stage = monster.get("stages", {}).get(key, 0)
    value = value * (2 + max(0, stage)) // (2 + max(0, -stage))
    if key == "SPEED" and monster["status"] == "PARALYSIS":
        value //= 2
    return max(1, value)


def choose_enemy_move(catalog, monster, target):
    available = [(index, entry) for index, entry in enumerate(monster["moves"]) if entry["pp"] > 0]
    if not available:
        return -1
    def score(pair):
        move = catalog["moves"][pair[1]["id"]]
        return move["base_damage"] * type_multiplier(catalog, move["type"], target) + (1 if move["category"] == 2 else 0)
    return max(available, key=score)[0]


def attack(catalog, user, target, move_index, rng, log):
    user["flinch"] = user.get("flinch", False)
    if user["hp"] <= 0:
        return
    if user["flinch"]:
        log.append({"event": "flinch", "id": user["id"]})
        return
    status = user["status"]
    if status == "SLEEP":
        user["sleep"] = max(0, user["sleep"] - 1)
        if user["sleep"]:
            log.append({"event": "asleep", "id": user["id"]})
            return
        user["status"] = "NONE"
    if status == "FROZEN":
        if rng.randrange(100) >= 20:
            log.append({"event": "frozen", "id": user["id"]})
            return
        user["status"] = "NONE"
    if status == "PARALYSIS" and rng.randrange(4) == 0:
        log.append({"event": "paralyzed", "id": user["id"]})
        return
    if user.get("confusion", 0):
        user["confusion"] -= 1
        if rng.randrange(3) == 0:
            damage = max(1, ((2 * user["level"] // 5 + 2) * 40 * boosted(catalog, user, "ATTACK") // boosted(catalog, user, "DEFENSE") // 50) + 2)
            user["hp"] = max(0, user["hp"] - damage)
            log.append({"event": "confusion_damage", "id": user["id"], "damage": damage})
            return
    if move_index == -1:
        identifier = "STRUGGLE"
    else:
        entry = user["moves"][move_index]
        entry["pp"] -= 1
        identifier = entry["id"]
    move = catalog["moves"][identifier]
    code = move["function_code"]
    log.append({"event": "move", "id": user["id"], "move": identifier})
    self_target = identifier in BOOSTS and BOOSTS[identifier][0] or identifier in ("PROTECT", "DETECT", "RECOVER", "REST", "FOCUSENERGY") or code in ("0D5", "0D9")
    if target.get("protect") and not self_target:
        log.append({"event": "protected", "id": target["id"]})
        return
    accuracy_stage = max(-6, min(6, user.get("stages", {}).get("accuracy", 0) - target.get("stages", {}).get("evasion", 0)))
    accuracy = move["accuracy"] * (3 + max(0, accuracy_stage)) / (3 + max(0, -accuracy_stage))
    if not self_target and move["accuracy"] and rng.randrange(10000) >= min(10000, int(accuracy * 100)):
        log.append({"event": "miss", "id": user["id"]})
        return
    if identifier in BOOSTS:
        own, changes = BOOSTS[identifier]
        recipient = user if own else target
        for stat, delta in changes.items():
            recipient["stages"][stat] = max(-6, min(6, recipient["stages"].get(stat, 0) + delta))
        return
    if identifier in ("PROTECT", "DETECT"):
        if rng.randrange(3 ** min(6, user.get("protect_chain", 0))) == 0:
            user["protect"] = True
            user["protect_chain"] = user.get("protect_chain", 0) + 1
        else:
            user["protect_chain"] = 0
        return
    user["protect_chain"] = 0
    if identifier == "FOCUSENERGY":
        user["focus"] = True
        return
    if code in ("0D5", "0D9"):
        maximum = stats(catalog, user)["HP"]
        if code == "0D9":
            if user["hp"] < maximum or user["status"] != "NONE":
                user.update(status="SLEEP", sleep=3, hp=maximum)
        else:
            user["hp"] = min(maximum, user["hp"] + max(1, maximum // 2))
        return
    if code == "0DC":
        if "GRASS" not in (species_info(catalog, target["species"])["type1"], species_info(catalog, target["species"])["type2"]):
            target["seeded"] = True
        return
    effectiveness = 1 if identifier == "STRUGGLE" or move["category"] == 2 and identifier != "THUNDERWAVE" else type_multiplier(catalog, move["type"], target)
    if identifier in ("SLEEPPOWDER", "POISONPOWDER", "STUNSPORE") and "GRASS" in {species_info(catalog, target["species"])[key] for key in ("type1", "type2")}:
        effectiveness = 0
    damage = 0
    if move["category"] != 2 and effectiveness:
        if code in ("06B", "06D"):
            damage = 40 if code == "06B" else user["level"]
        else:
            physical = move["category"] == 0
            critical_stage = (2 if user.get("focus") else 0) + (1 if "h" in move["flags"] else 0)
            critical = rng.randrange((24, 8, 2, 1)[min(3, critical_stage)]) == 0
            attack_stat, defense_stat = ("ATTACK", "DEFENSE") if physical else ("SPECIAL_ATTACK", "SPECIAL_DEFENSE")
            offense = stats(catalog, user)[attack_stat] if critical and user["stages"].get(attack_stat, 0) < 0 else boosted(catalog, user, attack_stat)
            defense = stats(catalog, target)[defense_stat] if critical and target["stages"].get(defense_stat, 0) > 0 else boosted(catalog, target, defense_stat)
            damage = ((2 * user["level"] // 5 + 2) * move["base_damage"] * offense // defense // 50) + 2
            info = species_info(catalog, user["species"])
            if identifier != "STRUGGLE" and move["type"] in (info["type1"], info["type2"]):
                damage = damage * 3 // 2
            damage = int(damage * effectiveness * (1.5 if critical else 1)) * (85 + rng.randrange(16)) // 100
            if physical and user["status"] == "BURN":
                damage //= 2
            damage = max(1, damage)
        hits = 2 if code == "0BD" else ([2] * 7 + [3] * 7 + [4] * 3 + [5] * 3)[rng.randrange(20)] if code == "0C0" else 1
        actual = min(target["hp"], damage * hits)
        target["hp"] -= actual
        log.append({"event": "damage", "id": target["id"], "damage": actual, "hp": target["hp"]})
        if code == "0DD":
            user["hp"] = min(stats(catalog, user)["HP"], user["hp"] + max(1, actual // 2))
        if identifier == "STRUGGLE":
            user["hp"] = max(0, user["hp"] - max(1, stats(catalog, user)["HP"] // 4))
    chance = 100 if move["category"] == 2 else move["effect_chance"]
    if target["hp"] > 0 and effectiveness and rng.randrange(100) < chance:
        status = {"003": "SLEEP", "005": "POISON", "006": "TOXIC", "007": "PARALYSIS", "008": "PARALYSIS", "00A": "BURN", "00B": "BURN", "00C": "FROZEN", "00D": "FROZEN", "00E": "FROZEN"}.get(code)
        types = {species_info(catalog, target["species"])[key] for key in ("type1", "type2")}
        immune = status in ("POISON", "TOXIC") and bool(types & {"POISON", "STEEL"}) or status == "BURN" and "FIRE" in types or status == "PARALYSIS" and "ELECTRIC" in types or status == "FROZEN" and "ICE" in types
        if status and target["status"] == "NONE" and not immune:
            target["status"], target["sleep"] = status, 2 + rng.randrange(3) if status == "SLEEP" else 0
            log.append({"event": "status", "id": target["id"], "status": status})
        if code == "013":
            target["confusion"] = 2 + rng.randrange(4)
    if target["hp"] > 0 and code in ("00B", "00E", "00F") and rng.randrange(100) < (move["effect_chance"] if code == "00F" else 10):
        target["flinch"] = True


def finish_round(catalog, first, second, log):
    for monster, opponent in ((first, second), (second, first)):
        maximum = stats(catalog, monster)["HP"]
        damage = 0
        if monster["status"] in ("POISON", "TOXIC"):
            monster["toxic_count"] = monster.get("toxic_count", 0) + 1
            damage += max(1, maximum * monster["toxic_count"] // 16) if monster["status"] == "TOXIC" else max(1, maximum // 8)
        if monster["status"] == "BURN":
            damage += max(1, maximum // 16)
        if monster.get("seeded") and monster["hp"] > 0:
            drained = min(monster["hp"], max(1, maximum // 8))
            damage += drained
            if opponent["hp"] > 0:
                opponent["hp"] = min(stats(catalog, opponent)["HP"], opponent["hp"] + drained)
        if damage and monster["hp"] > 0:
            actual = min(monster["hp"], damage)
            monster["hp"] -= actual
            log.append({"event": "residual", "id": monster["id"], "damage": actual})


def catch_shakes(catalog, monster, rng):
    maximum = stats(catalog, monster)["HP"]
    value = (3 * maximum - 2 * monster["hp"]) * species_info(catalog, monster["species"])["catch_rate"] / (3 * maximum)
    value *= 2.5 if monster["status"] in ("SLEEP", "FROZEN") else 1.5 if monster["status"] != "NONE" else 1
    value = max(1, int(value))
    if value >= 255:
        return 4
    threshold = math.floor(65536 / ((255 / value) ** 0.1875))
    shakes = 0
    while shakes < 4 and rng.randrange(65536) < threshold:
        shakes += 1
    return shakes
