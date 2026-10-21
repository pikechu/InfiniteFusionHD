# Android.2 GUI 回归准备

计划建立于2026-10-20；此文件是路线，不是通过报告。Android.2/code2的字体与普通闭环已实际执行，见[报告](gui-regression-report.md)。后续F/E/SAF升级到Android.3/code3执行；模拟器由GUI回归代理独占，其他任务不得同时操作。

## 存档隔离

- 现有 QA / File H 是只读基线。先记录 H 及所有备份的大小和 SHA256，复制到本 worktree 的 `temp/evidence/gui-v2/`。不导入、修改或读取 Windows 玩家档。
- 从正常入口读 H 后，立即使用暂停 Save → **Save to another file** → 空 **File G**。不先走路/战斗，避免自动保存仍指向 H。UI 确认后只读解析 G 的 `player.save_slot`，并再次核 H 哈希；后续普通回归只使用 G。
- 首次来源说明/角色创建/光标名字输入使用另一个全新 **File F**；独立闪光 fixture 使用从 GUI 另存的 **File E**。E 明确为人工数据，不能算自然闪光获得。
- 默认选择最晚修改槽，重启时必须先核卡片槽号，不能盲按 Continue。Save 菜单有“Save to another file”和“Name the next backup”；槽选择遇非空时取消，不覆盖 H。

## 回归顺序与证据

1. 升级安装保留数据：记录新 APK SHA、versionCode、私有 H 哈希，正常冷启至标题。分别在标题两精灵移动阶段和融合停留阶段只按一次 C，录屏/日志记录是否进入加载菜单；Movie 阶段与 GenOneStyle.intro 阶段分开，不把电影跳过键当标题通过。
2. 读 H 后另存 G。G 上核字体 Default、FR/LG、D/P、R/B 四种选项，显示多行正文、上下翻滚、选项、队伍名字和 HP 数字。选项位置为 Options 中 **Game's Font**；仅保存 G 的设置。截图必须可读全字形，不用 host 字体探针代替真实界面。
3. G 正常地图移动；使用已有三队员/正常商店购买道具，执行野战、捕捉、融合、拆分、Box 存入与取回。保留战斗命令、血量/经验、捕获、融合结果、道具数量、拆分队伍等关键画面。
4. G 原菜单保存，确认结束写入后 force-stop，再正常冷启读 G。核位置、普通物种/融合元数据、物品、金钱和哈希；对 H 始终比对不变。
5. F 全新 New Game 验证独立测试版来源说明、正常返回角色创建、Mobile cursor 昵称、首次选空槽保存。不选择任何会覆盖现有槽的确认。
6. E 才部署下述临时 fixture；真实 GUI 测普通/闪光精灵、普通+闪光融合、两闪光融合、反向融合、拆分、进化（15 级初始精灵 + Rare Candy）、多只闪光仓库与双打。记录第一次处理和缓存后重开耗时、FPS、PSS/RSS。fixture 只构造输入数据，所有交互和动画仍由原 UI/战斗执行。
7. E 保存后先退出并删除临时 Mod/请求文件，再正常启动读 E，验证闪光/融合/进化/仓库状态持久化。删除 Mod 后重启成功才算具备脱离 fixture 的读档证据。

## 临时闪光 fixture

`temp/android-gui-fixture.rb` 仅准备，未部署、未执行、未通过运行验收。部署位置为 AVD app 私有 writable/Mods；不得加入 APK 或 Data/Scripts。

- 必须先由 GUI 另存 File E，再关闭游戏。写入请求 `kif-gui-fixture.request`，内容必须精确为 `ANDROID_GUI_SHINY_FILE_E_V1`。读取其他槽时 fail closed；修改前后比对 H 原始 bytes。
- 首次读 E 后明确命名 `GUIFixture`，构造 6 只 15 级精灵（3 闪光、3 普通）、Box1 30 只（15 闪光），固定尺寸与配色参数，提供 12 个 Splicers / Reversers / Rare Candies / Balls，关闭 E 自动保存，保存到 E 并写一次性 receipt。所有这些数量与精灵均属人工 fixture。
- 只有另一个显式请求 `kif-gui-double.request` 才会弹出 GUI 确认，再启动真实 `pbDoubleWildBattle`；临时事件仅使该受控双打的野生敌方闪光。队伍前两只也是闪光，允许截图多只同屏的真实战斗。不会自动选择命令、确认融合或伪造结果。
- 准备阶段仅做 Ruby 语法检查。真实 seed 与双打可能发现接口/事件参数问题，必须据实际日志纠正；不得预写 PASS。

## 多槽、备份和 SAF

- G/E/F 各有独立 card/名字/位置，正常标题切槽逐个读回；H 仅核基线不变。G 用“Name the next backup”给一次备份命名，普通保存生成后记录新文件哈希。
- Launcher 的 **SAVES / EXIT** → 确认 **Close game** 后，必须确认 `:game` PID 消失。菜单实际按钮为 **Start game**、**Export saves to ZIP**、**Import saves from ZIP**、**Verify / repair bundled assets**。
- 点击 Export，经系统 SAF 选择 AVD Downloads 中唯一新 ZIP 名；读取 ZIP 条目/哈希与 app 私有目录对照。转移只处理文件字节，不执行 Marshal。
- 原封不动导入刚导出的ZIP应被冲突保护拒绝，所有既有文件哈希不变。另制作只包含专用空槽 **File D.rxdata** 的ZIP（来自E的已保存备份字节，记录来源与哈希），经SAF导入。Android.3已在加载前自动绑定实际手动槽；正常标题读D后须用普通Save确认显示D并实际保存，核两份Player均为D、E及其他槽字节未变，不能用立即“Save to another file”绕过这项验证。不得导入同名H。
- 备份恢复用 E 的明确命名备份，通过 SAF 导入到空 D；测试恢复的物种/闪光状态与旧备份一致，并与之后修改的 E 区分。只验证已执行的恢复路径，不假称自动损坏检测/断电恢复都通过。
- 测取消 SAF、无支持存档 ZIP、同名冲突和危险路径 ZIP时先备份 AVD 测试目录，确认报错后私有哈希不变。构造的 ZIP 都存 worktree temp，不触及主工作区存档。

每项实际结果追加独立 v2 报告，包括安装包、设备/API、runtime、时间、步骤、预期/实际、截图与日志；失败保存原证据。主机测试、构建、模拟器 GUI、真机结论分别报告。
