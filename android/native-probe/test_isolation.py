"""Host-only regression for the gate protecting the installed game application.

No Android tools, native compiler, APK installation, or target execution.
"""
import copy
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/android"))
import build_native_probe as builder


def main():
    fixture = builder.FIXTURE
    base = ET.parse(fixture / "AndroidManifest.xml")
    results = []
    cases = [
        ("wrong-application-id", lambda r: r.set("package", "org.kuray.kif")),
        ("shared-uid", lambda r: r.set(builder.ANDROID + "sharedUserId", "org.kuray.kif")),
        ("relative-activity", lambda r: r.find("application/activity").set(builder.ANDROID + "name", ".NativeProbeLauncherActivity")),
        ("exported-native-activity", lambda r: r.findall("application/activity")[1].set(builder.ANDROID + "exported", "true")),
        ("wrong-native-process", lambda r: r.findall("application/activity")[1].set(builder.ANDROID + "process", "org.kuray.kif")),
        ("internet-permission", lambda r: ET.SubElement(r, "uses-permission", {builder.ANDROID + "name": "android.permission.INTERNET"})),
        ("storage-permission", lambda r: ET.SubElement(r, "uses-permission", {builder.ANDROID + "name": "android.permission.MANAGE_EXTERNAL_STORAGE"})),
        ("provider", lambda r: ET.SubElement(r.find("application"), "provider")),
        ("service", lambda r: ET.SubElement(r.find("application"), "service")),
        ("backup-enabled", lambda r: r.find("application").set(builder.ANDROID + "allowBackup", "true")),
        ("wrong-label", lambda r: r.find("application").set(builder.ANDROID + "label", "KIF Android Test")),
    ]
    try:
        for name, action in cases:
            path = builder.OUTPUT / "isolation-checks" / name
            path.mkdir(parents=True, exist_ok=True)
            tree = copy.deepcopy(base)
            action(tree.getroot())
            tree.write(path / "AndroidManifest.xml", encoding="utf-8", xml_declaration=True)
            builder.FIXTURE = path
            try:
                builder.manifest_safety()
            except ValueError as error:
                results.append({"case": name, "rejected": True, "reason": str(error)})
            else:
                raise AssertionError("Unsafe manifest accepted: " + name)
    finally:
        builder.FIXTURE = fixture
    assert builder.manifest_safety()["applicationId"] == "org.kuray.kif.nativeprobe"
    record = {"validFixtureAccepted": True, "unsafeCasesRejected": len(results), "tests": results,
              "hostOnly": True, "targetExecuted": False, "deviceCommandsInvoked": False}
    builder.write_json(builder.OUTPUT / "isolation-checks/result.json", record)
    print(f"Host-only isolation regression passed: valid fixture + {len(results)} unsafe cases")


if __name__ == "__main__":
    main()
