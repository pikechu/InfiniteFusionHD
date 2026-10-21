"""Native Windows substitute for the pinned upstream xxd-include.sh host tool.

Emit the same C byte arrays without requiring a POSIX shell in Meson's Ninja
commands. This is build-time code generation, not a target/runtime patch.
"""
import argparse
import pathlib
import re
import sys


def include(symbol: str, data: bytes) -> str:
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", symbol, flags=re.ASCII):
        raise ValueError("Expected a C identifier")
    lines = [f"unsigned char {symbol}[] = {{"]
    for offset in range(0, len(data), 12):
        chunk = data[offset:offset + 12]
        line = "  " + ", ".join(f"0x{byte:02x}" for byte in chunk)
        if offset + 12 < len(data):
            line += ","
        lines.append(line)
    lines += ["};", f"unsigned int {symbol}_len = {len(data)};"]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xxd", action="store_true", help="Unused upstream tool discovery compatibility")
    parser.add_argument("--include", action="store_true")
    parser.add_argument("arguments", nargs="*")
    args = parser.parse_args()
    if args.xxd and args.arguments in ([], ["-v"], ["--version"]):
        print("KIF Python C-include generator; replaces xxd-include.sh at build time")
        return
    if not args.include or len(args.arguments) != 2:
        parser.error("Use --include SYMBOL INFILE")
    symbol, filename = args.arguments
    # Preserve LF bytes under native Windows stdout; Meson captures these as a C include.
    sys.stdout.buffer.write(include(symbol, pathlib.Path(filename).read_bytes()).encode("ascii"))


if __name__ == "__main__":
    main()
