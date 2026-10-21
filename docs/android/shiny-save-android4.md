# Android.4 shiny-save GUI verification

Actual device work on 2026-10-20, emulator-5554, `org.kuray.kif` Android.4/code4 (APK SHA-256 `636ce391a97330d9a8fb0e7135468318b305e45e4babdf356623667afbcc6000`, active payload `4891b2121b1a64fa417082fa`). This is the API30 x86_64 emulator with ARM64 translation, 4KiB pages and 3GiB RAM. Evidence lives in `temp/evidence/shiny-v4`.

The dedicated File E / GUIFixture / Route1 is an **artificial test fixture**, seeded previously through the reviewed Mod. It is not a natural shiny encounter. H had a prior test write and restoration, disclosed in `shiny-save-report.md`; this report uses its restored hash and does not claim H never changed during the earlier test.

## Upgrade read-back

The first fresh image `001-current.png` visibly displayed the selected File E / GUIFixture / Route1 card with five party icons. It followed the root operator's single title C press and a delayed transition; no immediate-transition timing is claimed. `002-before-load-all-saves.tar` captured the 20-file baseline before Continue. The actual visible E card was confirmed once, then `003` captured a black transition and `004-after-load-wait.png` showed Route1. No unseen Continue was sent.

`006-party.png` shows five Lv15 members, the fused GUI SHI1 first, GUI SHI2 and GUI SHI3 with red stars, and GUI NORM1/3 without stars. All five display full HP. This verifies the upgrade read-back of the party. No new Android.4 full box or fused full-size summary check has yet been completed.

## Free-text cancel: recovered after a real KIF ANR

The original Save menu visibly offered **Save to File E**, **Save to another file**, **Name the next backup**, save-folder information and Cancel (`011`). Selecting Name the next backup opened the original empty Backup name field (`012`).

A single real 150ms virtual X at `(1165,210)` was attempted. Its ADB subprocess exceeded the 25-second timeout. `013` still showed the text field. Android then displayed **KIF Android Test isn't responding** (`015`), which names KIF rather than System UI. The operator selected the visible **Wait** action once. `016-after-Wait.png` shows the game recovered to its original Choose a Save Slot menu (Save to File E / Save to another file / Cancel), so the text field eventually exited, with a material ANR and delay. This is not an unqualified input-cancel pass. No C submit, EBASE entry, named backup or save has occurred at this checkpoint.

`017-lastanr.txt` records ANR time 06:32:38 UTC, GameActivity not responding to the X-coordinate MotionEvent DOWN after 5006ms. `014-game-logcat.txt`, `017-logcat-full.txt` and `014-input-diagnostics.txt` preserve the InputDispatcher and CPU context. Android reported `ANR in org.kuray.kif:game`, PID22944. `/data/anr` could be listed; reading the relevant ANR and trace_04/05 files returned Permission denied (`019-*`), and no privilege change was attempted.

The after-ANR archive `018-after-X-ANR-all-saves.tar` and independent `019-preservation.json` establish that **all 20 save/archive files remain byte-identical to the before-load baseline**. H:754867B / `c4e4ae9a47faca16d94c9c84014158b845174f6a7975e46634aaee73b8c23b3b`; G:838923B / `0f6532bb75c41a2bbe96b123e6e4b7047394c6a8cab621b4cef12fc5499a89ca`; F:683515B / `605ee325be6d357cb7ec3d0998aa8a36f60665abe97ca36c65f16bd45f2915a5`; E:883158B / `690768f0bfe5970bfc972d4224e3fc5599806cfe3317188e2f4b159dd5d89c75`.

## Visible IME input and subsequent virtual confirm failure

After recovery, the operator cancelled the save-slot menu, reopened Save and selected Name the next backup again (`021`–`026`). The current `show_ime_with_hard_keyboard` value was read and preserved as **1** (`027`); it was not changed. Pressing the visible Keyboard button exposed an actionable Gboard alphabet keyboard (`028`). The text `EBASE` was entered through normal Android IME input, then Android Back hid the IME. `031` clearly shows the complete five-letter EBASE string.

Two separated real virtual C presses after hiding the IME did not close the text field (`032`–`034`), while the displayed game FPS remained approximately28–31. Reopening the visible IME, pressing C once, and hiding the IME again still left EBASE in the text field (`036`–`038`). A subsequent single virtual X also left the field visible (`039`). Those calls returned normally with no second ANR observed at this stage. Input and C were separated by several seconds, so this observation does not reproduce the separate same-frame final-character issue. No named backup or successful C submit is claimed.

The adapter's `text_virtual_query` requires native `Input.text_input == true`. Hiding the IME may affect that native state, but this remains a source-based hypothesis without runtime-state instrumentation. The current observations establish a real failure of virtual C/X on this route after the IME hide cycle; they do not establish the cause or behavior of a fresh entry that submits while its first IME session stays open.

The ordinary visible Gboard blue Return button was then used (`040`–`041`). This closed the original text field and returned to Choose a Save Slot. The actual **Save to File E** item was visibly selected (`042`) and confirmed once; `043` shows **GUIFixture saved the game.** After dismissing the message and waiting for the backup operation to finish, `045-named-stable-all-saves.tar` contains21 files. Independent comparison (`046-named-preservation.json`) proves that only preexisting E changed and the new named backup was added; all19 other existing files, including H/G/F and every earlier backup, remain identical.

The new E is883164B, SHA `2f8d92064e93a5c9f35ae6cb0da2bde7192403462fa54431a4c145a3e8a94636`. The actual named backup is **File E - EBASE.rxdata**,883163B, SHA `311c3317f212f4d09f707ec0bd2f7771b0be924e5c0017228dba56b888c7b293`. Inert E decoding is retained in `046-E-extended.json`. This verifies real text input and named-backup persistence via the IME Return route; it does not turn the virtual C failure into a pass.

`029-dropbox-data-app-anr.txt`, obtained through the normal dumpsys dropbox interface, preserves the earlier KIF ANR. It includes the main SDLActivity thread name and waiting channels (`wait_on_page_bit_common` then `futex_wait_queue_me`), memory pressure and CPU data, but no usable main-thread call stack. Those samples do not establish an ANR cause. `020-upgrade-preservation.json` also confirms the pre-load20-file manifest exactly matches the root operator's post-install manifest; the inert extended E decoder output is retained in `020-E-baseline-extended.json`.

## Original reverse-fusion UI and saved shiny-side transition

The original Bag displayed12 Splicers and12 Reversers (`049`). The operator used DNA Reverser on the first fused GUI SHI1, confirmed the explicit reverse question (`053`) and allowed the original animation to run. `055`/`056` capture the full transformed fused sprite and the intermediate white rotating silhouette. `058` shows the transformed orange/purple reverse sprite and **GUI SHI1 has been turned into Bulbamander!** The original Pokédex registration and species-info page followed (`059`–`062`); that page is species information, not individual shiny evidence.

The original Save explicitly targeted E (`066`) and reported success (`067`). After dismissing and waiting, `069-reverse-stable-all-saves.tar` contains22 files. Existing-file comparison (`070-reverse-summary.json`) proves only E changed and a normal E4 backup was added; EBASE and every H/G/F/earlier backup remain identical.

Inert decoding `070-reverse-E-extended.json` proves the actual saved transition from B1H4 to **B4H1**, overall shiny/debug true and natural false, **head_shiny=true**, **body_shiny=nil**, head hue90/RGB2,0,1/nine KRS zeros. PersonalID835311203, level15 and EXP2035 remain equal. This establishes reversal of the shiny side, beyond the red star alone. Current E:883411B / `de3bdbc2723f6f45240bfee308c5b91240ee40def4f55fbbc207b5557886097a`; new File E4 backup:883408B / `7be40cb9a72949b1420b13504ce4f1a86c5689d0518e9f9acbe50b6d87d822a0`.

## Original unfusion and Rare Candy evolution

The Bag after reversal visibly displayed Reverser11 (`073`), confirming one consumed item. DNA Splicers was then used on the visible reversed GUI SHI1. The original question **Should GUI SHI1 be unfused?** was confirmed (`076`). The original input-gated Unfusing/ellipsis messages were advanced individually; `081` shows **Your Pokémon were successfully unfused!**, six members, ordinary Charmander in the first position without a red star and GUI SHI1 Bulbasaur in the last position with one. `083` displays11 Splicers and11 Reversers.

The original Medicine pocket displayed12 Rare Candy (`084`). One was used on the visibly selected GUI SHI2 Charmander15 (`087`); `088` says **GUI SHI2 grew to Lv.16!** The normal stat-increase panels followed. `093` shows the transformed golden Charmander and **What? GUI SHI2 is evolving!**, `094` captures the actual white silhouette transition, and `095`/`096` show the transformed orange Charmeleon full sprite with the original evolution congratulations. The actual animation was allowed to complete. The original Pokédex registration/view followed (`097`–`099`); the ordinary species page is not evidence of the individual's shiny flags.

The original Save dialog explicitly targeted E (`103`) and reported success (`104`). The enclosing backup method was allowed to complete before `106-evolution-stable-all-saves.tar` was captured. `107-final-E-extended.json` is an inert decode of this exact archive's E. Both Player clones remain GUIFixture / File E. The saved actual party is:

| Position / display name | Species / Lv | PersonalID | shiny / debug / natural | Hue |
| --- | --- | --- | --- | --- |
|1 / Charmander |CHARMANDER15 |835311203 |false / false / false |90 |
|2 / GUI SHI2 |CHARMELEON16 |2531964575 |true / true / false |-90 |
|3 / GUI NORM1 |BULBASAUR15 |1718496965 |false / false / false |90 |
|4 / GUI SHI3 |SQUIRTLE15 |4086049832 |true / true / false |135 |
|5 / GUI NORM3 |PIDGEY15 |2473579911 |false / false / false |0 |
|6 / GUI SHI1 |BULBASAUR15 |2788567983 |true / nil / nil |90 |

All remain artificial fixture descendants. Nil in the last row means the corresponding ivar is absent, not silently converted to false. The original unfusion code retains the existing object for the body and creates a new head object. Therefore, after reversal and unfusion, the retained original fusion PersonalID835311203 belongs to ordinary Charmander, while the shiny Bulbasaur head has new PersonalID2788567983. This report does **not** claim that the original shiny Bulbasaur's personalID or the pre-fusion ordinary Charmander's personalID survived as their original individual identities. It records the actual original-game behavior without changing it. The resulting shiny side and hue match the saved head-side state before splitting.

GUI SHI2's original PID2531964575, shiny/debug true, natural false, hue-90, RGB2,0,1 and nine zero KRS entries survive evolution; saved EXP is2535, HP46/46. The other three unaffected fixture members retain their PIDs and flags. The final bag is Splicers11 / Reversers11 / Rare Candy11 / Poké Balls14. Independent `109-android4-checkpoint-summary.json` proves the entire decoded box state equals the pre-upgrade E state: Box1 remains30 members/15 shiny flags. No Android.4 full-box GUI rendering result is claimed.

## Closed Android.4 handover checkpoint

The final stable archive contains23 files. Compared with the20-file post-upgrade baseline, only preexisting E changed; the three additions are EBASE, E4 and E5. All19 other original files, including H/G/F and their backups, remain byte-identical. EBASE retains SHA `311c3317f212f4d09f707ec0bd2f7771b0be924e5c0017228dba56b888c7b293`.

Final E:882340B / `b4b640be066dcfb264b2a55261db96b0b67cb0a0e39add02abe73be6af3cf633`. New E5 backup:882336B / `034e37ff9d0da8044a1f4962da355e83603c81c2cd7872d85c6fb2b660251eb3`. `108-before-upgrade-map.png` captures the returned map after save. The self-owned QA app was force-stopped; `108-closed-state.json` confirms prior game PID22944 absent afterward and IME setting still1, matching its original value. The device was explicitly handed back to the root operator for Android.5 work, and this GUI operator made no later device call.

No APK install, AVD restart, game-runtime modification, player-save byte modification, fixture reseed or Windows player-file access was performed during this Android.4 GUI stage. IME settings were never changed. The retained Mod and consumed seed request remain as handed over; no double-battle request was written. Double battle, fixture-free read-back and SAF remain unexecuted at this Android.4 checkpoint. The virtual C/X text failure and recovered KIF ANR above remain failures/limitations, despite the successful IME-Return named backup and original shiny operations.
