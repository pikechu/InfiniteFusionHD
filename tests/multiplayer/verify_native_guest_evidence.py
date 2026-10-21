"""Verify authority-only combat plus native guest playback from Game.exe logs."""
import argparse
import json
import re
from pathlib import Path


def verify(host_path, guest_path):
    contents = [Path(path).read_text(encoding="utf-8") for path in (host_path, guest_path)]
    checks = 0

    def check(condition, message):
        nonlocal checks
        if not condition:
            raise AssertionError(message)
        checks += 1

    authority = {}
    for payload in re.findall(r"EVENT authority_state (.+)", contents[0]):
        value = json.loads(payload)
        authority[value["state"]["visuals"]["seq"]] = value["state"]
    check(bool(authority), "No real authority state")
    started = re.search(r"EVENT engine_started (.+)", contents[0])
    players = json.loads(started[1])["players"]
    check(len(players) == 2 and len(set(players)) == 2, "Distinct identities not used")
    guest_id = players[1]
    played, applied, pending = {}, {}, []
    for event, payload in re.findall(r"EVENT (guest_visual_event|guest_visual_applied|received_state) (.+)", contents[1]):
        value = json.loads(payload)
        if event == "guest_visual_event":
            check(value["native"] is True, "Animation was skipped")
            pending.append(value["event"])
        elif event == "guest_visual_applied":
            played[value["seq"]] = pending
            pending = []
            applied[value["seq"]] = value["rendered_battlers"]
        else:
            check(set(value["state"].get("actions", {})) <= {guest_id}, "Opponent private command options leaked")
            check("team_states" not in value["state"], "Singles exposed entire opposing party state")
    check(set(authority) == set(applied), "A visual input boundary was lost or repeated")
    for sequence, state in authority.items():
        check(played[sequence] == state["visuals"]["events"], f"Native timeline differs at sequence {sequence}")
        expected = [{key: battler[key] for key in ("index", "hp", "totalhp", "status", "species")} for battler in state["battlers"]]
        check(applied[sequence] == expected, f"Actual native battler values diverged at sequence {sequence}")
    kinds = {event["kind"] for events in played.values() for event in events}
    check({"move", "hp", "replace", "faint"} <= kinds, "Move/HP/replacement/faint animation paths not exercised")
    final = []
    for text in contents:
        check("NATIVE_GUEST_GAME_PASS" in text and "NATIVE_GUEST_GAME_FAIL" not in text, "Game process failed")
        check("guest_visual_fallback" not in text, "Fallback was used")
        check("ORIGINAL_GLOBALS_AND_WORLD_UNCHANGED" in text, "Main save/world protection missing")
        row = re.search(r"NATIVE_GUEST_GAME_PASS .+ result=(\{.+\}) ORIGINAL_GLOBALS_AND_WORLD_UNCHANGED", text)
        final.append(json.loads(row[1]))
    check(final[0] == final[1] and not final[0]["abnormal"], "Official settlements differ")
    return {"status": "passed", "checks": checks, "sequences": sorted(applied),
            "event_kinds": sorted(kinds), "native_events": sum(len(events) for events in played.values()),
            "result": final[0], "scope": "real local two-Game.exe authority/observer; automated input, manual and cross-machine checks separate"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--guest", required=True)
    parser.add_argument("--output")
    args = parser.parse_args()
    result = verify(args.host, args.guest)
    if args.output:
        Path(args.output).write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"NATIVE_GUEST_EVIDENCE_PASS checks={result['checks']} native_events={result['native_events']}")
