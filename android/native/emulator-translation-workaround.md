# Emulator-only scalar conversion workaround

This is a narrowly scoped workaround for the older Android 11 x86_64
`libndk_translation.so` used in the verification AVD. The publisher's
`fcvtzs s1, s1` instruction is **legal AArch64**. The problem is the observed
translator support gap, not invalid ARM machine code. Ordinary ARM phone APKs
must keep using the original runtime.

`scripts/android/patch_emulator_runtime.py` only accepts
`libmkxp-z.so` SHA-256
`6f90fabcb227eafa2a5b3a8967dbe34368cec06efab5cd3e709f538003186232`.
It checks the original instructions, ELF file/VMA mapping, exact function
boundaries, scratch-register use, opcode inventory and direct branch targets
before producing a separate file beneath `temp/android-emulator-native`.
It never writes to the original `android-generated/jniLibs` library.

| Site | File offset | Virtual address | Function |
| --- | --- | --- | --- |
| X setter's Y-coordinate roundtrip | `0x12946c` | `0x12a46c` | `Sprite::setX(int) + 0x40` |
| Y setter's X-coordinate roundtrip | `0x12951c` | `0x12a51c` | `Sprite::setY(int) + 0x34` |

Each original eight-byte pair is `21b8a15e21d8215e`:

```asm
fcvtzs s1, s1
scvtf  s1, s1
```

NDK r25c's actual assembler and disassembler confirm the replacement bytes
`3000381e0102221e`:

```asm
fcvtzs w16, s1
scvtf  s1, w16
```

Both routes perform the same signed 32-bit conversion towards zero and convert
that integer back to single precision. The final stored `s1` value is preserved.
The two complete functions (188 and 224 bytes) contain no original `w16`/`x16`
references. Neither has direct control flow entering the second instruction of
either rewritten pair. AAPCS64 permits IP0/x16 as a caller-saved temporary;
the X setter's return and Y setter's optional tail call do not require its
incoming value. See the [Arm procedure-call specification](https://github.com/ARM-software/abi-aa/blob/main/aapcs64/aapcs64.rst#611general-purpose-registers).
The original eight-byte layout is retained, so branch offsets, stack unwind
metadata and symbol addresses are unchanged.
The original embedded ELF build-id is also retained because this is not a
relink. Identify the variant by its output SHA-256 and provenance, not build-id
alone.

Generated patched SHA-256:
`90bee3c7406d62ca903ffb64798bca3f6da009e4b94402a580cb37a8f7ae0d23`.
Exactly 16 bytes change. Audit disassembly and provenance are written to
`temp/android-emulator-native`. An altered input and an output pointing at the
original shared library were both tested and rejected.

Build the explicitly selected variant from the development checkout root:

```powershell
& '<Python 3.11+>' scripts/android/patch_emulator_runtime.py --ndk temp/tools/android-ndk-r25c
& '<Python 3.11+>' scripts/android/build_apk.py --emulator-compatible
# After build_bridge.ps1, optional safe HTTPS support:
& '<Python 3.11+>' scripts/android/build_apk.py --emulator-compatible --with-network
```

The full-game artifacts are named `KIF-0.20.7-android.1-arm64-emulator-test.apk`
and `KIF-0.20.7-android.1-arm64-emulator-network-test.apk`. Build directories,
APKs, checksums and build records are separate from ordinary phone builds.
The builder requires the exact original and patched hashes above plus matching
provenance, substitutes only `lib/arm64-v8a/libmkxp-z.so`, and verifies that
entry's hash in the signed APK. Missing or changed inputs fail before staging
assets; there is no silent fallback. `emulatorOnly`, original/patched hashes,
the source-patch checksum and the full audit provenance are recorded.
`--runtime-only` produces a diagnostic APK without the game; combining all
three flags gives `KIF-network-probe-arm64-emulator-test.apk`, leaving the
ordinary network probe untouched.

Packaging verification completed with `--runtime-only --with-network
--emulator-compatible`: the 25,868,525-byte diagnostic APK passed Android
signature verification, with APK SHA-256
`857f8bf8fc00486a85dc2a8e051434b40f08461dc61257212ada8e3bee96d60c`.
All 22 packaged native library entries were compared with their generated
inputs; only the designated mkxp library differs. The shared original library
and existing ordinary network probe retained their recorded hashes. Six
negative checks rejected missing/altered patched libraries, malformed/mismatched
provenance, a changed original, and an emulator library placed in the ordinary
input location. Artifact and guard evidence is saved in
`temp/android-emulator-native/apk-variant-verification.json` and
`build-flag-validation.json`. These are build checks; no device was operated
for this packaging verification.

## Future source-build candidate

`emulator-coordinate-source.patch` targets the pinned runtime's
`src/display/sprite.cpp`. It enables an explicitly opt-in
`KIF_ANDROID_EMULATOR_GPR_CONVERSIONS` path in the two setters. The inline-assembly
helper uses compiler-managed general-purpose scratch allocation rather than
assuming x16 is free in a newly compiled binary. A simple C++ float→int→float
cast is insufficient as a workaround: the optimizer can select the same scalar
SIMD instructions again.

The helper in `emulator-coordinate-roundtrip.h` was compiled separately with the
Windows NDK and disassembled to check that it emits GPR conversion instructions.
The full runtime source patch has **not** been built or run. The byte-patched
published library is also **not** a full native runtime source rebuild.
Application startup, Intro/title transitions and game acceptance must be checked
with the emulator-specific APK before claiming the workaround succeeds at runtime.

This patch does not change the runtime's 4 KiB ELF alignment or establish
16 KiB-device support. Keep the ordinary phone APK and emulator APK separately
named and record which library SHA each one contains.
