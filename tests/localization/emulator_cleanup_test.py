"""An occupied private ADB port must leave the other test session untouched."""
import importlib.util
from pathlib import Path
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('emulator_qa', ROOT/'scripts/android/run_localization_emulator_tests.py')
qa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qa)
with tempfile.TemporaryDirectory(prefix='emulator-cleanup-test-', dir=ROOT/'temp') as name:
    directory = Path(name)
    assert directory.resolve().is_relative_to(ROOT.resolve())
    state = directory/'state'
    (state/'tmp').mkdir(parents=True)
    marker, log = state/'active-run.json', state/'tmp/adb.log'
    marker.write_text('other active session', encoding='utf-8')
    log.write_text('other session log', encoding='utf-8')
    with patch.object(qa, 'QA', state), patch.object(qa, 'OUT', directory/'evidence'), \
         patch.object(qa, 'free', return_value=False), patch.object(qa, 'adb') as adb, \
         patch.object(qa, 'command') as command, patch('sys.argv', ['qa', 'ui']):
        assert qa.main() == 1
        adb.assert_not_called()
        command.assert_not_called()
        assert marker.read_text(encoding='utf-8') == 'other active session'
        assert log.read_text(encoding='utf-8') == 'other session log'
print('PASS: an occupied ADB port preserves other processes, markers and logs; temporary fixtures removed')
