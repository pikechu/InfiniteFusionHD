# Android.2 GUI regression execution

2026-10-20, emulator-5554, Android 11/API30 x86_64 with ARM64 translation. This is an emulator GUI result; it is not a physical-device or 16 KiB compatibility result. App identity is `org.kuray.kif` `0.20.7-android.2` / code2.

Screenshots `01` through `26` below used candidate SHA256 `b8e19919adc12542391444ce750f3df9a4854d42ff9a19969aa013fe6665e2c7`, 742,762,733 bytes. Root subsequently built final candidate SHA256 `7279c3e35af7707bee71d2d003aad1c77ba3476a3a39741e4fa40841f4d95c73`, same byte size, payload `8c26905a7f60a78cc202278e`; installation/startup of that candidate is currently owned by the root task. Later evidence must explicitly record the handover and final candidate.

Evidence directory: `temp/evidence/gui-v2/`. All interaction uses the displayed Java virtual buttons with `input swipe x y x y 150`; no raw Android keyevents or injected gameplay success values. A fresh screenshot at the start showed system bars and C at `(1081,210)`.

## Executed so far

| Check | Actual result | Evidence |
| --- | --- | --- |
| Title fusion-wait stage, one C | PASS for this stage: screenshot02 shows the white fusion silhouette; one 150ms C entered the normal load menu. No confirm burst was used. | `02-current.png`, `03-fusion-phase-single-C.png`, `04-after-single-C.png` |
| Existing H Continue | Loaded the normal QA save at Viridian PokéMart entrance. | `08-H-loaded.png` |
| Real Save-to G | PASS: Save → Save to another file → visibly empty File G → save completion. G is exported for independent read-only slot verification. | `13-save-dialog-stable.png`, `14-save-another-file.png`, `15-empty-G-selected.png`, `16-G-saved.png` |

## Test-operation incident and preservation

H was intended to remain a read-only baseline. An operator error occurred: a screenshot taken after the first Save confirm still showed the preceding pause menu. A second C then selected the default **Save to File H**, and the next screenshot displayed “QA saved the game.” This is not a game defect and **H did not remain unchanged throughout the test**.

The root task was informed immediately. It authorized restoration limited to this self-created AVD QA slot from the existing pre-upgrade byte backup, after preserving all current data and creating G through the real UI. No Windows player save was accessed. Current saves, including the mistaken H write and new H7 backup, were exported intact to `saves-after-G-before-H-restore.tar`, individual `pre-restore-*` files, and a size/SHA manifest. No backup was deleted.

- Original H: 754,867 bytes, SHA256 `c4e4ae9a47faca16d94c9c84014158b845174f6a7975e46634aaee73b8c23b3b`; the pre-upgrade TAR's original bytes were independently rehashed and match.
- Mistaken saved H: 754,908 bytes, SHA256 `72c20471b5fe51e91257c8b5611e4475f7fd25fa95bff2edead3143448a966ae`.
- Real Save-to G: 754,920 bytes, SHA256 `f5fa15b43777af9e210b1e4b4e3f8c6c2bbca0f9599c52a61b9c1223bfcda4e8`.
- The mistaken H SHA remained unchanged across the subsequent real Save-to G operation.

Independent read-only Marshal decoding by the root task confirmed `player.name=QA`, `save_slot=File G`, and the three original party members. The input hash was unchanged by decoding; see `FileG-slot-verification.json`.

The game was then force-stopped and `:game` PID absence verified. Only the dedicated QA H file was restored from the pre-upgrade original bytes; the restored file matches the source byte-for-byte and SHA256 `c4e4ae9a47faca16d94c9c84014158b845174f6a7975e46634aaee73b8c23b3b`. G remained exactly `f5fa15b43777af9e210b1e4b4e3f8c6c2bbca0f9599c52a61b9c1223bfcda4e8`. See `H-restoration-checkpoint.json`. All mistaken-write files/backups remain preserved. The device is stopped at this safe checkpoint for the root task's final candidate installation.

Default font menu and a real two-line option description are visibly readable (`22-font-default-options.png`, `23-default-multiline.png`). FR/LG was actually selected and changed the menu font (`24-font-FRLG-options.png`), but the existing description window retained its old font until recreated; therefore `25-FRLG-multiline.png` is **not** counted as FR/LG multiline-body validation. The follow-up will exit and re-enter after each font change.

## Final candidate handover and real font verification

Root installed final `7279c3e35af7707bee71d2d003aad1c77ba3476a3a39741e4fa40841f4d95c73`, completed payload installation, and explicitly returned emulator-5554. The diagnostic game process was force-stopped, then normal Launcher cold-started PID9445. `Mods` was empty. Package inspection confirms code2 / `0.20.7-android.2`, ARM64. A read-only export after upgrade still matched restored H and G exactly (`final-before-G-save-hashes.json`). Normal File G card was visible in screenshot34; Continue restored the same Viridian location in screenshot36.

The real Options → KIF Settings → Graphics menu was used. Default, FR/LG, D/P and R/B each displayed the complete two-line description “Pokémon icons will use their full-size battle / sprites (except in boxes)” with intact glyph bottoms, accents and parentheses. After each font change, Graphics was exited and re-entered so the white description window was recreated with the newly selected font. These are real game windows, not the diagnostic font probe.

| Font | Actual GUI result | Evidence |
| --- | --- | --- |
| Default | PASS for inspected menu labels/title and two-line body | `41-final-default-multiline.png` |
| FR/LG | PASS after window recreation | `42-final-FRLG-selected.png`, `43-final-FRLG-multiline-rebuilt.png` |
| D/P | PASS after window recreation | `44-final-DP-selected.png`, `45-final-DP-multiline-rebuilt.png` |
| R/B | PASS after window recreation | `46-final-RB-selected.png`, `47-final-RB-multiline-rebuilt.png` |

Scope: this establishes the four fonts in the inspected real menu/body windows. The dense Type Display choice row still overlaps horizontally; no claim that every layout is flawless. Repeated ADB screencaps also sometimes show a black game region while controls/FPS remain visible, as in the prior report. A C sent during one such black frame reached the load menu, but its title phase was not visible and is **not counted** as the moving-stage single-C test.

Second visible title phase and remaining gameplay/transfer checks are pending; no PASS is claimed for them yet.

## Natural G gameplay continuation on final candidate

No fixture or Mod has been deployed. G's original three ordinary Pokémon and supplies are the starting state. H was rehashed after the font checks and remains at the restored original SHA; G's disk bytes remained unchanged until a later explicit save.

| Check | Actual result | Evidence |
| --- | --- | --- |
| Original Heal action and party UI | Real Heal Pokémon action completed. Party names/levels and HP are completely readable: Hoothoot3 16/16, Pidgey5 19/19, Charmander8 24/24. This is an intentional heal, not an exact-HP readback claim. | `51-G-heal-message.png`, `52-G-party-readable.png` |
| Map movement/entry | Actual Up movement entered PokéMart, then walked up to the counter. | `53-G-field-before-movement.png`, `55-G-Mart-current.png`, `56-G-Mart-counter.png` |
| Natural supply purchase | Bought 2 Poké Balls for400 and 2 DNA Splicers for600 through Buy/quantity/Yes. Money changed2480→2080→1480; Bag displayed 3 Splicers afterward. | `59-G-ball-buy-confirm.png`, `60-G-ball-purchased.png`, `61-G-splicers-buy-confirm.png`, `62-G-splicers-purchased.png`, `64-G-bag-splicers.png` |
| Ordinary fusion | Used actual Splicer on Pidgey and Charmander, selected visible Chargey orientation, confirmed, completed animation, selected Blaze and combined moves. Scratch/Growl learned; real party now Hoothoot3 and Chargey7 22/22. | `68-G-fusion-orientation.png`, `69-G-fusion-confirm.png`, `73-G-fusion-current.png`, `75-G-fusion-ability.png`, `76-G-fusion-traits-confirm.png` (actually the moveset menu), `77-G-fusion-moves.png`, `78-G-fusion-next-move.png`, `79-G-fusion-next-step.png`, `80-G-fused-party.png` |

Filenames describe capture intent; the table corrects any capture that actually shows the following screen. Saving the fusion snapshot, storage, split, wild/capture and cold readback remain in progress.

Continuation:

- Original Save dialog explicitly showed **Save to File G** (`82-G-save-dialog.png`). Export `fusion-File G.rxdata.export` is698,035 bytes, SHA256 `ccb9c658e6dfe1a3b738b37fc17e04c6b79060062584ee8f5d4db438d8653c92`. Read-only stub decoding confirmed File G,1480 money, Hoothoot3 + fused B16H4/Chargey7,2 Splicers, Map81(6,8) facing up. H remains its restored original hash. Screenshot83 is already back on the map after the successful save; it is not a still-visible save-message screenshot.
- Real PC Store into Box2 completed: `87-G-storage-fusion-menu.png`, `88-G-storage-destination.png`, `90-G-fusion-box-visible.png` show Chargey in Box2 and Party1. Real Withdraw completed: `91-G-withdraw-menu.png`, `92-G-fusion-withdrawn.png` show the emptied box/Party2; `93-G-withdraw-party-proof.png` shows Hoothoot and Chargey back in the party.
- Used a real Splicer to split Chargey (`96-G-unfusion-confirm.png`); processed the original messages and reached “Your Pokémon were successfully unfused!” (`100-G-unfusion-complete.png`). `101-G-unfused-party.png` shows Hoothoot3/Pidgey5/Charmander8.
- Walked from Mart through Viridian to the northern Route1 grass without changing position/state through scripts (`105`–`116`). A natural male Rattata appears with HUD Lv3 (`116-G-grass-return.png`); Hoothoot used actual Tackle (`119-G-first-Tackle.png`). First Poké Ball failed (`123-G-ball-throw.png`); after a second Tackle, the second Poké Ball caught it (`129-G-second-ball-result.png`, `130-G-capture-current.png`). Hoothoot took real battle damage to3/16. Waiting-party EXP and Pokédex registration messages followed. Capture UI completion, saved result and cold readback are still in progress.

Capture completed through the original Pokédex and nickname prompt (No). `133-G-capture-Dex-view.png` shows the complete four-line real Pokédex paragraph without bottom glyph loss; `138-G-four-party.png` shows all four ordinary Pokémon. The final original Save dialog explicitly says File G (`139-G-final-save-dialog.png`), and `140-G-final-save-result.png` shows “QA saved the game.”

Final pre-cold export `pre-cold-File G.rxdata.export`:838,923 bytes, SHA256 `0f6532bb75c41a2bbe96b123e6e4b7047394c6a8cab621b4cef12fc5499a89ca`. Read-only decoding confirmed:

- File G, QA,1480 money; one Splicer and two Poké Balls (three after purchase, minus one fusion/minus one split; four balls after purchase, minus two throws).
- Hoothoot Lv3 HP3/16; Pidgey Lv5 HP19/19; Charmander Lv8 HP26/26; newly caught Rattata Lv3 HP4/15. Here the Rattata saved level matches its encounter HUD Lv3. All storage boxes are empty after withdrawal.
- Route1 position(15,10), facing up. MapFactory contains the adjacent Viridian map as well as the Route1 map; active-map selection is decoded separately.
- H remains its restored original SHA256 `c4e4ae9a47faca16d94c9c84014158b845174f6a7975e46634aaee73b8c23b3b`.

After the save completed, old PID9445 was force-stopped; `pidof org.kuray.kif:game` returned no PID. Normal Launcher COLD started the next game PID14688. Cold readback is in progress; no successful readback is claimed yet.

## Completed natural G cold-read loop on7279

PASS for the executed loop: normal map movement → natural supply purchase → real ordinary fusion → Box2 Store/Withdraw → real split → natural wild battle/Tackle → failed ball → successful second-ball capture → original File G save → force-stop → normal cold read of G.

- Moving-title single C: `147-G-visible-moving-before-single-C.png` clearly shows Cloyster and Hoothoot separated at the two screen edges, before fusion. A screenshot-pixel detector waited for outlines in the two outer sprite regions, saved the exact triggering frame, and sent exactly one real150ms C at `(1081,210)` (12:21:27 local). Human review of the saved frame confirms the intended moving stage. `149-G-after-single-C-current.png` / `150-G-load-after-single-C.png` show normal File G/Route1 with the four-party card. No Ruby hook or confirm burst was used. `title-moving-single-C-samples.json` contains samples and the single action.
- Continue restored the original Route1 grass location and up-facing sprite (`152-G-cold-readback-current.png`, `153-G-cold-map.png`). Active map decoded as78, MapFactory active index1, position(15,10).
- The real party screen after cold read (`155-G-cold-four-party.png`) contains the same four species/levels and exact saved HP: Hoothoot3 3/16; Pidgey5 19/19; Charmander8 26/26; Rattata3 4/15. No Heal action was selected after this cold read.
- G raw SHA remained exactly `0f6532bb75c41a2bbe96b123e6e4b7047394c6a8cab621b4cef12fc5499a89ca` after Continue and again after opening the party. H still exactly matches the restored original `c4e4ae9a47faca16d94c9c84014158b845174f6a7975e46634aaee73b8c23b3b`. Evidence: `post-cold-continue-save-hashes.json`, `post-cold-party-save-hashes.json`.

The root task found a separate rename/import slot-binding risk before SAF testing and produced Android.3. No E fixture/SAF work has occurred on7279. Next stage upgrades at this safe G checkpoint; F/E/SAF will use the later candidate and be reported separately. Free space before upgrade:1.8GiB; no old content generation has yet been deleted.

## Android.3 upgrade checkpoint

The root task supplied Android.3/code3, APK SHA256 `c3a70ecd1eb05edfb0dd8356b798d74c6f3967b19fb14513c2b2b7aa9ca966fa`,742,762,733 bytes, payload `d5767c74f758589212589b2a`. Its change binds both in-memory player clones to the actually selected manual slot before loading, so an imported E backup renamed D cannot save back into E. This risk was found before testing the import route; no old-package workaround was used.

Before upgrading, all AVD saves were preserved in `saves-pre-upgrade-android3.tar` (9,815,040 bytes, SHA256 `3eaee8aed2143e2b07db1606ae9de02d5cdc1803d1fc07b3dd06f5703d3173d2`). A redundant host full-APK hash stalled under heavy host disk IO; the owned command was interrupted with Ctrl+C before install started. Root had already hashed the signed output and confirmed no later mutation. Installation used its adjacent `.sha256`, matching length/mtime, without a second concurrent installer. Root observed disk queue38 and only about2.26MB/s reads; installation/loading duration under this host pressure is not a phone benchmark.

The real `adb install --no-incremental -r` returned Success. Package inspection confirms versionCode3, `0.20.7-android.3`, ARM64. H and latest G raw bytes match their pre-upgrade SHA exactly after installation (`after-install-android3-save-hashes.json`). Free space still1.8GiB; no content generation or save directory was deleted. Normal Launcher COLD started new payload preparation (`156-android3-launch-installing.png`); `.complete`, normal native startup and G readback are pending at this point.

The new payload then completed933/933MiB restoration and “Preserving downloaded and customized sprites…” (`157`–`159`). The actual `d5767c74f758589212589b2a/.complete` marker exists (24 bytes), and normal game PID15260 started `SDL_main`/`libmkxp-z` at04:32:52 UTC and `KIF_ANDROID_INPUT_READY` at04:32:56. Installation/preservation took about4m28s from04:28:23 to04:32:51 under the noted host IO pressure. No old generation was removed; remaining space874MiB.

PASS for Android.3 normal G readback: `168-android3-current.png` restores the same Route1 position/facing; `170-android3-G-party-readback.png` shows all four species/levels and exact HP unchanged. H and G disk SHA still match after this read (`android3-G-loaded-save-hashes.json`). Four-font A/B was not redundantly repeated for this slot-binding-only change. F new-game work begins from this verified checkpoint.

## F fresh character and cursor save on Android.3

PASS for the actual New Game→Classic→cursor name→role confirmation→story→empty F first save path. The real Mobile cursor screen accepted **AF** using C for A, direction keys to F, C, Z to OK, then C. The complete name and alphabet are visible (`185-F-cursor-name-AF.png`, `189-F-AF-entered-final.png`); application confirmation shows AF (`190-F-application-confirm-question.png`). Reopening the name editor starts empty; an empty acceptance produced the original default Red, then AF was re-entered before final role confirmation. This was a corrected test operation, not a failed save or a claimed port defect.

Regular starters were retained and Autosave set No through the actual prompts. Original Silph commercial and story ran to AF's Room. First Save selected visibly empty **File F** (`211-F-first-save-slots.png`, `212-F-empty-slot-selected.png`) and completed **“AF saved the game.”** (`213-F-first-save-result.png`).

Read-only F export:683,515 bytes, SHA256 `b8a3ddda6241a2c3665903727ea33f7a6b71098f424df352a3d88676fa6e3930`. Decoder confirms `name=AF`, `player.save_slot=File F`, `kuray_player.save_slot=File F`, Map69(8,9) facing up, empty party. H and natural G remain byte-identical to their established hashes. See `F-created-save-hashes.json`, `F-created-decoded.json`.

The independent-APK notice did **not** appear on this existing-save New Game route. Root's separate read-only event audit found the original condition: Map295 Intro command21 sets switch972 from `SaveData.exists?`; command24 calls CE96 when true, and only command27's else path calls CE108. Since G exists, skipping CE108 here is expected. This is neither a notice PASS nor evidence that the replacement failed. The empty-QA-save-directory initial route remains to be tested later without changing source or switches.
