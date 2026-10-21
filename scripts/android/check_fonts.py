"""Run explicit A/B font probes on one test AVD, preserving game saves."""
import argparse
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--serial", required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "temp/evidence/font-metrics-android2")
    parser.add_argument("--timeout", type=float, default=900, help="Per-mode deadline including first content installation")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    adb = [str(ROOT / "temp/tools/android-sdk/platform-tools/adb.exe"), "-s", args.serial]

    def command(*parts):
        return subprocess.check_output(adb + list(parts), stderr=subprocess.STDOUT, timeout=30)

    reports = {}
    for mode in (0, 1):
        command("shell", "am", "force-stop", "org.kuray.kif")
        command("logcat", "-c")
        result = command("shell", "am", "start", "-W", "-n", "org.kuray.kif/.LauncherActivity",
                         "--ez", "fontSmoke", "true", "--ei", "fontMetricsMode", str(mode))
        (args.output / f"mode-{mode}-launch.txt").write_bytes(result)
        if b"Error type" in result or b"Error:" in result:
            raise RuntimeError(f"Android rejected mode {mode} launch; see launch output")
        deadline = time.monotonic() + args.timeout
        while True:
            log = command("logcat", "-d", "-v", "threadtime")
            text = log.decode("utf-8", errors="replace")
            if "KIF_FONT_FAIL" in text:
                (args.output / f"mode-{mode}-logcat.txt").write_bytes(log)
                raise RuntimeError(f"Font probe mode {mode} failed; see logcat")
            if f"KIF_FONT_PASS mode={mode}" in text or f"KIF_FONT_CLIPPED mode={mode}" in text:
                break
            if time.monotonic() >= deadline:
                (args.output / f"mode-{mode}-logcat.txt").write_bytes(log)
                raise TimeoutError(f"Font probe mode {mode} timed out")
            time.sleep(3)
        (args.output / f"mode-{mode}-logcat.txt").write_bytes(log)
        for suffix in ("json", "png"):
            data = command("exec-out", "run-as", "org.kuray.kif", "cat", f"files/font-probe-mode-{mode}.{suffix}")
            (args.output / f"mode-{mode}.{suffix}").write_bytes(data)
        try:
            (args.output / f"mode-{mode}-screen.png").write_bytes(command("exec-out", "screencap", "-p"))
        except subprocess.TimeoutExpired:
            (args.output / f"mode-{mode}-screen-timeout.txt").write_text("Optional physical screencap timed out; native bitmap PNG and pixel checks retained.\n")
        reports[mode] = json.loads((args.output / f"mode-{mode}.json").read_text(encoding="utf-8"))
        print(f"Font mode {mode}: " + json.dumps(reports[mode], ensure_ascii=True), flush=True)
    if all(row["complete"] for row in reports[0]["fonts"]):
        raise AssertionError("Nominal metrics did not reproduce clipping; inspect A/B results")
    if not all(row["complete"] and row["exists"] for row in reports[1]["fonts"]):
        raise AssertionError("Rendered metrics still clip or select a missing font")
    print(f"PASS: A/B actual game draw_text font raster coverage; evidence at {args.output}", flush=True)


if __name__ == "__main__":
    main()
