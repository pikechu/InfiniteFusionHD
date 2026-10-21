"""Verify real default-budget Boss recovery logs, without simulating combat."""
import argparse
import datetime as dt
import json
import re
from pathlib import Path


def verify(host_path, guest_path):
    host, guest = [Path(path).read_text(encoding="utf-8") for path in (host_path, guest_path)]
    checks = 0

    def check(condition, message):
        nonlocal checks
        if not condition:
            raise AssertionError(message)
        checks += 1

    def timestamp(text, marker):
        row = re.search(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) UTC " + marker, text)
        check(row is not None, f"Missing {marker}")
        return dt.datetime.strptime(row[1], "%Y-%m-%d %H:%M:%S")

    elapsed = (timestamp(guest, "EVENT guest_detached") - timestamp(guest, "FAULT_BEGIN")).total_seconds()
    check(elapsed >= 70, "Guest did not exercise the real 70-second fetch boundary")
    ai = json.loads(re.search(r"AI_TAKEOVER (\{.+\})", host)[1])
    restored = json.loads(re.search(r"CONTROL_RESTORED (\{.+\})", guest)[1])
    check(ai["remaining"] == 0 and restored["remaining"] == 0, "Reconnect allowance reset instead of staying exhausted")
    check(restored["turn"] > ai["turn"], "Human control replaced an already locked AI phase")
    reconnect = re.search(r"RECONNECTED turn=(\d+) phase=(\w+) ai=(\[.+?\]) pending=(\[.+?\])", guest)
    check(reconnect is not None and json.loads(reconnect[3]) == json.loads(reconnect[4]), "Returning guest did not wait for pending next-phase control")
    check("STALE_COMMAND_DEFINITIVELY_REJECTED code=turn_mismatch" in guest, "Uncertain old command was not authoritatively reconciled")
    check("DETACHED_WITHOUT_ABORT" in guest, "Guest detachment was not preserved")
    results, accepted = [], []
    for role, text in (("host", host), ("guest", guest)):
        check("BOSS_DISCONNECT_GAME_PASS" in text and "BOSS_DISCONNECT_GAME_FAIL" not in text, f"{role} native game did not pass")
        check("ORIGINAL_GLOBALS_UNCHANGED" in text, f"{role} original save was not checked")
        row = re.search(r"BOSS_DISCONNECT_GAME_PASS .+ accepted=(\[.+\]) result=(\{.+\}) ORIGINAL_GLOBALS_UNCHANGED", text)
        packets, result = json.loads(row[1]), json.loads(row[2])
        check(len({packet["turn"] for packet in packets}) == len(packets), f"{role} submitted duplicate effective phase commands")
        check(len({packet["request_id"] for packet in packets}) == len(packets), f"{role} reused a mutation identity across phases")
        check(result["coop_outcome"] == "victory" and not result["abnormal"], f"{role} did not finish in shared victory")
        results.append(result)
        accepted.append(packets)
    check(results[0] == results[1], "Official settlements differ")
    check(accepted[0][0]["command"]["move_index"] == 0, "Authority did not start with defensive control")
    check(accepted[1][0]["turn"] == restored["turn"], "Human guest acted before control restoration")
    return {"status": "passed", "checks": checks, "fetch_outage_seconds": elapsed,
            "ai_takeover": ai, "control_restored": restored, "result": results[0],
            "scope": "two real local Game.exe processes, default 60-second cumulative allowance, automated input"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--guest", required=True)
    parser.add_argument("--output")
    args = parser.parse_args()
    result = verify(args.host, args.guest)
    if args.output:
        Path(args.output).write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"BOSS_DISCONNECT_EVIDENCE_PASS checks={result['checks']} outage_seconds={result['fetch_outage_seconds']}")
