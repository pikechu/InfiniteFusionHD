"""Build/run isolated, on-device MotionEvent checks against the installed KIF view.

No Gradle, JUnit, game launch, save access, or downloaded dependencies. By default
only build the small test APK. Pass --run after installing the current KIF APK
and closing the game. All generated files remain below the project's temp/.
"""
from pathlib import Path
import argparse
import datetime
import hashlib
import json
import os
import shutil
import subprocess
import sys
import zipfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
PACKAGE = "org.kuray.kif"
TEST_PACKAGE = PACKAGE + ".touchchecks"
RUNNER = TEST_PACKAGE + "/" + TEST_PACKAGE + ".TouchControlsInstrumentation"


def command(arguments, **kwargs):
    return subprocess.run([str(item) for item in arguments], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jdk", type=Path)
    parser.add_argument("--sdk", type=Path, default=ROOT / "temp/tools/android-sdk")
    parser.add_argument("--run", action="store_true", help="Install/run the test APK; requires a current target APK already installed")
    parser.add_argument("--serial", help="ADB serial; must be specified when multiple devices are connected")
    parser.add_argument("--expect-version", help="Require this installed target version, for example 0.20.7-android.7")
    args = parser.parse_args()
    jdk = args.jdk or next((ROOT / "temp/tools").glob("jdk-17*"), None)
    if jdk is None or not (jdk / "bin/javac.exe").is_file():
        raise SystemExit("Portable JDK 17 missing; pass --jdk or run bootstrap-tools.ps1")
    sdk = args.sdk
    tools = sdk / "build-tools/35.0.0"
    platform = sdk / "platforms/android-35/android.jar"
    key = ROOT / "temp/android-signing/kif-debug.keystore"
    if not key.is_file():
        raise SystemExit("Build the target local test APK first; its existing local signing key is required")
    source = ROOT / "android/tests/touch-java"
    work = ROOT / "temp/android-touch-checks"
    work.mkdir(parents=True, exist_ok=True)
    classes, dex = work / "classes", work / "dex"
    for folder in (classes, dex):
        if folder.exists():
            if folder.resolve().parent != work.resolve():
                raise SystemExit("Refusing to clean a build directory outside this test's temp directory")
            shutil.rmtree(folder)
        folder.mkdir()
    sources = sorted(source.rglob("*.java"))
    source_list = work / "sources.txt"
    source_list.write_text("\n".join('"' + str(path).replace("\\", "/") + '"' for path in sources), encoding="utf-8")
    command([jdk / "bin/javac.exe", "-J-Duser.language=en", "-encoding", "UTF-8", "--release", "8",
             "-classpath", platform, "-d", classes, "@" + str(source_list)])
    classes_jar = work / "tests.jar"
    command([jdk / "bin/jar.exe", "cf", classes_jar, "-C", classes, "."])
    command([jdk / "bin/java.exe", "-cp", tools / "lib/d8.jar", "com.android.tools.r8.D8", "--min-api", "30",
             "--lib", platform, "--output", dex, classes_jar])
    unsigned, aligned, final = work / "unsigned.apk", work / "aligned.apk", work / "kif-touch-checks.apk"
    command([tools / "aapt2.exe", "link", "-I", platform, "--manifest", source / "AndroidManifest.xml", "-o", unsigned])
    with zipfile.ZipFile(unsigned, "a", compression=zipfile.ZIP_DEFLATED) as apk:
        apk.write(dex / "classes.dex", "classes.dex")
    command([tools / "zipalign.exe", "-f", "-p", "4", unsigned, aligned])
    # The existing disposable local test key, never a release key. Its value is not logged.
    environment = dict(os.environ, KIF_TEST_KEY_PASSWORD="android")
    signer = [jdk / "bin/java.exe", "-jar", tools / "lib/apksigner.jar"]
    command(signer + ["sign", "--ks", key, "--ks-key-alias", "androiddebugkey", "--ks-pass", "env:KIF_TEST_KEY_PASSWORD",
                      "--key-pass", "env:KIF_TEST_KEY_PASSWORD", "--out", final, aligned], env=environment)
    command(signer + ["verify", final])
    record = {"apk": final.name, "sha256": hashlib.sha256(final.read_bytes()).hexdigest(),
              "scope": "Real Android MotionEvent tests against the installed target class; no gameplay acceptance claim",
              "testSources": {path.relative_to(ROOT).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                              for path in sources + [source / "AndroidManifest.xml", Path(__file__)]},
              "currentTargetSourceSha256": hashlib.sha256((ROOT / "android/app/src/main/java/org/kuray/kif/TouchControlsView.java").read_bytes()).hexdigest(),
              "compileSdk": 35, "buildTools": "35.0.0", "status": "built; not run"}
    (work / "build-record.json").write_text(json.dumps(record, indent=2), encoding="utf-8")
    print(f"Built {final} ({final.stat().st_size} bytes)", flush=True)
    if not args.run:
        print("Not run. Install the current KIF APK, close the game, then rerun with --run --expect-version <version>.")
        return
    adb = [sdk / "platform-tools/adb.exe"] + (["-s", args.serial] if args.serial else [])

    def adb_text(*items, allow_failure=False):
        result = subprocess.run([str(item) for item in adb + list(items)], capture_output=True, encoding="utf-8", errors="replace")
        if result.returncode and not allow_failure:
            raise RuntimeError(result.stdout + result.stderr)
        return result.stdout.strip()

    if adb_text("shell", "pidof", PACKAGE + ":game", allow_failure=True):
        raise SystemExit("The game process is running. Save/close it first; this test does not stop or operate the game.")
    installed_path = adb_text("shell", "pm", "path", PACKAGE)
    if not installed_path.startswith("package:"):
        raise SystemExit("Install the current KIF target APK before running touch checks")
    target_dump = adb_text("shell", "dumpsys", "package", PACKAGE)
    (work / "target-package.txt").write_text(target_dump, encoding="utf-8")
    if args.expect_version and not any(
            line.strip() == "versionName=" + args.expect_version for line in target_dump.splitlines()):
        raise SystemExit("Installed target version does not match --expect-version")
    print(adb_text("install", "--no-incremental", "-r", final), flush=True)
    execution = subprocess.run([str(item) for item in adb + ["shell", "am", "instrument", "-w", "-r", RUNNER]],
                               capture_output=True, encoding="utf-8", errors="replace", timeout=90)
    raw = execution.stdout + execution.stderr
    (work / "instrumentation.txt").write_text(raw, encoding="utf-8")
    prefix = "INSTRUMENTATION_RESULT: kif.touch.report="
    report_line = next((line[len(prefix):] for line in raw.splitlines() if line.startswith(prefix)), None)
    if execution.returncode or report_line is None:
        print(raw)
        raise SystemExit("Touch instrumentation did not return a valid report; inspect temp/android-touch-checks/instrumentation.txt")
    report = json.loads(report_line)
    report["testApkSha256"] = record["sha256"]
    report["targetSourceSha256AtBuild"] = record["currentTargetSourceSha256"]
    report["recordedAtUtc"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    report["serial"] = args.serial or "adb default device"
    report["targetInstalledPath"] = installed_path
    if args.expect_version and report.get("targetVersion") != args.expect_version:
        raise SystemExit("The instrumentation target version changed during the run")
    (work / "result.json").write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"Touch checks: {report['passed']} passed, {report['failed']} failed, {report['assertions']} assertions")
    print(work / "result.json")
    if report.get("failed") or not report.get("passed"):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
