"""Compare the production Python generator with the real pinned POSIX helper."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--git-bin', type=Path, required=True)
parser.add_argument('--source', type=Path, default=ROOT / 'temp/windows-native/sources/mkxp-z')
args, unittest_arguments = parser.parse_known_args()
spec = importlib.util.spec_from_file_location('codegen', ROOT / 'scripts/android/windows_native_codegen.py')
codegen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(codegen)


class GeneratorTests(unittest.TestCase):
    def test_real_upstream_equivalence(self):
        commit = subprocess.check_output(['git', '-C', str(args.source), 'rev-parse', 'HEAD'], text=True).strip()
        self.assertEqual(commit, '68653811c3c396f2d4c12225c52c407746285a3d')
        inputs = [('length-' + str(length), bytes(range(256))[:length]) for length in (0, 1, 11, 12, 13, 24, 25, 255, 256)]
        for path in sorted((args.source / 'shader').iterdir()):
            if path.suffix in ('.frag', '.vert') or path.name == 'common.h':
                inputs.append(('shader/' + path.name, path.read_bytes()))
        for name in ('icon.png', 'gamecontrollerdb.txt', 'liberation.ttf'):
            inputs.append(('assets/' + name, (args.source / 'assets' / name).read_bytes()))
        with tempfile.TemporaryDirectory(prefix='codegen comparison ', dir=ROOT / 'temp') as directory:
            work = Path(directory)
            for index, (_, data) in enumerate(inputs):
                (work / f'case{index:03}.bin').write_bytes(data)
            shell = work / 'compare.sh'
            shell.write_text('set -eu\nfor path in "$1"/case*.bin; do\n  "$2" ___verified_input "$path" > "$path.c"\ndone\n', encoding='ascii', newline='\n')
            env = dict(os.environ, PATH=str(args.git_bin) + os.pathsep + os.environ['PATH'])
            subprocess.run([str(args.git_bin / 'sh.exe'), str(shell), str(work), str(args.source / 'xxd-include.sh')], env=env, check=True, capture_output=True)
            for index, (name, data) in enumerate(inputs):
                with self.subTest(source=name):
                    expected = (work / f'case{index:03}.bin.c').read_bytes().replace(b'\r\n', b'\n')
                    self.assertEqual(codegen.include('___verified_input', data).encode('ascii'), expected)
            result = dict(upstreamCommit=commit, comparedInputs=len(inputs), allByteIdentical=True,
                          sources=[name for name, _ in inputs], shell=str(args.git_bin / 'sh.exe'),
                          status='pass', targetExecuted=False)
            output = ROOT / 'temp/core-tools/codegen-validation.json'
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
            print(f'PASS: {len(inputs)} real upstream include outputs are byte-identical', flush=True)

    def test_invalid_c_identifiers(self):
        for value in ('', '1name', 'has space', 'x;evil', 'é', 'x\n'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                codegen.include(value, b'a')


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]] + unittest_arguments)
