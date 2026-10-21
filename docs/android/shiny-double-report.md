# Android.5 artificial shiny double battle

2026-10-20, `emulator-5554`, `org.kuray.kif` Android.5/code 5. Payload `16590ec82d1107a4bf628808`. Evidence: `temp/evidence/root-android5/`.

The real double battle rendered four full Pokémon sprites simultaneously, with four red shiny stars. `242-double-current.png` shows the first command menu for GUI SHI 2, enemy Bulbasaur/Charmander Lv12, and friendly GUI SHI 2 Lv16/GUI SHI 3 Lv15. No missing sprite or visual error was observed in that screen. These are artificial QA Pokémon, not naturally encountered shinies.

## Preparation and protection

The deployed fixture was read before use. Its seed runs from the `Game.load` wrapper; its separate double request is checked in `Scene_Map#update`. No seed request was created. The active Android.5 content directory contained neither a seed request nor a double request before arming; it had no seed receipt because the receipt was not migrated across payloads. The shared writable Mods contained the existing fixture and diagnostic Mod.

Real Party → Switch operations moved GUI SHI 2 and GUI SHI 3 into positions 0/1. `204-party-stable.png` captures the original party; `216-party-ordered-stable.png` captures the final order and red stars. The pixel font's digit 6 was initially read as 8 in operator commentary; inert decoding confirms GUI SHI 2 remained Lv16/EXP2535/HP46 and did not grow to Lv18.

The normal Save dialog explicitly selected Save to File E (`219-sort-save-menu.png`), followed by **GUIFixture saved the game.** (`220-sort-save-E.png`). One C dismissed the message (`221-sort-save-dismiss.png`). The stable `222-sorted-stable.tar` contains 25 files. Independent actual-tar hashes match its manifest; compared with the 24-file `120-after-cancel-reopen` baseline, only File E changed, one normal `File E 7 2h 5m Route 1.rxdata` backup was added, and the other 23 files including EBASE5 remained byte-identical. See `222-preservation.json`.

Two inert decoders agreed on the saved party order: SHI 2, SHI 3, NORM 1, ordinary Charmander, NORM 3 (Pidgey), SHI 1. Individual shiny/debug/natural flags were unchanged by personalID against the earlier baseline. SHI 1's stored flags remain `true/null/null`; they were not normalized to false. The other artificial shinies have `shiny=true`, `debug_shiny=true`, `natural_shiny=false`. No member has `natural_shiny=true`. The pre-battle variable 1 was 4. See `222-sorted-decoded.json` and `222-sorted-full-decoded.json`.

## Actual battle and exit

After the successful save, force-stop confirmed the game PID absent (`223-sorted-stopped.json`). The only request written was `files/content/16590ec82d1107a4bf628808/kif-gui-double.request`, containing the exact 27-byte token `ANDROID_GUI_SHINY_FILE_E_V1`; it was read back byte-for-byte (`224-double-request.json`). Normal Launcher cold-started the game as PID29250. The visible File E/GUIFixture/Route1 card with the reordered party was confirmed before Continue (`235-title-current.png`, `236-continue-visible-E.png`).

The actual Yes prompt said **Artificial GUI test fixture: start a shiny double battle?** (`238-double-question-stable.png`, fresh `240-double-question-fresh.png`). One virtual C selected Yes (`241-double-yes.png`). `242-double-current.png` then shows the full four-Pokémon battle and the first Pokémon's command prompt. The state was reached through the deployed fixture's real `pbDoubleWildBattle`; no alternate script entry point, outcome write, or simulated battle result was used.

For the first Pokémon only, Down selected Pokémon (`243-first-command-down.png`), Right selected Run (`244-first-command-run.png`), and one virtual C executed it (`245-run-once.png`). The two-second post-input screenshot captured the black exit transition rather than the transient escape text. `246-after-run-map.png` independently confirms return to the normal Route1 map. No second Pokémon Run/Cancel was selected. The exact **You got away safely!** message was not captured, so it is not claimed as screenshot evidence.

A separate 120-second background recording was started immediately before the real Yes input and subsequently extracted by the root agent as `247-double-entry.mp4`: 6,869,259 bytes, SHA256 `bf84107fd140255ae64e77b14ecb6e38e35e223c9b6f2aa17eb51bff6c2666be`. The original is preserved but was not analyzed frame by frame because no existing video-decoding library was available. No claim about a captured sparkle-animation frame or video-derived FPS is made. The confirmed visual evidence remains the four-sprite/four-red-star PNG. The earlier `239` recording captured waiting at the Yes prompt and must not be cited as a battle recording.

## Samples and handover

The pre-battle cold-start sample `227-cold-current.json` records 7 shiny-cache PNGs totaling 12,401 bytes, with a TAR and each SHA256. `227-cold-current.meminfo.txt` records PSS228,340 KiB at that loading sample. These are sparse samples, not a peak-memory, leak, sustained-FPS or average-FPS result. The full battle screenshot displays 40 FPS; the map after Run displays 15 FPS.

At `246-after-run-map.png`, device ownership was explicitly handed to the root agent for the final normal File E save, stable archive, outcome-1 readback and force-stop before Android.6 installation. This agent made no further ADB call after that handover. The root agent then completed the original Save to File E flow (`250-double-save-options.png`), captured **GUIFixture saved the game.** (`251-double-saved.png`), dismissed the message and returned to the normal map (`252-double-saved-dismiss.png`), and reported successful force-stop before the upgrade work.

## Final saved checkpoint

Independent offline verification of `253-double-final.tar` found 26 actual files, with every size and SHA256 matching `253-double-final.json`. The TAR SHA256 is `fb16ebede91e86f1d857345f7f4d78c5645af142036f0c80470c7fbd761b8d2c`. Relative to the 25-file sorted checkpoint `222`, only File E changed and the ordinary `File E 8 2h 41m Route 1.rxdata` backup was added; the other 24 files were byte-identical, with no file missing. Relative to the original 24-file `120` baseline, only E changed and normal E7/E8 backups were added; all other 23 baseline files were retained exactly. This includes H/G/F, their backups, old EBASE, and EBASE5. See `253-preservation.json`.

| Final record | Bytes | SHA256 |
| --- | ---: | --- |
| File E | 882159 | `182e791c231625cbfdd0ca927cf2c20bd43692efef4e5abb47ca2444af131522` |
| File E 8 2h 41m Route 1 | 882157 | `373cb695184fc9cb76cab09966009d1ab4a8244058b3db0f0d5933e4e1619165` |
| Protected EBASE5 | 882340 | `5bb27e4cc7a66f771182b7ffefdf25994c16443b89264fa38469c551a8ec3cb7` |

The final E export was independently decoded with inert class stubs, without loading game scripts. `254-double-outcome.json` records `Game_Variables.data[1] = 3`, confirming the real Run result was saved. All six Pokémon's inspected party fields exactly match the sorted pre-battle `222` data. Therefore the completed result is PASS for real four-Pokémon shiny rendering, one first-Pokémon Run, return to map, original File E save and protected-save preservation. It does not claim the transient escape-text screenshot or a visually inspected sparkle-animation frame.

No production source, Mod, APK or save bytes were edited directly during this task. No AVD restart, app install, settings change, SAF operation, Windows player-save read, or seed re-run occurred. The fixture and diagnostic Mod remain deployed for the root agent's subsequent Android.6 input check.
