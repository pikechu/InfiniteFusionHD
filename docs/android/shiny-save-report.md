# Android.3 shiny / save GUI regression

2026-10-20. Candidate: `org.kuray.kif`, version `0.20.7-android.3` / code3, APK SHA256 `c3a70ecd1eb05edfb0dd8356b798d74c6f3967b19fb14513c2b2b7aa9ca966fa`, payload `d5767c74f758589212589b2a`.

Scope: emulator-5554, Android11/API30 x86_64 with ARM translation and 4KiB pages. This is not a physical-device or 16KiB result. Evidence belongs to `temp/evidence/shiny-v3/`. Only the AVD QA saves are in scope; no Windows player save is accessed.

## Offline preparation / handover

The prior ordinary G loop, font checks, Android.3 upgrade/readback, and F fresh-character path are documented in [the existing GUI report](gui-regression-report.md). E was already created through the original Save-to GUI, independently decoded with both Player clones bound to File E. No shiny fixture had been deployed at the handover.

The reviewed fixture `temp/android-gui-fixture.rb` requires Android, File E, an existing E save, and the exact one-use token `ANDROID_GUI_SHINY_FILE_E_V1`. It constructs artificial test inputs: six Lv15 party members (three shiny and three ordinary), full Box1 (30 members,15 shiny), and supplies. It saves E through `Game.save`, protects H bytes, and renames the request to a receipt. Its separate double-battle request is outside this first checkpoint. Ruby syntax checks of the fixture and host guard script both returned `Syntax OK`; no runtime/GUI PASS is implied by those checks.

The first checkpoint will perform actual party/summary and full-Box1 UI rendering, preserve cache/memory/timing observations, then close the game before handover. All fixture Pokémon are explicitly artificial and are not evidence of naturally obtaining shiny Pokémon.

Latest existing E-created exports before device ownership:

| Slot | Bytes | SHA256 |
| --- | ---: | --- |
| H |754867 | `c4e4ae9a47faca16d94c9c84014158b845174f6a7975e46634aaee73b8c23b3b` |
| G |838923 | `0f6532bb75c41a2bbe96b123e6e4b7047394c6a8cab621b4cef12fc5499a89ca` |
| F |683515 | `605ee325be6d357cb7ec3d0998aa8a36f60665abe97ca36c65f16bd45f2915a5` |
| E |838928 | `c8c15058ab83aa655a1d8b147763b2855850a45ab20c609405fc95f4d19414a7` |

F's earlier first-save export had SHA `b8a3ddda6241a2c3665903727ea33f7a6b71098f424df352a3d88676fa6e3930`. The latest existing E-created F export differs, while the read-only decoder's inspected fields remain identical: AF, both clones File F, Map69(8,9) facing up, empty party,3000 money. A full inert structural comparison found only five semantic changes: frame_count17129→17199, game_system.save_count19→20, variables.data[226]362→140, picture3 angle185→357.5, and global_metadata.newFrameCount9600→9669. This establishes a subsequent save; it does not establish which exact earlier UI action caused it. The root agent accepted605ee as the latest F baseline. This report does not claim F remained byte-identical between those older checkpoints. No restoration was attempted. See `F-at-E-created-decoded.json`, `F-existing-export-diff.json`, and `F-structural-diff.json`.

H had an earlier test-operation write and authorized QA restoration, fully preserved and disclosed in the prior GUI report. Its original restored hash is the baseline above; this report does not claim H was unchanged throughout the whole earlier test.

No device call was made during the offline preparation. The root agent then explicitly returned5554 after stopping its separate native probe; the GUI work below began after that handover.

## First milestone: actual execution

**PASS for the executed artificial E seed, six-member party, shiny/ordinary summary, full Box1, cache reuse, and original File E save checkpoint.** No fusion, split, evolution, double battle, SAF or fixture-free cold read is claimed here.

At13:25 local, `:game` and the separate native `:probe` PIDs were absent. `001-before-fixture-all-saves.tar` preserves all18 files from saves/backups. H/G/F/E match the latest baselines above; Mods and Cache were empty. Only the reviewed4641-byte Mod (SHA `d52761e06fdd06b5a76e222c9957b2d120dbc1b479f92d7be4c6c5fb809377a3`) and exact request were deployed. The normal Launcher cold-started game PID19365. No APK installation, alternate script entry point or AVD change was used.

The real File E/QA/Route1 card was visibly selected before Continue (`012-E-continue-selected.png`). At05:28:49.969 UTC /13:28:49 local, the game logged `KIF_GUI_FIXTURE_SEEDED slot=FileE artificial=true party=6 shinies=3 box=30 shiny_box=15`; the request became `.used`. Independent inert decoding of the seeded E export confirms both Player clones `GUIFixture`/File E, party species/names/levels, three `shiny=true`/`debug_shiny=true`, all `natural_shiny=false`, and Box1 count30/shiny flags15. Seeded E:878411 bytes, SHA `0f7afb1900bfaecb7daadb0f3e018d1ff286145be71a72d8af6399e6b5700471`.

| Real UI check | Actual result | Evidence |
| --- | --- | --- |
| Six-member party | All six Lv15 names and HP readable; exactly GUI SHI1/2/3 have red stars, ordinary1/2/3 do not. | `017-first-party-2.png` |
| Shiny summary | GUI SHI1 Bulbasaur shows the artificial transformed brown/orange/purple sprite and red star; no missing sprite. | `022-first-shiny-summary-after-wait.png` |
| Same-species ordinary summary | GUI NORM1 Bulbasaur shows its ordinary cyan/green sprite and no red star. | `026-first-normal-summary-5.png` |
| Cached shiny summary reopening | Same transformed sprite and star; cache bytes/hash unchanged. | `029-cached-shiny-summary-1.png`, `030-cached-shiny-summary-cache-hashes.json` |
| Full Box1 | The actual storage screen displays30 occupied positions in a6×5 grid, Party6, and the selected GUI BOX1 transformed purple/blue full sprite with red star. Decoding independently establishes15 shiny members; the screenshot alone does not establish every member's flags. | `035-first-full-box-after-wait.png` |
| Cached full-box reopening | Same30 positions and selected shiny full sprite; cache bytes/hashes unchanged. No Pokémon was stored, moved, withdrawn or released. | `038-cached-full-box-5.png` |
| Original Save | The complete original dialog explicitly says **Save to File E**; the successful message says **GUIFixture saved the game.** | `043-save-E-complete-question.png`, `044-E-saved-real-UI.png` |

## Observed timing, memory and cache

Each timing sequence starts before a real150ms virtual-button press and uses ADB screenshot polling. These are coarse observed bounds including ADB and host scheduling, not renderer-only benchmarks. The cold sequences were black in their early samples and were captured again after a wait; the gap was not continuously sampled. Therefore33.85s/35.87s below are times by which a visible image was captured, not exact cold generation durations.

| Screen | Last black sample | Captured visible image | Screenshot FPS | Game PSS / RSS (KiB) |
| --- | ---: | ---: | ---: | ---: |
| First party |1.42s |2.58s (complete brightness) |13 |630550 /752836 |
| First shiny summary |4.81s |by33.85s |24 |690453 /812872 |
| Ordinary summary |1.69s |2.19s |30 (later full image) |665416 /787600 |
| Cached shiny summary |1.91s |2.45s |19 |664164 /786412 |
| First full Box1 |3.98s |by35.87s |23 |673573 /795820 |
| Cached full Box1 |2.47s |3.08s (visible during fade),4.52s full brightness |13 (later full image) |671785 /794032 |

Memory is from `dumpsys meminfo 19365`, the actual `org.kuray.kif:game` PID. Every FPS value is the single screenshot's displayed instantaneous value; no average/minimum FPS or sustained-memory claim is made. Baseline map/pause after seed was PSS633442/RSS755440KiB. The inspected summary sample rose to PSS690453KiB, then later samples fell; these sparse snapshots do not establish peak memory or a leak result.

The party-icon screen left Cache empty. First full-size shiny summary created one1466-byte PNG, `b_1j_270_2_0_1_0_0_0_0_0_0_0_0_0.png`, SHA `6a42ef0ef87052afc5cdc43c80d60f5ed86aa85eb64693c2e5a8f08ea6cdc5b8`. Its ordinary comparison created no additional shiny cache. First full-box view added one1461-byte PNG, `b_1j_180_2_0_1_0_0_0_0_0_0_0_0_0.png`, SHA `debc1f9c00a9362e1f4b35b8d5773316feb6b2829d647274479b46ccee49ffe4`. Total cache after this checkpoint:2 files/2927 bytes. Both warm reopenings preserved the applicable files byte-for-byte. Cache TARs and full size/SHA manifests are saved in evidence. This validates the selected full-size previews and30 box icons; it does not mean all15 shiny full sprites were individually generated or rendered simultaneously.

Actual black game-content frames occurred on title→load, first shiny summary, and first box entry. Offline PIL checks of the game-content crop show one color/zero nonblack pixels for those black PNGs, so these files are not merely a black preview-tool artifact. Later summary/box PNGs contain1474/1616 colors. The title→load region remained black across repeated captures; one safe X input revealed the E card. A subsequent Up wrapped the selection to Quit, then Down visibly returned to E before Continue; Quit was never confirmed. Logcat includes `KIF Android download write failed (ArgumentError)` during the earlier title→load period. That log plus the captured black frames is preserved; no cause is inferred, and no success input was sent to an unseen save card.

## Closed safety checkpoint

Final original-UI E save:878529 bytes, SHA `e744cc6040cfc37f44f32b9cba765238f8f7109c9de9b9bd37b781b9b723e124`. Its newly generated normal backup `File E 1 1h 27m Route 1.rxdata`:878530 bytes, SHA `cfaaee7f3ac3cf57d601ddc0ec83a6e670ba519638d49387163352585e863e1d`.

`045-final-all-saves.tar` preserves all19 final files. Offline manifest comparison proves only the preexisting File E changed, and only the named E backup was added; every other preexisting save/archive file, including H/G/F and all their older backups, is byte-identical to the start. Independent final E decoding confirms both Player clones remain GUIFixture/File E, and all party and box records equal the seeded snapshot after the real UI save.

The main app was force-stopped after the completed save; `046-stopped-state.json` confirms `:game` PID absent. The reviewed Mod remains deployed, with its seed request consumed into `.used`; there is no double-battle request. This is a stopped checkpoint awaiting the next assigned stage. It is not yet a fixture-free cold-read result. No device call occurred after the root agent was told the device could be taken back.

Evidence index: `actions.jsonl` records real inputs; `014-seeded-decoded.json`/`045-final-E-decoded.json` preserve independent state inspection; `*-timing.json`, `*-meminfo.txt`, cache TAR/manifests, and `046-game19365-logcat.txt` preserve raw observations. `checkpoint-summary.json` and `offline-summary.py` independently assert save preservation, exact party/box equality, cache reuse and real PNG color statistics.

## Second stage: named-backup attempt

The root agent authorized continued exclusive device use after the first checkpoint, including actual fusion/reverse/split/evolution/double battle. Early E and its normal E1 backup above remain the recovery baseline.

Normal Launcher cold-started PID20804 at13:38:26. InputReady was05:38:33 UTC; a visible normal title was captured at13:40:15 (about109s after launch). The earlier LOADING/0FPS state had a live~96.8% CPU Ruby thread; it was not treated as a crash or bypassed with gameplay input. File E/GUIFixture's six-party card was visibly selected at13:41 before Continue.

**Named-backup input is blocked on this tested input route.** The actual Save→Name the next backup opens the original empty free-text box (`062-backup-text-entry.png`), not the Mobile cursor keyboard. The visible Android Keyboard button was pressed twice. Input-method diagnostics show `mInputShown=true`, `mShowRequested=true`, and an active SDL DummyEdit/InputConnection, but no actionable alphabet keyboard appeared (`063`–`065`); only the small system input-method icon/down arrow became visible. Touching the icon did not expose a usable keyboard. No EBASE text or success result was injected.

Offline source inspection confirms this entry calls `pbMessageFreeText`→`pbFreeText` directly, creating `Window_TextEntry_Keyboard` and accepting only `Input.triggerex?(:ESCAPE/:RETURN)`; it bypasses the Mobile `pbEnterText` cursor route. Evidence is limited to this emulator/input configuration, not every physical keyboard/IME. Logs and full IME state are preserved in `066-name-backup-*`.

The root agent's preauthorized fallback was used: preserve the automatic early E backup, force-stop the self-owned test app from this blocked screen, and cold-start normally. `066-named-backup-blocked-all-saves.tar` plus exact manifest comparison proves all19 save/archive files remained byte-identical to the first checkpoint. There was no new backup and no E overwrite from this attempt. The system keyboard configuration was not modified.

After that restart, screenshot067 displayed an Android **System UI isn't responding** dialog. This names System UI, not KIF. The visible **Wait** action dismissed it (`068-system-ui-wait.png`); normal startup later reached the movie/title. This environmental ANR limits the IME conclusion above. The original `show_ime_with_hard_keyboard` setting was read into `071-ime-hard-keyboard-original.txt`; it was not changed.

Following the System UI/IME transition, the navigation circle dimmed from255 white to153 gray while the system bars remained visible. The test helper's older white-circle detector misclassified this one title frame as immersive, so its intended C hit the displayed Back(X) button and left the title unchanged (`071`). The helper was corrected to identify the two observed black-navigation-strip pixels in a fresh screenshot, checked against both stored immersive and barred frames. The next correct C reached the visible E card (`072`); no unseen Continue, save or gameplay action occurred during this coordinate correction. Earlier first-milestone navigation circles were white and its actual selections are shown in the retained screenshots.

## Mixed shiny/ordinary fusion on Android.3

**PASS for the actual mixed fusion and saved body-side shiny state.** This continued on Android.3; the reverse/split/evolution/double-battle steps had not yet been performed when the root agent requested a safe upgrade checkpoint.

Actual Bag displayed DNA Splicers13 and DNA Reverser12 (`076`). The fixture added12 to the original ordinary G supplies, so this is intentionally13 Splicers and14 Poké Balls rather than replacing those inventories with12. Rare Candy was12.

The original Splicer Use UI selected **GUI SHI1** (artificial shiny Bulbasaur) and **GUI NORM2** (ordinary Charmander), shown in `078`–`080`. The two-orientation screen was entered, and the **right** Fire/Poison orientation was explicitly selected (`083-fusion-B1H4-right-selected.png`). The confirmation names both input Pokémon (`084`). The original fusion prompt and animation completed; `088-mixed-fusion-current.png` shows the transformed blue/purple fused sprite and **Congratulations! ... fused into Charsaur!** The original Pokédex registration/view ran (`089`–`091`); it is species info, not evidence of the individual's shiny state. The original traits menu retained GUI SHI1, Overgrow and Adamant; the real moveset menu selected Keep Bulbasaur's moveset. `097` shows the resulting five-member party with the fused member and red star.

The early fusion message is input-gated. Its30s initial stillness was a test operator waiting at the original prompt, not animation duration or a frozen-game result; a single C advanced it and the original animation then finished. No C+X shortcut or synthetic result was used.

The original Save dialog explicitly showed File E (`100-mixed-Save-E-dialog.png`), and its successful message is visible in `101`. The test then dismissed that message and waited for the enclosing backup method to finish before taking the stable checkpoint. The earlier `102` archive was captured before the new backup existed and is not the final all-backups checkpoint; `104-mixed-stable-all-saves.tar` is the stable20-file checkpoint.

Independent inert extended decoding of the stable E export establishes:

| Field | Saved actual value |
| --- | --- |
| Both Player clones |GUIFixture / File E |
| Fused species / level / EXP |B1H4 /15 /2035 |
| Original individual's personalID |835311203, retained |
| Overall shiny / debug / natural |true / true / false |
| body_shiny |true |
| head_shiny |ivar absent, read as nil; not silently converted to false |
| Body hue / R,G,B / KRS |90 /2,0,1 /nine zeros |
| Overall hue / R,G,B / KRS |90 /2,0,1 /nine zeros |
| Fused head/body initial EXP, gained |2035 /2035 /0 |
| Splicers / Reversers / Rare Candy / Balls |12 /12 /12 /14 |

This matches the original mechanism: species `B<body>H<head>`, numeric dex/body*501+head, gives B1H4/505 for Bulbasaur body and Charmander head. The fusion code records the shiny input on the appropriate side and sets overall shiny. A single red star alone cannot establish which side is shiny; the stored fields above do. No shiny-rule or balance code was changed. See `104-mixed-stable-E-extended.json` and `104-mixed-transition-summary.json`.

Closed upgrade checkpoint: E883158 bytes, SHA `690768f0bfe5970bfc972d4224e3fc5599806cfe3317188e2f4b159dd5d89c75`. New normal E2 backup883163 bytes, SHA `3071cc1b2d9f784808ebe5b29bfcf2141d5798fff32c829093681129bb693484`. The earlier e744 main-file export and cfaa E1 backup remain preserved; the latter was also extracted to `early-E1-unfused.rxdata.export`, rehashed and independently decoded. Stable manifest comparison proves only E changed and E2 was added; H/G/F and every previous backup remain byte-identical.

The app was force-stopped, and `105-mixed-closed-state.json` confirms no game PID. The sampled /data availability was797612KiB (`105-before-upgrade-df.txt`). The root agent was explicitly handed5554 for authorized old-resource capacity cleanup and Android.4 installation. The GUI agent made no further device call after this handover. The existing Mod/request receipt remain as before; no double request has been written.
