"""Verify the host tools that are actually executed against fixed archives."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import zipfile

MESON_ENTRY = b'from mesonbuild.mesonmain import main\nraise SystemExit(main())\n'


def quarantine_bytecode(directory, destination):
    directory, destination = Path(directory).resolve(), Path(destination).resolve()
    if destination.is_relative_to(directory) or directory == destination:
        raise ValueError('Bytecode quarantine must be outside the executed tool directory')
    moved = 0
    for parent, directories, _ in os.walk(directory, followlinks=False):
        if '__pycache__' not in directories:
            continue
        source = Path(parent) / '__pycache__'
        if source.is_symlink() or not source.resolve().is_relative_to(directory):
            raise ValueError('Bytecode path escaped the Meson cache')
        target = destination / source.relative_to(directory)
        if not target.resolve().is_relative_to(destination):
            raise ValueError('Bytecode quarantine target escaped its directory')
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            raise ValueError('Bytecode quarantine target already exists')
        shutil.move(str(source), str(target))
        directories.remove('__pycache__')
        moved += 1
    return moved


def verify_meson(archive, directory, digest):
    archive, directory = Path(archive), Path(directory).resolve()
    if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
        raise ValueError('Meson wheel differs from fixed archive SHA256')
    expected = set()
    with zipfile.ZipFile(archive) as wheel:
        for item in wheel.infolist():
            if item.is_dir():
                continue
            relative = Path(item.filename)
            if relative.is_absolute() or '..' in relative.parts:
                raise ValueError('Invalid wheel path')
            path = directory / relative
            if not path.resolve().is_relative_to(directory):
                raise ValueError('Meson cache link escaped its directory')
            if path.read_bytes() != wheel.read(item):
                raise ValueError(f'Meson cache differs from verified wheel: {item.filename}')
            expected.add(relative.as_posix())
    if (directory / 'meson.py').read_bytes() != MESON_ENTRY:
        raise ValueError('Generated Meson entry point differs')
    expected.add('meson.py')
    actual = {path.relative_to(directory).as_posix() for path in directory.rglob('*') if path.is_file()}
    if actual != expected:
        raise ValueError('Unexpected files in Meson cache; use a fresh temp tool directory')
    return len(expected)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('directory', type=Path)
    parser.add_argument('sha256')
    parser.add_argument('--quarantine-bytecode', type=Path)
    args = parser.parse_args()
    if args.quarantine_bytecode:
        print(f'Preserved {quarantine_bytecode(args.directory, args.quarantine_bytecode)} bytecode cache directories outside the executed tool cache')
    print(f'PASS: {verify_meson(args.archive, args.directory, args.sha256)} executed Meson cache files match the fixed wheel')
