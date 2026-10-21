"""Apply Meson's normal ELF install RPATH cleanup to a separate Android copy."""
import hashlib
import importlib
from pathlib import Path
import shutil
import struct
import sys


def package_core(source, destination, meson_directory):
    source, destination = Path(source), Path(destination)
    if source.resolve() == destination.resolve():
        raise ValueError('Preserve the raw linked core; package a separate copy')
    before = source.read_bytes()
    if before[:6] != b'\x7fELF\x02\x01' or struct.unpack_from('<H', before, 18)[0] != 183:
        raise ValueError('Expected ELF64 little-endian AArch64')
    section_offset = struct.unpack_from('<Q', before, 40)[0]
    entry_size, count = struct.unpack_from('<HH', before, 58)
    dynamic = []
    for index in range(count):
        section = struct.unpack_from('<IIQQQQIIQQ', before, section_offset + entry_size * index)
        if section[1] == 6:  # SHT_DYNAMIC
            dynamic.append((section[4], section[5]))
    if len(dynamic) != 1:
        raise ValueError('Expected exactly one ELF dynamic section')
    offset, size = dynamic[0]
    if offset + size > len(before):
        raise ValueError('Invalid ELF dynamic bounds')
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    sys.path.insert(0, str(meson_directory))
    try:
        depfixer = importlib.import_module('mesonbuild.scripts.depfixer')
        with depfixer.Elf(str(destination), verbose=False) as elf:
            old_paths = [value for value in (elf.get_rpath(), elf.get_runpath()) if value]
        removals = {part.encode('utf-8') for value in old_paths for part in value.split(':')}
        depfixer.fix_elf(str(destination), removals, b'', verbose=False)
        with depfixer.Elf(str(destination), verbose=False) as elf:
            if elf.get_rpath() is not None or elf.get_runpath() is not None:
                raise ValueError('Meson cleanup left an ELF runtime search path')
        tool = Path(depfixer.__file__)
    finally:
        sys.path.pop(0)
    after = destination.read_bytes()
    if len(after) != len(before) or after[:offset] != before[:offset] or after[offset+size:] != before[offset+size:]:
        raise ValueError('ELF packaging changed bytes outside .dynamic')
    digest = lambda data: hashlib.sha256(data).hexdigest()
    return dict(method='Meson 1.9.1 depfixer.fix_elf install cleanup',
                rawPath=str(source), rawSha256=digest(before), packagedSha256=digest(after),
                removedSearchPaths=old_paths, codeAndAllNonDynamicBytesUnchanged=True,
                dynamicOffset=offset, dynamicBytes=size,
                depfixerPath=str(tool), depfixerSha256=digest(tool.read_bytes()))
