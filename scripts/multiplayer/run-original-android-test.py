"""Exercise the production original-role client in an isolated AVD/save root."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time
import uuid

ROOT=Path(__file__).resolve().parents[2]
APP="org.kuray.kif"


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--mode",choices=("resume","interactive","transport"),default="resume")
    parser.add_argument("--serial",default="emulator-5560")
    parser.add_argument("--stage-client",action="store_true")
    args=parser.parse_args()
    adb=[str(ROOT/"temp/tools/android-sdk/platform-tools/adb.exe"),"-s",args.serial]
    def command(*words,check=True):
        return subprocess.run(adb+list(words),capture_output=True,check=check,timeout=90)
    def device(*words):
        return command(*words).stdout.decode("utf-8",errors="replace").strip()
    if device("emu","avd","name").splitlines()[0]!="kif_original_20261023":
        raise RuntimeError("Use the dedicated original-rules AVD")
    record=json.loads(next((ROOT/"temp/original-apk").glob("*-build-record.json")).read_text())
    payload=record["payload"]
    if len(payload)!=24 or any(value not in "0123456789abcdef" for value in payload):
        raise RuntimeError("Invalid recorded payload")
    content=f"/data/user/0/{APP}/files/content/{payload}"
    if command("shell","run-as",APP,"test","-f",content+"/.complete",check=False).returncode:
        raise RuntimeError("Launch this APK and wait for its game-content installation before probing")
    run_id=uuid.uuid4().hex[:10]
    private=f"/data/user/0/{APP}/files/diagnostics/original-{run_id}"
    evidence=ROOT/"temp/multiplayer"/("original-android-"+run_id)
    evidence.mkdir(parents=True)
    command("shell","am","force-stop",APP)
    command("shell","run-as",APP,"mkdir","-p",private,content+"/scripts/multiplayer",content+"/tests/multiplayer")
    backup=content+"/android-game-smoke.rb"
    original=command("exec-out","run-as",APP,"cat",backup).stdout
    (evidence/"original-android-game-smoke.rb").write_bytes(original)
    def push(source,target):
        transfer="/data/local/tmp/kif-original-"+run_id
        command("push",str(source),transfer)
        command("shell","run-as",APP,"cp",transfer,target)
    hashes={}
    for source in sorted((ROOT/"Data/Scripts/054_Multiplayer").glob("*.rb")):
        name=source.relative_to(ROOT).as_posix()
        expected=hashlib.sha256(source.read_bytes()).hexdigest()
        actual=device("shell","run-as",APP,"sha256sum",content+"/"+name).split()[0]
        if actual!=expected and args.stage_client:
            push(source,content+"/"+name)
            actual=device("shell","run-as",APP,"sha256sum",content+"/"+name).split()[0]
        if actual!=expected:
            raise RuntimeError("Installed client differs from current source: "+name)
        hashes[name]=actual
    (evidence/"client-source-hashes.json").write_text(json.dumps(hashes,indent=2),encoding="utf-8")
    for name in ("scripts/multiplayer/test-bootstrap.rb","scripts/multiplayer/runtime-preload.rb","tests/multiplayer/original_resume_game.rb"):
        push(ROOT/name,content+"/"+name)
    env={"KIF_SAVE_DIR":private,"KIF_MULTIPLAYER_SAVE_DIR":private,"KIF_MULTIPLAYER_PROFILE":"original-android-"+run_id,
         "KIF_MULTIPLAYER_SERVER":"http://10.0.2.2:18770","KIF_ORIGINAL_PROBE_MODE":args.mode}
    wrapper=evidence/"entry.rb"
    wrapper.write_text("\n".join("ENV["+json.dumps(key)+"]="+json.dumps(value) for key,value in env.items())+'''
load "kif_android_preload.rb"
module OriginalProbeMods
  def [](*arguments)
    return [] if arguments.first == "Mods/*.rb"
    super
  end
end
Dir.singleton_class.prepend(OriginalProbeMods)
load "tests/multiplayer/original_resume_game.rb"
''',encoding="utf-8")
    push(wrapper,backup)
    print("ORIGINAL_ANDROID_EVIDENCE="+str(evidence),flush=True)
    try:
        command("shell","am","start","-W","-n",APP+"/.LauncherActivity","--ez","gameSmoke","true")
        deadline=time.monotonic()+(600 if args.mode=="interactive" else 300)
        while time.monotonic()<deadline:
            raw=command("exec-out","run-as",APP,"cat",private+"/feature-smoke.log",check=False)
            if raw.returncode==0:
                (evidence/"feature-smoke.log").write_bytes(raw.stdout)
                output=raw.stdout.decode("utf-8",errors="replace")
                if "ORIGINAL_RESUME_FAIL" in output:
                    partial=command("exec-out","run-as",APP,"cat",private+"/truncated-body.bin",check=False)
                    if partial.returncode==0 and not partial.stdout.startswith(b"cat:"):
                        (evidence/"truncated-body.bin").write_bytes(partial.stdout)
                    raise RuntimeError(output[output.index("ORIGINAL_RESUME_FAIL"):])
                if "ORIGINAL_RESUME_PASS" in output:
                    break
            time.sleep(2)
        else:
            raise RuntimeError("Original-role Android probe timed out")
        (evidence/"screen.png").write_bytes(command("exec-out","screencap","-p").stdout)
        result={"mode":args.mode,"serial":args.serial,"apk":record["sha256"],"payload":payload,"emulator_only":True,"staged_client":args.stage_client,
                "physical_device":"unverified by user decision","client_files":len(hashes),"status":"passed"}
        (evidence/"result.json").write_text(json.dumps(result,indent=2),encoding="utf-8")
        print("ORIGINAL_ANDROID_PASS "+args.mode,flush=True)
    finally:
        command("shell","am","force-stop",APP,check=False)
        push(evidence/"original-android-game-smoke.rb",backup)


if __name__=="__main__":
    main()
