"""Verify isolated real-Game HTTP/GC failure and safe-transport controls."""
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / "temp/multiplayer"
checks = 0


def check(value, label):
    global checks
    if not value:
        raise AssertionError(label)
    checks += 1


def evidence(profile):
    directory = BASE / profile
    log_path = directory / "saves/http-gvl-probe.log"
    stderr_path = directory / "stderr.log"
    log = log_path.read_text(encoding="utf-8", errors="replace")
    stderr = stderr_path.read_text(encoding="utf-8", errors="replace")
    check("no_graphics=true no_sprites=true no_thread_kill=true" in log,
          f"{profile}: isolated probe configuration")
    result = {
        "profile": profile,
        "log": str(log_path.relative_to(ROOT)),
        "stderr": str(stderr_path.relative_to(ROOT)),
        "log_sha256": hashlib.sha256(log_path.read_bytes()).hexdigest(),
        "stderr_sha256": hashlib.sha256(stderr_path.read_bytes()).hexdigest(),
    }
    return log, stderr, result


native_log, native_stderr, native = evidence("native-http-gvl-pure")
check("[BUG] object allocation during garbage collection phase" in native_stderr,
      "legacy native binding actually allocates during active GC")
check("rb_hash_new" in native_stderr and "rb_thread_call_without_gvl" in native_stderr,
      "native crash includes response Hash allocation and no-GVL binding")
check("HTTP_GVL_PROBE_PASS" not in native_log,
      "failed legacy probe is never labelled passed")
native["outcome"] = "native_vm_crash"
controls = []
for profile, transport in [("native-socket-gvl-pure", "socket"),
                           ("native-production-gvl-pure", "production")]:
    log, stderr, result = evidence(profile)
    check(f"transport={transport} " in log, f"{profile}: correct transport")
    match = re.search(r"HTTP_GVL_PROBE_PASS requests=(\d+) sweeps=(\d+) gc=(\d+)", log)
    check(match is not None, f"{profile}: real Game completion")
    requests, sweeps, gc_count = map(int, match.groups())
    check(requests == 200 and sweeps >= 1000, f"{profile}: full requests and GC stress")
    check("[BUG]" not in stderr and "PROBE_FAIL" not in log,
          f"{profile}: no native or Ruby failure")
    result.update(outcome="passed", requests=requests, forced_gc_sweeps=sweeps,
                  final_gc_count=gc_count)
    controls.append(result)

output = {
    "checks": checks,
    "actual_runtime": "Game.exe / Ruby 3.1.3",
    "legacy": native,
    "safe_controls": controls,
    "scope": "No RPG scripts, Graphics, sprites, battle/replay scenes or Thread.kill",
    "conclusion": "Bundled HTTPLite response construction races Ruby GC; core Socket control avoids that binding",
    "source_reference": "temp/runtime-research/reworked/app/jni/mkxp-z/binding/http-binding.cpp:68-105",
}
output_path = BASE / "native-http-gvl-comparison-evidence.json"
output_path.write_text(json.dumps(output, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(f"HTTP_GVL_COMPARISON_PASS checks={checks} evidence={output_path}")
