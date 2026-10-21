"""Pinned, emulator-only workaround for an old ARM native translator.

The original scalar AdvSIMD instructions are legal AArch64. This script does
not repair bad ARM code, rebuild mkxp-z, or modify the phone/runtime inputs.
It rewrites exactly two fixed eight-byte conversion pairs in one SHA-pinned
published library, after assembler, ELF, register and direct-branch audits.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import struct
import subprocess
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
INPUT_SHA256 = "6f90fabcb227eafa2a5b3a8967dbe34368cec06efab5cd3e709f538003186232"
RUNTIME_COMMIT = "68653811c3c396f2d4c12225c52c407746285a3d"
OLD_PAIR = bytes.fromhex("21b8a15e21d8215e")
NEW_PAIR = bytes.fromhex("3000381e0102221e")
SITES = (
    (0x12946C, "_ZN6Sprite4setXEi", 0x12A42C, 0xBC),
    (0x12951C, "_ZN6Sprite4setYEi", 0x12A4E8, 0xE0),
)


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def run(program, *arguments):
    result = subprocess.run([str(program), *(str(x) for x in arguments)], check=True,
                            capture_output=True, text=True, encoding="utf-8", errors="strict")
    return result.stdout


def elf_metadata(data):
    require(data[:6] == b"\x7fELF\x02\x01", "Expected little-endian ELF64")
    header = struct.unpack_from("<16sHHIQQQIHHHHHH", data)
    require(header[2] == 183, "Expected an AArch64 ELF")
    programs = [struct.unpack_from("<IIQQQQQQ", data, header[5] + i * header[9])
                for i in range(header[10])]
    sections = [struct.unpack_from("<IIQQQQIIQQ", data, header[6] + i * header[11])
                for i in range(header[12])]
    names_section = sections[header[13]]
    names = data[names_section[4]:names_section[4] + names_section[5]]

    def string(table, offset):
        return table[offset:table.index(b"\0", offset)].decode("ascii")

    named_sections = {string(names, section[0]): section for section in sections}
    symbols = {}
    dynamic = named_sections[".dynsym"]
    strings_section = sections[dynamic[6]]
    strings = data[strings_section[4]:strings_section[4] + strings_section[5]]
    for offset in range(dynamic[4], dynamic[4] + dynamic[5], dynamic[9]):
        name, _info, _other, _index, value, size = struct.unpack_from("<IBBHQQ", data, offset)
        if name:
            symbols[string(strings, name)] = (value, size)
    return programs, named_sections, symbols


def file_to_vma(programs, offset):
    matches = [segment for segment in programs
               if segment[0] == 1 and segment[1] & 1
               and segment[2] <= offset < segment[2] + segment[5]]
    require(len(matches) == 1, f"Patch offset {offset:#x} is not in exactly one executable LOAD")
    segment = matches[0]
    return segment[3] + offset - segment[2]


def instructions(disassembly):
    pattern = r"^\s*([0-9a-fA-F]+):\s+(?:[0-9a-fA-F]{2}\s+){4}\s*([.a-zA-Z0-9_]+)\s*(.*)$"
    return [(int(match[1], 16), match[2], match[3]) for line in disassembly.splitlines()
            if (match := re.match(pattern, line))]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=ROOT / "temp/android-generated/jniLibs/arm64-v8a/libmkxp-z.so")
    parser.add_argument("--output", type=Path, default=ROOT / "temp/android-emulator-native/arm64-v8a/libmkxp-z.so")
    parser.add_argument("--ndk", type=Path, default=ROOT / "temp/tools/android-ndk-r25c")
    args = parser.parse_args()
    source, output = args.input.resolve(), args.output.resolve()
    emulator_root = (ROOT / "temp/android-emulator-native").resolve()
    require(output.is_relative_to(emulator_root) and output.name == "libmkxp-z.so",
            "Output must be the dedicated temp/android-emulator-native variant, never the phone jniLibs")
    require(output != source, "Refusing to overwrite the original runtime")
    original = source.read_bytes()
    require(sha256(original) == INPUT_SHA256, "Original runtime SHA-256 mismatch; no patch applied")
    properties = (args.ndk / "source.properties").read_text()
    require(re.search(r"(?m)^Pkg\.Revision\s*=\s*25\.2\.9519653\s*$", properties), "Use the pinned Windows NDK r25c")
    tools = args.ndk / "toolchains/llvm/prebuilt/windows-x86_64/bin"
    clang, objdump, objcopy = (tools / name for name in ("clang.exe", "llvm-objdump.exe", "llvm-objcopy.exe"))
    programs, sections, symbols = elf_metadata(original)
    text = sections[".text"]
    opcode_sites = [offset for offset in range(text[4], text[4] + text[5], 4)
                    if struct.unpack_from("<I", original, offset)[0] & 0xFFFFFC00 == 0x5EA1B800]
    require(opcode_sites == [site[0] for site in SITES], "Unexpected scalar SIMD32 FCVTZS inventory")

    output.parent.mkdir(parents=True, exist_ok=True)
    audit = emulator_root / "audit"
    audit.mkdir(exist_ok=True)
    assembly = ROOT / "android/native/emulator-coordinate-replacement.S"
    object_file, fragment = audit / "replacement.o", audit / "replacement.bin"
    run(clang, "--target=aarch64-linux-android30", "-c", assembly, "-o", object_file)
    run(objcopy, "--only-section=.text", "-O", "binary", object_file, fragment)
    assembled = fragment.read_bytes()
    require(assembled == NEW_PAIR, f"Unexpected assembled replacement bytes: {assembled.hex()}")
    fragment_disassembly = run(objdump, "-d", object_file)
    require([(mnemonic, re.sub(r"\s+", "", operands)) for _, mnemonic, operands in instructions(fragment_disassembly)]
            == [("fcvtzs", "w16,s1"), ("scvtf", "s1,w16")], "Replacement disassembly mismatch")
    (audit / "replacement-disassembly.txt").write_text(fragment_disassembly, encoding="utf-8")

    all_disassembly = run(objdump, "-d", "--section=.text", source)
    decoded = instructions(all_disassembly)
    require(len(decoded) > 1000, "Original disassembly was not parsed")
    second_instructions = {file_to_vma(programs, site[0]) + 4 for site in SITES}
    for address, mnemonic, operands in decoded:
        if mnemonic in {"b", "bl", "cbz", "cbnz", "tbz", "tbnz"} or mnemonic.startswith("b."):
            branch = re.search(r"(?:^|,\s*)(0x[0-9a-fA-F]+)\s*(?:<|$)", operands)
            require(not branch or int(branch[1], 16) not in second_instructions,
                    f"Direct control flow enters the second replaced instruction at {address:#x}")

    patches = []
    for offset, name, expected_start, expected_size in SITES:
        require(symbols.get(name) == (expected_start, expected_size), f"Function symbol changed: {name}")
        address = file_to_vma(programs, offset)
        require(expected_start <= address and address + 8 <= expected_start + expected_size, "Patch outside its function")
        require(original[offset:offset + 8] == OLD_PAIR, f"Original bytes changed at {offset:#x}")
        function = [line for line in decoded if expected_start <= line[0] < expected_start + expected_size]
        require(len(function) == expected_size // 4, f"Incomplete function audit for {name}")
        require(not any(re.search(r"\b[wx]16\b", operands) for _, _, operands in function),
                f"x16/w16 has an existing live use in {name}; refusing scratch-register patch")
        before = run(objdump, "-d", f"--start-address={expected_start}", f"--stop-address={expected_start + expected_size}", source)
        (audit / f"{name}-before.txt").write_text(before, encoding="utf-8")
        patches.append({"fileOffset": offset, "virtualAddress": address, "function": name,
                        "functionStart": expected_start, "functionSize": expected_size,
                        "originalHex": OLD_PAIR.hex(), "replacementHex": NEW_PAIR.hex(),
                        "originalX16References": 0})

    patched = bytearray(original)
    for patch in patches:
        offset = patch["fileOffset"]
        patched[offset:offset + 8] = assembled
    changed = [index for index, pair in enumerate(zip(original, patched)) if pair[0] != pair[1]]
    require(changed == [offset + index for offset, *_ in SITES for index in range(8)], "Unexpected bytes changed")
    require(sha256(source.read_bytes()) == INPUT_SHA256, "Original runtime changed concurrently")
    pending = output.with_suffix(".so.pending")
    pending.write_bytes(patched)
    pending.replace(output)
    after_disassembly = run(objdump, "-d", f"--start-address={SITES[0][2]}",
                            f"--stop-address={SITES[-1][2] + SITES[-1][3]}", output)
    (audit / "sprite-setters-after.txt").write_text(after_disassembly, encoding="utf-8")
    after_instructions = {address: (mnemonic, re.sub(r"\s+", "", operands))
                          for address, mnemonic, operands in instructions(after_disassembly)}
    for patch in patches:
        require(after_instructions.get(patch["virtualAddress"]) == ("fcvtzs", "w16,s1"), "Patched FCVTZS mismatch")
        require(after_instructions.get(patch["virtualAddress"] + 4) == ("scvtf", "s1,w16"), "Patched SCVTF mismatch")
    provenance = {"schemaVersion": 1, "variant": "emulator-only-old-arm-native-translation",
                  "runtimeCommit": RUNTIME_COMMIT, "nativeRuntimeRebuiltFromSource": False,
                  "originalInstructionIsLegalAArch64": True, "scratchRegister": "w16/x16 (AAPCS64 IP0 caller-saved)",
                  "inputSha256": INPUT_SHA256, "outputSha256": sha256(patched),
                  "input": str(source), "output": str(output), "fileSizeUnchanged": len(original),
                  "changedByteCount": len(changed), "patches": patches,
                  "assembler": run(clang, "--version").strip(), "assemblySourceSha256": sha256(assembly.read_bytes()),
                  "directBranchIntoSecondInstruction": False,
                  "usage": "Emulator translation compatibility only. Ordinary ARM phone APKs must use the original runtime.",
                  "runtimeValidation": "Not performed by this script; install/run and gameplay checks remain required."}
    (emulator_root / "emulator-runtime-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"output": str(output), "sha256": provenance["outputSha256"],
                      "changedBytes": len(changed), "variant": provenance["variant"]}, indent=2))


if __name__ == "__main__":
    main()
