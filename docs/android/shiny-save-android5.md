# Android.5 actual GUI verification

This report records actual emulator-5554 execution on2026-10-20. The installed build is `org.kuray.kif` Android.5/code5, emulator APK SHA `01f37fa99f2a06628528851621705ecda5ec8426163d224c3342b61ce666c728`, new payload `16590ec82d1107a4bf628808`, source commit `7538320d`. The matching physical-phone APK SHA is `a1cab78124b9ca0ae48cf2659417184d4b54976b865d839dd7554a25baa75887`; the root build records both packages742766829B with identical sources/payload. No physical-phone run is claimed here. Evidence is in `temp/evidence/shiny-v5`.

The File E / GUIFixture / Route1 party and full Box1 are artificial QA fixture descendants. H's prior historical test write/restoration is disclosed in earlier reports; its restored sentinel hash remains the protection baseline. Android.4 results remain frozen in `shiny-save-android4.md`.

The root operator installed Android.5 and preserved all23 save/archive files from the Android.4 closed checkpoint. It also intentionally interrupted the initial resource extraction before `.complete`, preserving the old active identity and QA files; its raw records are under `temp/evidence/upgrade-android5`. At this GUI operator's first fresh image (`001-current.png`), normal resumed extraction was visibly at748/933MiB. The new `.complete` did not yet exist and active still named the prior payload (`001-resources-state.txt`). No recovery completion, title/read-back or focused-input success is claimed at this initial checkpoint.

The only retained loaded QA Mods at handover are the original reviewed `android-gui-fixture.rb` and the root's2397B read-only text diagnostic `zzz_android_text_mode_diag.rb`, SHA `deaabb6ecfdb1f48790e188ad460c638be2da8337cd56ae48de6807fe05bcfe8`. The diagnostic logs text setter/key edges without consuming text or polling native input. The old seed request is consumed and there is no double request. No new seed or diagnostic-input value injection is authorized or claimed. The root's empty failed first diagnostic file is outside Mods and is not executable. These two loaded QA Mods must be backed up and removed from load paths before a later fixture-free cold read.

## Resource recovery and root handover

After the initial operator's two installer images, the root operator explicitly interrupted that task and reclaimed exclusive device use. `temp/evidence/root-android5/001-current.json` confirms both active and `.complete` now equal`16590ec82d1107a4bf628808`, with game PID27030; the PNG shows the normal animated title. Thus the earlier incomplete installation actually resumed through resource readiness and ordinary game startup. The observed host had31.72GiB RAM,4.03GiB available,87% load. This is not a clean-install or quiet-host timing benchmark.

A150ms ADB swipe command exceeded25s. The subsequent captured last-ANR still named the earlier Android.4 event at06:32:38 UTC/PID22944; no new Android.5 ANR was established. The root used a normal virtual-button tap next. Diagnostics recorded the C edge, and after a delayed title/load transition the actual File E/GUIFixture/Route1 card was visible (`006-after-title-wait.png`). It was explicitly selected before Continue. `008-E-map.png` shows the ordinary Route1 map. This sequence includes an earlier timed-out injection attempt and is not presented as a fresh, strict first-command single-C title acceptance test; the earlier Android.2 single-C phase tests remain separately recorded.

## Actual virtual-text submission and named backup

| Executed check | Actual result | Root evidence |
| --- | --- | --- |
| Empty Name field → virtual X | Returned to Choose a Save Slot; no save action was selected. |`014`–`018`,`016-empty-cancel-logs.txt` |
| Visible Gboard input | Actual Android input typed the six characters`EBASE5`; AndroidBack hid the keyboard and the field visibly retained all six. |`023-keyboard-visible.png`,`025-EBASE5-hidden.png` |
| Hidden IME → one virtual C | Returned to Choose a Save Slot. The log at07:47:31.541UTC records`native_mode=false return=true`, followed by the Ruby false setter. |`026-hidden-C-submit.png`,`027-hidden-C-logs.txt` |
| Original Save to File E | The selected item visibly named E; the next actual dialog says **GUIFixture saved the game.** It was dismissed and the enclosing backup method finished. |`026`,`028-save-EBASE5.png`,`029` |
| Named backup bytes |`File E - EBASE5.rxdata` exists,882340B/SHA`5bb27e4cc7a66f771182b7ffefdf25994c16443b89264fa38469c551a8ec3cb7`; no CR/LF or extra character in the filename. |`030-EBASE5-stable.tar/json` |

The actual native setter returned an Integer for its true request, and the asynchronous public getter was initially false; the wrapper retained the native result. The key proof above directly observes a virtual Return accepted while the native getter is false, supporting the explicit Ruby-session fix on this installed runtime. It does not prove that the Android.4 ANR shares that cause.

`032-checkpoint-verification.json` independently compares all24 files to the23-file upgrade baseline: only preexisting File E changed and only the exact EBASE5 backup was added; every other save/archive file, including H/G/F, EBASE and E1–E5, remains byte-identical. New main E is882340B/SHA`5dc389f8cd3b7d0cb8cb214c13f64019652b0673fdf7ad94c10ea282a7e558ef`. Trusted inert decoding of both main and named backup confirms both Player clones remain GUIFixture/File E; all six party records, shiny colors/flags/PIDs, boxes, bag, money, selected input/shiny settings and map position equal the Android.4 final checkpoint. No game classes or scripts were executed by the offline decoder.

These root records are under`temp/evidence/root-android5/`; they do not overwrite the initial operator's`shiny-v5` images. A separate narrow operator then received exclusive device use for hidden-IME X and reopen/typing checks. Double battle, fixture-free read-back, SAF and empty-save first-notice checks have not yet been counted as passes. The deterministic same-frame final-text fix has164 host assertions; device typing here is intentionally separated by seconds and does not claim reproduction of same-frame event ordering.
