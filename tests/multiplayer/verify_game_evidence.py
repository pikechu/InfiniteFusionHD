"""Check consistency of already executed, real Game.exe smoke-test evidence.

This reads two existing logs. It neither runs the game nor substitutes for game,
manual-menu, LAN, public-network or deterministic dual-engine acceptance tests.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

PUBLIC_STATE_FIELDS = ("kind", "battlers", "weather", "terrain", "events", "turn_count", "phase_owner_ids")
DECODER = json.JSONDecoder()


def read_json(text, location):
    try:
        value, end = DECODER.raw_decode(text)
    except (ValueError, RecursionError) as error:
        raise ValueError(f"{location}: invalid event JSON: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"{location}: expected event JSON object")
    return value, text[end:].strip()


def read_log(path, expected_role):
    raw = path.read_bytes()
    if len(raw) > 32 * 1024 * 1024:
        raise ValueError(f"{path}: log exceeds 32 MiB")
    text = raw.decode("utf-8-sig")
    result = {"path": str(path.resolve()), "sha256": hashlib.sha256(raw).hexdigest(), "role": None,
              "pid": None, "identity": None, "source_loaded": False, "codec_checks": [],
              "codec_summary": [], "matches": {}, "smoke_pass": [], "fail_markers": []}
    current = None
    last_state = None
    for line_number, line in enumerate(text.splitlines(), 1):
        location = f"{path}:{line_number}"
        if any(marker in line for marker in ("GAME_SMOKE_FAIL", "CLIENT_GAME_TEST_FAIL", "CLIENT_GAME_TESTS_FAIL")):
            result["fail_markers"].append({"line": line_number, "text": line})
        begin = re.search(r"\bBEGIN pid=(\d+) role=(host|guest)\b", line)
        if begin:
            if result["pid"] is not None:
                raise ValueError(f"{location}: multiple process runs in one log; choose one fresh log")
            result["pid"], result["role"] = int(begin[1]), begin[2]
        if " SOURCE_LOADED " in line:
            result["source_loaded"] = all(name in line for name in ("054_Multiplayer/001_Client.rb", "054_Multiplayer/002_UI.rb", "054_Multiplayer/003_Battle.rb"))
        identity = re.search(r"\bIDENTITY id=([A-Za-z0-9_\-]+)\b", line)
        if identity:
            if result["identity"] is not None and result["identity"] != identity[1]:
                raise ValueError(f"{location}: identity changed during scenario")
            result["identity"] = identity[1]
        if " CLIENT_GAME_PASS " in line:
            result["codec_checks"].append(line.split(" CLIENT_GAME_PASS ", 1)[1])
        codec = re.search(r"\bCLIENT_GAME_TEST_PASS checks=(\d+)\b", line)
        if codec:
            result["codec_summary"].append(int(codec[1]))
        smoke = re.search(r"\bGAME_SMOKE_PASS battles=([A-Za-z0-9_,\-]+)", line)
        if smoke:
            result["smoke_pass"].append(smoke[1].split(","))
        battle_begin = re.search(r"\bBATTLE_BEGIN match=(\d+) id=([A-Za-z0-9_\-]+)\b", line)
        if battle_begin:
            match = int(battle_begin[1])
            if match in result["matches"]:
                raise ValueError(f"{location}: duplicate BATTLE_BEGIN match={match}")
            current = {"battle_id": battle_begin[2], "begin_line": line_number, "authority": {}, "received": {},
                       "settlements": [], "passes": [], "commands": [], "engine_started": [], "duplicate_states": 0}
            result["matches"][match] = current
            last_state = None
        event = re.search(r"\bEVENT (authority_state|received_state|settlement|engine_started) (\{.*)$", line)
        if event:
            if current is None:
                raise ValueError(f"{location}: battle event before BATTLE_BEGIN")
            payload, remainder = read_json(event[2], location)
            if remainder:
                raise ValueError(f"{location}: trailing text after event JSON")
            if event[1] in ("authority_state", "received_state"):
                turn = payload.get("turn")
                state = payload.get("state")
                if type(turn) is not int or turn < 0 or not isinstance(state, dict):
                    raise ValueError(f"{location}: invalid phase number/state")
                for field in PUBLIC_STATE_FIELDS:
                    if field not in state:
                        raise ValueError(f"{location}: public state missing {field}")
                if not isinstance(state["battlers"], list) or not isinstance(state["events"], list):
                    raise ValueError(f"{location}: invalid battler/event list")
                if type(state["turn_count"]) is not int:
                    raise ValueError(f"{location}: invalid game round count")
                record = {"line": line_number, "state": state, "decision": payload.get("decision")}
                bucket = current["authority" if event[1] == "authority_state" else "received"]
                if turn in bucket:
                    if bucket[turn]["state"] != state:
                        raise ValueError(f"{location}: conflicting duplicate state phase={turn}")
                    current["duplicate_states"] += 1
                else:
                    bucket[turn] = record
                last_state = {"turn": turn, "kind": state["kind"], "turn_count": state["turn_count"]}
            elif event[1] == "settlement":
                current["settlements"].append({"line": line_number, "result": payload})
            else:
                current["engine_started"].append(payload)
        command = re.search(r"\bCOMMAND match=(\d+) round=(\d+) (\{.*)$", line)
        if command:
            match = int(command[1])
            if current is None or result["matches"].get(match) is not current:
                raise ValueError(f"{location}: command does not belong to the current match")
            value, remainder = read_json(command[3], location)
            if remainder:
                raise ValueError(f"{location}: trailing command data")
            current["commands"].append({"line": line_number, "round": int(command[2]), "command": value,
                                        "preceding_state": dict(last_state) if last_state else None})
        battle_pass = re.search(r"\bBATTLE_PASS match=(\d+) decision=(\d+) result=(\{.*)$", line)
        if battle_pass:
            match = int(battle_pass[1])
            if current is None or result["matches"].get(match) is not current:
                raise ValueError(f"{location}: result does not belong to the current match")
            value, remainder = read_json(battle_pass[3], location)
            current["passes"].append({"line": line_number, "decision": int(battle_pass[2]), "result": value,
                                      "original_globals_unchanged": remainder == "ORIGINAL_GLOBALS_UNCHANGED"})
    if result["role"] != expected_role:
        raise ValueError(f"{path}: expected role={expected_role}, got {result['role']!r}")
    return result


def project_state(state):
    # Actions intentionally differ: guest only receives its own legal options.
    # Compare all fields in each public battler, rather than just an HP digest.
    projected = {field: state[field] for field in PUBLIC_STATE_FIELDS}
    battlers = projected["battlers"]
    if any(not isinstance(battler, dict) or type(battler.get("index")) is not int for battler in battlers):
        raise ValueError("Invalid public battler index")
    if len({battler["index"] for battler in battlers}) != len(battlers):
        raise ValueError("Duplicate public battler index")
    projected["battlers"] = sorted(battlers, key=lambda battler: battler["index"])
    return projected


def verify(host, guest):
    report = {"ok": True, "purpose": "Consistency checks on existing real Game.exe evidence; does not run the game",
              "inputs": [{key: log[key] for key in ("path", "sha256", "role", "pid", "identity")} for log in (host, guest)],
              "checks": [], "errors": [], "matches": [],
              "limits": ["Input automation bypasses manual menu acceptance.",
                         "Guest presents the host result; this is not independent dual-engine verification.",
                         "Phase 0 initialization is not logged as received_state by the current guest observer.",
                         "These logs do not certify LAN/public networking, reconnect or timeout scenarios."]}

    def check(condition, label, details=None):
        item = {"name": label, "passed": bool(condition)}
        if details is not None:
            item["details"] = details
        report["checks"].append(item)
        if not condition:
            report["ok"] = False
            report["errors"].append(item)

    check(host["pid"] is not None and guest["pid"] is not None and host["pid"] != guest["pid"], "two_independent_game_processes")
    check(host["identity"] is not None and guest["identity"] is not None and host["identity"] != guest["identity"], "two_independent_identities")
    for log in (host, guest):
        prefix = log["role"]
        check(log["source_loaded"], prefix + "_new_multiplayer_sources_loaded")
        check(not log["fail_markers"], prefix + "_no_failure_markers", log["fail_markers"])
        check(log["codec_summary"] == [16] and len(log["codec_checks"]) == 16 and len(set(log["codec_checks"])) == 16,
              prefix + "_sixteen_real_codec_checks", {"summary": log["codec_summary"], "individual_checks": len(log["codec_checks"])})
        check(set(log["matches"]) == {1, 2}, prefix + "_two_matches", sorted(log["matches"]))
        ids = [log["matches"][index]["battle_id"] for index in sorted(log["matches"])]
        check(len(ids) == 2 and len(set(ids)) == 2, prefix + "_rematch_has_new_battle_id", ids)
        check(log["smoke_pass"] == [ids] and len(ids) == 2, prefix + "_game_smoke_completed", log["smoke_pass"])

    for match in sorted(set(host["matches"]) & set(guest["matches"])):
        h, g = host["matches"][match], guest["matches"][match]
        prefix = f"match_{match}"
        battle_id = h["battle_id"]
        item = {"match": match, "battle_id": battle_id, "compared_phases": [], "host_only_initialization": [],
                "voluntary_switches": [], "forced_replacements": []}
        report["matches"].append(item)
        check(battle_id == g["battle_id"], prefix + "_battle_id_matches")
        check(len(h["engine_started"]) == 1 and h["engine_started"][0].get("battle_id") == battle_id
              and h["engine_started"][0].get("players") == [host["identity"], guest["identity"]], prefix + "_real_host_engine_started")
        check(not g["engine_started"] and not g["authority"], prefix + "_guest_does_not_run_authority")
        hturns, gturns = set(h["authority"]), set(g["received"])
        check(0 in hturns and len(hturns) >= 3, prefix + "_authority_initialization_and_results")
        check(hturns == set(range(max(hturns) + 1)) if hturns else False, prefix + "_authority_phases_contiguous")
        check(gturns == hturns - {0}, prefix + "_every_result_received", {"host_phases": sorted(hturns), "guest_phases": sorted(gturns)})
        if 0 in hturns and 0 not in gturns:
            item["host_only_initialization"].append(0)
        for turn in sorted(hturns & gturns):
            authority = project_state(h["authority"][turn]["state"])
            received = project_state(g["received"][turn]["state"])
            differences = [field for field in PUBLIC_STATE_FIELDS if authority[field] != received[field]]
            check(not differences, prefix + f"_phase_{turn}_public_state_matches", {"different_fields": differences})
            if not differences:
                item["compared_phases"].append(turn)
            # The normal guest must not receive the host's private legal actions.
            guest_actions = g["received"][turn]["state"].get("actions", {})
            check(isinstance(guest_actions, dict) and set(guest_actions) <= {guest["identity"]}, prefix + f"_phase_{turn}_action_privacy")

        for role, log, data in (("host", host, h), ("guest", guest, g)):
            check(len(data["passes"]) == 1, prefix + "_" + role + "_single_success_record")
            check(len(data["settlements"]) == 1, prefix + "_" + role + "_single_settlement")
            if data["passes"]:
                check(data["passes"][0]["original_globals_unchanged"], prefix + "_" + role + "_original_globals_unchanged")
            for command in data["commands"]:
                if command["command"].get("action") != "switch":
                    continue
                previous = command["preceding_state"]
                known_kind = previous is not None and previous["kind"] in ("command", "switch")
                check(known_kind, prefix + f"_{role}_switch_line_{command['line']}_classified")
                if not known_kind:
                    continue
                feature = {"role": role, "line": command["line"], "phase": previous["turn"],
                           "party_index": command["command"].get("party_index")}
                bucket = "voluntary_switches" if previous["kind"] == "command" else "forced_replacements"
                item[bucket].append(feature)
                following = [turn for turn in hturns if turn > previous["turn"]]
                if following:
                    next_state = h["authority"][min(following)]["state"]
                    active = [battler for battler in next_state["battlers"] if battler.get("owner_id") == log["identity"]]
                    check(any(battler.get("party_index") == feature["party_index"] for battler in active),
                          prefix + f"_{role}_switch_line_{command['line']}_applied")
                else:
                    check(False, prefix + f"_{role}_switch_line_{command['line']}_has_result")
        check(bool(item["voluntary_switches"]), prefix + "_voluntary_switch_exercised")
        check(bool(item["forced_replacements"]), prefix + "_forced_replacement_exercised")
        states = [record["state"] for record in h["authority"].values()]
        item["poison_observed"] = any(battler.get("status") == "POISON" for state in states for battler in state["battlers"])
        item["held_item_events"] = [event for state in states for event in state["events"] if "leftovers" in event.lower()]
        check(item["poison_observed"], prefix + "_poison_status_observed")
        check(bool(item["held_item_events"]), prefix + "_held_item_effect_observed")
        if h["settlements"] and g["settlements"]:
            hs, gs = h["settlements"][0]["result"], g["settlements"][0]["result"]
            item["settlement"] = hs
            check(hs == gs, prefix + "_complete_settlement_matches")
            check(hs.get("battle_id") == battle_id and hs.get("id") == "result_" + battle_id,
                  prefix + "_settlement_identifiers_match")
            check(hs.get("winner_id") in (host["identity"], guest["identity"]) and hs.get("abnormal") is False,
                  prefix + "_normal_decisive_result")
            check(hs.get("rewards") == [], prefix + "_no_main_save_rewards")
            for role, data in (("host", h), ("guest", g)):
                if data["passes"]:
                    expected = {key: value for key, value in hs.items() if key != "battle_id"}
                    check(data["passes"][0]["result"] == expected, prefix + "_" + role + "_final_query_matches_settlement")
            if hturns:
                last = h["authority"][max(hturns)]
                expected_decision = 1 if hs.get("winner_id") == host["identity"] else 2
                check(last["decision"] == expected_decision, prefix + "_engine_decision_matches_settlement")
    report["passed_checks"] = sum(check["passed"] for check in report["checks"])
    report["total_checks"] = len(report["checks"])
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, type=Path, help="Host's existing game-smoke.log")
    parser.add_argument("--guest", required=True, type=Path, help="Guest's existing game-smoke.log")
    parser.add_argument("--output", required=True, type=Path, help="Write the machine-readable evidence report")
    args = parser.parse_args(argv)
    try:
        report = verify(read_log(args.host, "host"), read_log(args.guest, "guest"))
    except (OSError, UnicodeError, ValueError, TypeError, KeyError) as error:
        report = {"ok": False, "errors": [{"name": "evidence_parse_error", "details": str(error)}],
                  "passed_checks": 0, "total_checks": 1}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"{'PASS' if report['ok'] else 'FAIL'}: {report['passed_checks']}/{report['total_checks']} evidence checks; report={args.output.resolve()}")
    for error in report["errors"][:20]:
        print(f"  {error['name']}: {error.get('details', '')}")
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
