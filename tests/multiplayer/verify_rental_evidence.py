"""Check real Game.exe rental logs; does not simulate game combat."""
import argparse
import json
import re
from pathlib import Path


def verify(host_path, guest_path):
    host = Path(host_path).read_text(encoding="utf-8")
    guest = Path(guest_path).read_text(encoding="utf-8")
    checks = 0

    def check(condition, message):
        nonlocal checks
        if not condition:
            raise AssertionError(message)
        checks += 1

    picks = []
    for contents in (host, guest):
        check("RENTAL_GAME_PASS" in contents and "RENTAL_GAME_FAIL" not in contents, "Native process did not pass")
        check("ORIGINAL_GLOBALS_UNCHANGED" in contents, "Original save protection not verified")
        picks.extend(re.findall(r"PICK id=(\S+) index=(\d+) owner=(\S+) pool_digest=(\S+)", contents))
    picks.sort(key=lambda row: int(row[1]))
    check([int(row[1]) for row in picks] == list(range(6)), "Draft skipped or duplicated a pick phase")
    check(len({row[0] for row in picks}) == 1, "Draft identifier differs")
    check(len({row[3] for row in picks}) == 1, "The two clients saw different full candidate pools")
    a, b = picks[0][2], picks[1][2]
    check(a != b and [row[2] for row in picks] == [a, b, b, a, a, b], "Draft order was not ABBAAB")
    records = []
    for contents in (host, guest):
        values = {}
        for _event, payload in re.findall(r"EVENT (authority_state|received_state) (.+)", contents):
            value = json.loads(payload)
            values[value["turn"]] = value["state"]
        records.append(values)
    authority, observer = records
    check(bool(authority) and bool(observer), "No real battle state evidence")
    for turn, state in observer.items():
        check(turn in authority, f"Observer state {turn} has no authority counterpart")
        reference = authority[turn]
        for field in ("kind", "turn_count", "battlers", "weather", "terrain", "events", "phase_owner_ids"):
            check(state[field] == reference[field], f"Public state diverged at phase {turn}: {field}")
        for owner, actions in state.get("actions", {}).items():
            check(actions == reference["actions"][owner], f"Owner action options diverged at phase {turn}")
    final_results = []
    for contents in (host, guest):
        value = re.search(r"RENTAL_GAME_PASS .+ result=(\{.+\}) ORIGINAL_GLOBALS_UNCHANGED", contents)
        check(value is not None, "Official settlement not recorded")
        final_results.append(json.loads(value[1]))
    check(final_results[0] == final_results[1] and not final_results[0]["abnormal"], "Official settlement differs")
    return {"status": "passed", "checks": checks, "draft_id": picks[0][0], "pool_digest": picks[0][3],
            "observer_phases": sorted(observer), "result": final_results[0], "scope": "two local Game.exe processes, automated input; manual UI and cross-machine validation separate"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--guest", required=True)
    parser.add_argument("--output")
    args = parser.parse_args()
    report = verify(args.host, args.guest)
    if args.output:
        Path(args.output).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"RENTAL_EVIDENCE_PASS checks={report['checks']} phases={len(report['observer_phases'])}")
