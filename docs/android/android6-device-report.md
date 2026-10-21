# Android.6 设备 GUI 验证（2026-10-20）

本轮在 `emulator-5554` 上实际操作 Android 界面。安装版本为 `0.20.7-android.6` / code 6，API 30 x86_64 AVD 使用 ARM64 翻译、4 KiB 页、3 GiB RAM；非真机。证据均位于 `temp/evidence/root-android6/`。

## 键盘重开与保存

- 从明确的 `File E / GUIFixture / Route 1` 卡继续游戏，进入 Save → Name the next backup。
- Keyboard 显示 Gboard 后输入 `R6`；Android Back 隐藏键盘；Keyboard 再次打开后输入 `Z`；再次 Back 后游戏自己的字段显示 **R6Z**（`017-field-r6z.png`）。虚拟 C 提交，再明确选择 Save to File E；界面显示 saved（018–020）。
- `021-r6z-saved` TAR/JSON 证明生成 `File E - R6Z.rxdata`，882140 B，SHA-256 `8bfa8b8db8110b26fea69ddd40d8f8bf93e0b1664a6e7c0ba69049c6398727bd`。
- 新 Name 输入 `CANCEL6`，隐藏键盘后虚拟 X 取消，随后在 Choose a Save Slot 明确选择 Cancel，再虚拟 C。`021` 与 `033` 的全部 27 文件哈希一致，没有 CANCEL6 备份。
- 随后用普通 Save to File E 保存，游戏自身新增一份自动备份；SAF 前归档为 `039-before-saf`（28 文件）。

## 临时 Mod 隔离

普通保存后通过 Saves / Exit → Close game 正常关闭，确认 `:game` PID 为空。

`042-retired-fixture-originals.tar` 完整保存两份 Mod，逐份核验原 SHA-256 后，移动至设备私有 `files/diagnostics/android6-fixture-retired/`，原件未丢弃：

| 文件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| android-gui-fixture.rb | 4641 | d52761e06fdd06b5a76e222c9957b2d120dbc1b479f92d7be4c6c5fb809377a3 |
| zzz_android_text_mode_diag.rb | 2397 | deaabb6ecfdb1f48790e188ad460c638be2da8337cd56ae48de6807fe05bcfe8 |

当时活动 CWD `files/content/be6a7f326cb7e1e0ea4ce30e` 下没有 `kif-gui-*.request/.used`。`files/writable/Mods` 已空，完整列表及隔离记录见 `042-retired-fixture.json`。旧 payload 目录遗留标记未加载、未触碰。

## SAF 真实系统文件选择器

以下均经 Launcher 按钮和 Android DocumentsUI 实际完成，未绕过 picker 调用导入实现。导出唯一文件名为 Downloads/`KIFQA6Export.zip`。

| 操作 | 实际界面结果 | 存档核验 |
| --- | --- | --- |
| Export saves to ZIP | Exported 27 save, backup and keybinding files（049） | 导出前后全部 28 原文件哈希一致（039/050） |
| 同 ZIP 导入 | A save already exists: File E - EBASE.rxdata；nothing was imported（067） | 全部 28 文件不变（068） |
| 打开 Import picker 后 Android Back | 返回 Launcher（071） | 全部 28 文件不变（072） |
| KIF-QA-reject-traversal.zip | Invalid ZIP path segment: ../File D.rxdata（077） | 全部 28 文件不变（078） |
| KIF-QA-reject-unsupported.zip | Unsupported save-import file: settings.json（082） | 全部 28 文件不变（083） |
| KIF-QA-restore-E1-as-D.zip | Imported 1 files. Existing saves were preserved（090） | 只新增原本不存在的 D；原 28 文件不变（089） |

导出的 ZIP 已只读拉回同证据目录，1379045 B。`053-export-content-check.json` 核验 27 个条目全部和源存档逐字节哈希匹配；与 `SaveTransfer.supported` 当前实现一致，本组文件仅 `android-runtime-smoke.dat` 被排除，`android-integration-probe.rxdata` 属于实现允许的后缀与路径。

恢复 ZIP 的唯一条目 `File D.rxdata` 为 878530 B，SHA-256 `cfaaee7f3ac3cf57d601ddc0ec83a6e670ba519638d49387163352585e863e1d`，来自此前人工 QA E1 备份，嵌入槽名原为 E。导入未改写这份文件字节。

## D 槽真实读取与普通保存

两份 Mod 移出后正常 Start game，明确选择 `File D / GUIFixture / Route 1` 卡（106）再继续。普通 Save 菜单自动显示 **Save to File D**（112），选择后显示 saved（113），没有通过 Save to another file 绕过。

`115-after-d-save` 归档显示：原 SAF 前 28 文件全部不变；D 主文件变为 880776 B / `43d55309ee8fe880d92d1d7522601ea4c686cf5f53fbf2899352ad8f33c594e5`，游戏自身新增 D 自动备份。

仅使用已有惰性类桩只读 decoder，未加载真实 Game 类、未写入 Marshal：`117-d-saved-decode.json` 中 `player.save_slot` 和 `kuray_player.save_slot` 均为 `File D`；队伍仍是早 E1 的六只未融合人工测试宝可梦（Bulbasaur / Charmander / Bulbasaur / Charmander / Squirtle / Pidgey，均 15 级）。

## 文件保护

`123-completed-checks.json` 汇总上述已完成的逐哈希检查。相对升级前 `temp/evidence/upgrade-android6/before.json` 的 26 文件基线，本轮仅允许 E 主文件变化；其余 25 个原文件全部保持原哈希，包括 H/G/F 和 EBASE5/EBASE/E1–E8 等旧备份。

H/G/F 的历史误写及恢复已在此前报告披露；此处只陈述本轮基线之后的保护结果，不能解释为历史上从未变化。

## 已观察限制

移出 Mod 后的 D 冷启，游戏画面实际为 512×384，靠左下显示，外侧虚拟按钮正常；Load 卡、地图及 Save 菜单均持续该布局（105/106/109/112）。早先本轮 IME 测试画面约 872×654。没有修改显示设置。随后通过 Close game 再正常 Start game（未再次进入 picker），标题、Load 卡、地图、队伍和摘要页均恢复约 872×654 的正常显示（125/129/135/138）。因此这是本轮 SAF 往返后的首次冷启出现、第二次冷启恢复的实际现象，原因未定位，不能把显示布局描述为无条件通过。

本轮未验收完整剧情、真机、16 KiB 页设备。启动加载阶段可出现 0 FPS，不能将截图帧率当平均性能。本轮最终 `148-lastanr.txt` 显示 `<no ANR has occurred since boot>`，未观察到新 ANR。


## E 槽无测试 Mod 冷读与最终状态

第二次正常冷启动后，从明确的 File E 卡继续（129/130）。GUI 实际确认：

- 135 队伍页显示六只，第一只 GUI SHI 2、第二只 GUI SHI 3 及第六只 GUI SHI 1 带红色闪光标记。
- 138 摘要页明确显示 Charmeleon / Lv16 / EXP 2535 / 红星 / OT GUIFixture；139 是 Squirtle / Lv15 摘要页。
- 143 Box 1 显示 GUI SHINY FIXTURE 的 5×6 共 30 只，选中的 GUI BOX 1 预览带红星；没有执行移动、释放、融合或重新 seed。
- 147 只读解码交叉核验六只队伍、Charmeleon16、Squirtle15，以及 Box 1 的 30 只/15 个 shiny 标记。它们均为此前明确标记来源的人工 QA 后代；不是自然遇闪证据。

`145-e-fixture-free-read` 与 D 保存后的 `115` 全部 30 文件哈希相同；最终 `154-final-saves` 仍相同。E 主文件保持普通保存后的 882140 B / `452152fd7715ef011cc6806b17f65be5d39a20ca4b32cfabc7bd66792700834f`，D 的读取与保存没有污染 E，最终冷读也没有写入存档。

146 当前进程日志没有 KIF_TEXT_MODE_DIAG；155 确认可加载 Mods 目录仍空。最终通过 Saves / Exit → Close game 正常关闭，152 停在 Launcher 管理页，153 的 `:game` PID 为空。全部自动核验结果见 **156-final-checks.json**，所有布尔项为 true。

未执行 APK 安装、构建、AVD 重启、生产代码修改或 Windows 玩家存档读取。本轮文档之外的产物均在 temp。
