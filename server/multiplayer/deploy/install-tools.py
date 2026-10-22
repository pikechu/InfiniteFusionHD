"""Explicit future-host tool installation; no services, DNS or certificates."""
import bz2
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import sys
import tarfile
import urllib.request


def main():
    if sys.platform != "linux" or os.geteuid() != 0:
        raise SystemExit("Run this explicit tool installer as root on the future Linux server")
    arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(platform.machine())
    lock = json.loads(Path(__file__).with_name("tools.lock.json").read_text())
    if arch not in lock["platforms"]:
        raise SystemExit("Unsupported server architecture")
    target = Path("/opt/kif-mmo/tools")
    target.mkdir(parents=True, exist_ok=True, mode=0o755)
    if target.resolve() != target:
        raise SystemExit("Tool installation root must not redirect through symlinks")
    target.parent.chmod(0o755)
    target.chmod(0o755)
    for name, tool in lock["platforms"][arch].items():
        if not tool["url"].startswith("https://github.com/"):
            raise SystemExit("Unexpected tool distribution URL")
        with urllib.request.urlopen(tool["url"], timeout=120) as response:
            if not response.url.startswith("https://"):
                raise SystemExit("Tool download did not remain HTTPS")
            data = response.read(80 * 1024 * 1024 + 1)
        if len(data) > 80 * 1024 * 1024 or hashlib.new(tool["algorithm"], data).hexdigest() != tool["checksum"]:
            raise SystemExit("Official tool checksum mismatch: " + name)
        if name == "restic":
            binary = bz2.decompress(data)
        else:
            with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
                member = archive.getmember("caddy")
                if not member.isfile() or member.size > 100 * 1024 * 1024:
                    raise SystemExit("Unexpected Caddy archive member")
                binary = archive.extractfile(member).read()
        machine = 62 if arch == "amd64" else 183
        if binary[:5] != b"\x7fELF\x02" or int.from_bytes(binary[18:20], "little") != machine:
            raise SystemExit("Tool is not the expected Linux ELF architecture")
        pending = target / (name + ".pending")
        descriptor = os.open(pending, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o755)
        with os.fdopen(descriptor, "wb") as file:
            file.write(binary)
            file.flush()
            os.fsync(file.fileno())
        pending.chmod(0o755)
        os.replace(pending, target / name)
        (target / (name + "-provenance.json")).write_text(json.dumps({**tool, "binary_sha256": hashlib.sha256(binary).hexdigest()}, indent=2))
        print(name + " " + tool["version"] + " verified and installed into the isolated KIF tools directory")


if __name__ == "__main__":
    main()
