# Android.5 real IME device checks

Tested 2026-10-20 on `emulator-5554`, running `org.kuray.kif` Android.5/code 5, PID 27030. Build identity supplied by the parent test session: payload `16590ec82d1107a4bf628808`; APK SHA-256 `01f37fa99f2a06628528851621705ecda5ec8426163d224c3342b61ce666c728`.

## Results

| Check | Result | Evidence |
| --- | --- | --- |
| Enter `CANCEL5` using visible Gboard, hide IME with Android Back, then one virtual X | PASS: actual field displayed `CANCEL5`; virtual X left the text field and opened the three-item Choose a Save Slot menu. Explicit Cancel then virtual C returned to the normal pause menu. | `107-cancel5-field.png`, `108-cancel5-virtual-x.png`, `109-cancel5-select-exit.png`, `110-cancel5-exit.png` |
| Enter `R5`, hide IME, reopen with Keyboard, enter `Z`, hide IME and inspect actual field | FAIL: field was `R5` before reopening and remained `R5` afterward; it did not become `R5Z`. Gboard was visibly open for the `Z` command, which completed successfully. | `117-r5-field.png`, `118-reopen-keyboard.png`, `119-reopen-z-ime.png`, `121-reopen-final-field.png` |
| Cancel the second test and leave safely | PASS: one virtual X returned to Choose a Save Slot; explicit Cancel then virtual C returned to the normal pause menu, with Save selected. | `122-reopen-cancel-x.png`, `123-reopen-select-cancel.png`, `124-reopen-exit-safe.png` |

Evidence files are under `temp/evidence/root-android5/`. `actions.jsonl` records the commands and host timestamps. All navigation used actual ADB touch taps; text used `adb shell input text` only while Gboard was visible. Android Back only hid visible IME. The native blue Return key was never used.

## Diagnostics and preservation

`111-cancel5-log.txt` / `125-final-log.txt` contain `KIF_TEXT_MODE_DIAG` entries for both cancellation edges:

```text
10-20 07:53:12.164 ... edge c=false b=true native_mode=false return=false escape=true
10-20 07:58:05.796 ... edge c=false b=true native_mode=false return=false escape=true
```

The second field was canceled without submitting its text or saving. No new code, Mod, APK, device restart, data reset, or setting change was applied. No Windows player save was read. No ADB command exceeded the existing 25-second timeout in these checks; no ANR was observed during them.

The final read-only archive `120-after-cancel-reopen.tar` and its hash manifest were captured after both cancellations. Comparing `120-after-cancel-reopen.json` against `030-EBASE5-stable.json` found the same 24 files, identical byte counts and SHA-256 hashes, with no added, removed, or changed file. Existing E, EBASE5, other slots, and backups therefore remained byte-identical to that baseline.

The device was handed back running on the visible normal pause menu shown in `124-reopen-exit-safe.png`. These were manual QA fixture checks and are not evidence of a naturally encountered shiny.
