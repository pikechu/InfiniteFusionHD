# Android GUI 兼容性调查

2026-10-16，只读调查。未修改游戏二进制、Ruby 源码、字体或 Android 配置；未驱动、安装、停止或重启 5554/5556，也未读取 Windows 玩家存档。5554 GUI 仍由 `game_audit` 独占。

## 1. 首次启动来源问答：Other 必然进入退出路径

读取的原仓库素材经 Git 对照，均与隔离 worktree 的 HEAD 对应 blob 一致：

| 数据 | Git blob |
| --- | --- |
| `Data/CommonEvents.rxdata`，157,955 bytes | `6f0ac9c7405a3a349d0a4954a31cd3d9ddaa74e2` |
| `Data/Map295.rxdata` | `442f5dedf879af66671cd04210f8aa49c61f31e1` |
| `Data/System.rxdata` | `70001652e4ce27d48f21bc35bead34e2893a395b` |

portable Ruby 使用仅含字段的 RPG 数据类 stub，以及只保存原始 bytes 的 Tone/Color/Table `_load` stub，反序列化可信数据库；没有加载游戏脚本或执行事件中的 Ruby。临时提取器和完整精确输出在 `temp/gui-investigation/extract_common_event.rb`、`common-event-108.json`、`common-event-108.txt`、`extract_context.rb`、`map295-context.json`。

### 事件元数据和入口

CommonEvent **108** 名称为 **`gameDownload Warning`**，`trigger=0`、`switch_id=1`；trigger 0 表示被调用的公共事件，元数据 switch_id 不构成运行条件。该事件共 **91 条命令，索引 0–90**。

实际入口为 Map **295** 的 Event **4** `Intro`、page **0**、autorun `trigger=3`，该 page 的 switch/variable/self-switch 条件均未启用：

- Map command **23**：`code=111, indent=0, parameters=[0,972,0]`，检查 switch 972 为 ON。
- switch **972** 的数据库名称为 **`Not the first savefile`**。
- ON 分支 command **24**：`code=117, indent=1, parameters=[96]`。
- ELSE command **26** 后，command **27**：`code=117, indent=1, parameters=[108]`。
- 公共事件返回后，command **35–36** 执行 `menu = CharacterSelectionMenuView.new` / `menu.start`，随后 `setupStartingOutfit()`。来源问答是人物创建之前的启动说明，不是剧情进度本身。

`003_Game processing/004_Interpreter_Commands.rb:425` 的 `Interpreter#command_117` 创建 child interpreter 并执行指定公共事件。该文件 `:310` 起解释 switch/variable 条件，`parameters=[0,972,0]` 中最后的 0 确实表示 ON。

### 精确分支和写入

CommonEvent command **4–10** 组成一个 Ruby script block：

```ruby
options=["The game's official Discord",
"The game's subreddit",
"The game's Pokecommunity thread",
"A Pokémon Infinite Fusion website",
"Other"]
selected= optionsMenu(options,nil,4)
pbSet(5,selected)
```

`052_AddOns/GameplayUtils.rb:1525` 的签名是 `optionsMenu(options=[], cmdIfCancel=-1, startingOption=0)`，所以第三参数 **4 是初始选中 Other**，不是取消码；nil 取消参数转为 -1。变量 **5** 的数据库名称为 **`Temp Text Entry`**。

| 条件命令索引 | 精确参数 | 跳转命令 | 目标 |
| --- | --- | --- | --- |
| 11 | `[1,5,0,0,0]`：var5 == 常量 0 | 13：119 `["good"]` | good 标签 36 |
| 16 | `[1,5,0,1,0]`：var5 == 1 | 18：119 `["good"]` | good 标签 36 |
| 21 | `[1,5,0,2,0]`：var5 == 2 | 23：119 `["good"]` | good 标签 36 |
| 26 | `[1,5,0,3,0]`：var5 == 3，website | 28：119 `["bad"]` | bad 标签 53 |
| 31 | `[1,5,0,4,0]`：var5 == 4，Other | 33：119 `["bad"]` | bad 标签 53 |

108 中没有 code 121 控制 switch 或 code 122 控制变量；除 script 的 `pbSet(5,selected)` 外，没有剧情变量/开关写入。不要把 switch 972 打开来绕过问题：那会伪造“不是首个存档”的状态。

### 关键命令序列

| 索引范围 | 命令与行为 |
| --- | --- |
| 0–3 | 101/401 欢迎、询问下载来源，并注明数据不会收集 |
| 4–10 | 上述 355/655 选项 script，写 var5 |
| 11–35 | 上表五个条件分支、注释、119 跳转、412 分支结束 |
| 36–49 | good 标签；SE；来源安全说明、假网站提醒；106 `[8]`；“Let's get started!” |
| 50 | **115**，结束公共事件，返回父地图事件 |
| 51–53 | 注释；bad 标签 |
| 54 | **112**，开始 Loop |
| 55–72 | SE、IMPORTANT、假网站/卸载电脑游戏/扫描/加入 Discord 等多屏警告，含 106 `[8]` |
| 73 | **102**, `[["Repeat","Understood!"],2]` |
| 74–75 | 402 `[0,"Repeat"]`，空命令 |
| 76–81 | 402 `[1,"Understood!"]`；要求举报假网站；提示将打开社区地址 |
| 82 | **355**, `openUrlInBrowser(Settings::DISCORD_URL)` |
| 83 | **355**, `#Quit game` |
| 84 | **655**, `$scene = nil` |
| 85–90 | 等待、空命令、404 选项结束、413 Repeat Above、末尾 0 |

`Interpreter#command_355`（同文件 `:1015`）会合并相邻的 **355 和 655**，因此 82–84 实际作为一个 script 执行。精确调用是 `openUrlInBrowser`，数据库里不是一个名为 openDiscord 的函数。

`GameplayUtils.rb:1138` 已集中处理 Android 的浏览器/复制地址行为，但这无法消除后面的 `$scene=nil`。bad 分支的 Loop **没有 code 113 Break Loop**；只忽略退出赋值会让警告重复，不能作为可用修复。选择官方来源 0 路径走通也不能证明 Other 已解决。

上述消息只是当前数据库内容的记录，不代表对 2026 年实际官方发布渠道或网站状态的外部核实。

### 可实施选择：建议 A

**A. 在公共事件调用边界做 Android 启动说明替代。** `Interpreter#command_117` 增加一处集中平台调用，例如 `KIF::Platform.common_event_commands(id, event)`；仅 Android、id 108 且名称/关键命令签名与固定数据相符时返回替代命令 list，否则返回 nil、使用原 list。替代 list 只包含原消息系统的 101/401、可选的 `pbSet(5,4)` script 和末尾 115，仍用原 child interpreter/setup 流程执行。说明如“这是 KIF 的独立 Android 测试移植版，不能据此认定 APK 下载来源为原项目官方渠道”，可保留核实来源/查看原项目社区地址的可选入口，然后返回父事件继续人物创建。若记录临时变量的来源分类，明确记录 var5=4（Other），不能写 0 冒充官方 Discord。

该方案不改 rxdata，不改其他公共事件，不改变 switch 972、人物、地图、剧情或存档状态；Windows 和签名不匹配的上游事件继续原行为。实现时要显式保护事件签名，防未来 id 108 被复用后静默跳过新内容。对应单元测试应以本次精确事件元数据作 fixture，验证 Android 执行新的说明 child、未执行原 bad list、说明结束后返回父地图、无 `$scene=nil`，其他 ID/Windows 均原样转发，var5 不伪装官方来源。

不要未经保护就在 `command_117` 内同步调用 pbMessage：`003_Interpreter.rb:105` 通过 `@message_waiting` 防止消息期间重入解释器，原 `command_101` 会设置/复位它。替代 list 复用现有消息命令可以保留这一保护；若坚持同步 handler，必须在 ensure 中正确恢复该 flag，并做重入测试。

**B. 仅在内存中替换该公共事件的说明内容。** 加入明确的“Standalone Android APK (unofficial port)”选项及独立、可正常结束的 Android 分支。必须同时处理原始 Other 和默认选中项，不能仍让诚实选择 Other 的用户被退出。需要更多 EventCommand 构造和顺序验证；比 A 更难维护，但可以保留来源问答形式。

不建议改 binary、强制返回选项 0、改变全局 optionsMenu、泛化屏蔽 `$scene=nil`，或仅关闭浏览器打开。这些要么伪造来源，要么影响无关退出/剧情逻辑，要么留下无限循环。

## 2. 文本下半裁切：优先测试原生字体高度报告模式

已查看保留截图 `gui-loop/06-intro-text.png`、`08-origin-options.png`、`25-character-intro.png`。来源选项中多个独立行均在字形中部切平；长消息第二行也被切，而窗口和 Java 侧按钮正常。现象更符合每次 draw_text 的局部裁切，不像整个 SDL surface 被安全区/按钮覆盖。此为图像观察，不是新的设备操作。

### 实际后加载链

1. `007_Objects and windows/002_MessageConfig.rb:10–15`：Power Green / Small / Narrow，字号 **29/25/29**；`:31–35` 类变量也初始化为这些值；`:452–467` 的 pbSetSystemFont 等读取这些 getter。
2. `007_Objects and windows/005_SpriteWindow_text.rb:128`：对话 `@lineHeight=32`；`:741`、`:758`：菜单行高 32。`Window_CommandPokemon#drawItem`（`:1265`）调用 pbDrawShadowText。
3. `007_Objects and windows/010_DrawText.rb:1147` 的 pbDrawShadowText 为行增加 y=4，阴影再加最多 2px，然后调用 Bitmap.draw_text；格式化文字在 `:1045` 的 drawSingleFormattedChar 也走同一个入口。
4. `001_Technical/001_MKXP_Compatibility.rb:518–523` 先保存原生 `mkxp_draw_text`，再把传入 height **无条件替换为 `text_size(text).height`**。
5. **后加载** `102_DemICE's Tutor.net/Tutor.net.rb:22–34` 再次定义 Bitmap.draw_text。普通坐标路径同样覆盖 height，并处理 text_offset_y；Rect 路径还会修改传入 Rect.y。只改第 4 步会被后加载重开类覆盖。
6. `016_UI/015_UI_Options.rb:351–386`、`:732–765`、`:2550–2587` 会按用户字体设置再次设置名称/字号。因此仅修改 MessageConfig 常量也不是可靠统一入口。

### 原生源码与字体表证据

固定 runtime commit `68653811...` 的源码：

- `src/config.cpp:198` 默认 **`fontHeightReporting=0`**；`:337` 从配置读取。
- `mkxp.json:455–459` 明确说明：0 是 Nominal/TTF_FontHeight，可能切掉字形底部；**1 是 Rendered/TTF_SizeUTF8**。
- `src/display/bitmap.cpp:3596–3639` 的 textSize 先获得实际 TTF_SizeUTF8 的 h，但在模式 0 又用 TTF_FontHeight 覆盖。
- 同文件 `:3393–3403` 用 textSize 结果做对齐，`:3538–3545` 形成目标矩形时用 `min(rect.h, txtSurf->h)`，所以 Ruby 层传入过小的名义高度确实会裁掉实际字形。

此外，用只读 SFNT 表解析检查全部 8 个已跟踪 TTF。它们都没有 VDMX 表，且 hhea descender 都为**正值**。例如：

| 字体 | UPEM | hhea ascender | hhea descender | Win ascent/descent |
| --- | --- | --- | --- | --- |
| Power Green / Narrow | 832 | 624 | **+208** | 765 / 232 |
| Power Green Small | 704 | 528 | **+176** | 703 / 88 |
| Power Red and Green | 768 | 528 | **+240** | 701 / 224 |

完整数据与提取器在 `temp/gui-investigation/font-tables-all.json`、`font_tables.rb`。这不是字体修改。

native `src/display/font.cpp:472–530` 按 Windows 字号规则和 Win ascent/descent 算 ppem。Power Green size 29 在无 VDMX 时估算 ppem≈24；SDL_ttf 2.20.2 的 scalable nominal height 公式为 ascent−descender，按该表估算约 `(624−208)*24/832 = 12px`。字形实际范围明显超过该名义高度，与截图只显示每行上半的现象一致。**12px 是表/源码推算，不是设备上实际 TTF_FontHeight 的新测量**；FreeType 选用的实际 metrics 和 raster bounds 仍应由探针确认。[SDL_ttf 2.20.2 官方源码](https://github.com/libsdl-org/SDL_ttf/blob/release-2.20.2/SDL_ttf.c#L1808)

日志里的 “Primary font not found: Arial” 是 native 初始默认字体，不足以证明 Power Green 缺失；打包清单包含 8 个原字体，且截图风格符合原像素字体。不要直接换 Liberation Sans 或把字号全局缩小来掩盖裁切。

### 最小修复候选与量化验收

**优先候选：只在 Android 构建的 mkxp-base.json 加 `fontHeightReporting: 1`**（集中 `scripts/android/package_game.py` 的 BASE_CONFIG）。不动 TTF、不动行距和菜单，不影响 Windows mkxp.json。它使现有两次 Ruby height 覆盖都拿到实际渲染高度，是最小且有上游配置依据的选择。需要冷重启 runtime 进行对照，不能只刷新 Ruby 就宣称配置生效。

建议根任务安排一个独立诊断：固定 Power Green 29、Small 25、Narrow 29 及另两种可选字体，记录 `Font.exist?`、实际 font.name/size、`CFG['fontHeightReporting']`、`text_size('Agjpqyé').height`。分别用原生 alias 在 64px 高 bitmap 和现有 draw_text 路径在 32px 行中渲染；通过 raw_data 的非透明像素边界统计，或 `Bitmap#to_file` 留图，比较底部被裁的像素行数。使用 `Agjpqyé` 涵盖上下延伸字符，不只看没有下伸部的数字。

退出标准：0/1 两配置的同一探针可复现差异；模式 1 下字形底部完整、阴影包含在 32px 行中，相邻两行不重叠；GUI 的来源五选项、多行介绍、角色菜单均无字形中部平切；选项 0–3 的字体切换、已有存档字体设定及 Windows 默认表现回归。若 size29 实际加阴影超过32，再依据实测做小范围基线/行高调整，不能先猜。

若模式 1 不能解决：第二选择是在 Android preload 的集中 Bitmap prepend 中处理 draw_text，保留 text_offset_y、支持 Rect/坐标两种签名，直接调用保存的原生 alias，避免后加载 Tutor 覆盖传入行高。该方案必须验证格式化逐字描绘、Rect 对象不被修改及 Window_CommandPokemon/Window_AdvancedTextPokemon 的基线，不宜先于单配置对照。改 MessageConfig 字号/全局 32 行距或替换原字体属于影响更大的后续选择。

本次仅给出可实施选择，没有声称两个 GUI 问题已修复或已经重新跑过新档。
