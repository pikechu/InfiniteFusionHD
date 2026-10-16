# KIF Android 游戏侧兼容审查

审查日期：2026-10-16。范围：当前仓库 `Data/Scripts`、`Data/Scripts.rxdata`、`Game.ini`、字体和音频清单。文中行号基于平台接入前的基线 `7ed0dedafd46e7476e358d8c243687b77185c091`；随后实施状态见 `platform-test-strategy.md`。本文是源码审查结果，不是 Android 运行或性能验收。

## 版本与真实加载顺序

- `Data/VERSION` 为 `0.20.7`；`Data/Scripts/001_Settings.rb:8` 与 `:9` 标注 Infinite Fusion `6.4.5`。
- `Game.ini:3` 指向 `Data\Scripts.rxdata`，不是 `(Source)`。该文件为 Ruby Marshal 4.8 数组，其唯一 Main 脚本使用 zlib 压缩。
- 本次用 PowerShell/.NET `ZLibStream` 对压缩段（文件偏移 22，736 字节）只读解压核实加载器。其 `load_scripts_from_folder` 在每一层先收集文件和目录，分别 `sort!`；先 `File.open(..., "r")` / `eval(code, nil, f)` 全部文件，然后递归全部目录。**不按 `.rb` 扩展名筛选**。
- 所以根目录 `001_Settings.rb`、`002_BattleSettings.rb`、`RemoteUrls.rb` 都先于 `001_Technical` 子目录执行。目录名、文件名以及“本层文件先于本层目录”都决定最终行为。
- `999_Main/999_Main.rb:177` 进入主循环；进入该文件以后加载器不会再正常继续加载更后的目录。因此任何最终平台重开补丁应排在 `999_Main` 前。
- 不要把 README、JSON 清单、日志、测试报告、打包资源或临时文件放在 `Data/Scripts` 内。`docs/android`、`android`、`temp` 才是安全位置。

## 最小启动所需原生接口

下表区分脚本加载阶段与进入主循环后的调用。只让 `Graphics.update` 和标准 RGSS 类存在不足以启动。

| 阶段 | 位置 | 必须满足的行为 |
| --- | --- | --- |
| 根文件执行 | `001_Settings.rb:15`、`:131` | 能用 Ruby `File.read("Data/VERSION")`；能检查/创建 `Data/sprites`，路径必须是可访问的真实文件系统，或有完整 Ruby IO 映射 |
| 技术文件执行 | `001_Technical/001_MKXP_Compatibility.rb:42`、`:43` | `Font`、`Graphics.frame_rate=`；40 FPS 游戏逻辑 |
| 技术文件执行 | `001_Technical/001_MKXP_Compatibility.rb:512` | `Bitmap#draw_text`、`#text_size` 已存在才能 alias；仅 RGSS 占位常量不足够 |
| 输入定义 | `001_Technical/004_Input.rb:2`、`:14` | `Input::A/B/C/X/Y/Z/L/R` 和 `Input.update` 已存在；后者会被 alias |
| 存档类定义 | `002_Save data/001_SaveData.rb:8` | `System.data_directory` 在执行游戏启动函数前就被调用；目录必须预先存在，否则常量固定到当前目录 |
| 地图类定义 | `006_Map renderer/002_TilesetWrapper.rb:25`、`003_AutotileExpander.rb:3` | `Bitmap.max_size` 无条件执行，需返回实际 GL 最大纹理尺寸；假大值可能把后续地图带入崩溃 |
| 编译器文件执行 | `021_Compiler/001_Compiler.rb:1` | Ruby `require 'zlib'` 必须可用，即便 `Compiler.main` 已禁用也会执行这行 |
| 插件注册 | `052_AddOns/Spped Up.rb:23`、`:70`、`:54` | `PluginManager.register` 与 `System.set_window_title`；全新进程 `$PokemonSystem` 未初始化，加载该文件时即执行 `updateTitle` |
| 多存档定义 | `052_AddOns/MultiSaves.rb:96` | 再次无条件取 `System.data_directory`，定义真正使用的 `SAVE_DIR` |
| 主循环第一帧 | `999_Main/999_Main.rb:149`、`:122` | `Sprite`、`Viewport`、`Bitmap`、图片路径解析、`Graphics.update`；加载图片路径包含反斜杠 |
| 数据启动 | `999_Main/999_Main.rb:155`、`:156` | `Compiler.main` 随即返回；`Game.initialize` 直接读现有编译数据，不能缺少 `.rxdata`/`.dat` |
| 系统启动 | `052_AddOns/MultiSaves.rb:766` | 实际 `Game.set_up_system` 已被后加载实现覆盖，调用 `System.platform` 并从最新存档槽读取设置 |
| 显示初始化 | `001_Technical/001_MKXP_Compatibility.rb:536` | `Graphics.resize_screen`, `fullscreen`, `fullscreen=`, `scale=`, `center`；Android 应集中适配为固定游戏逻辑画布和 Activity 等比布局 |
| 标题/加载菜单 | `052_AddOns/IntroScreen.rb:24`、`:37`，`MultiSaves.rb:379` | 图片帧电影、音频、确认键，然后同步刷新网络文件/版本检测 |
| 地图第一帧 | `012_Overworld/001_Overworld.rb:34`、`:50` | `System.power_state` 返回哈希，至少有 `:discharging`，可有 `:seconds` / `:percent`；否则每次地图更新都会失败 |

### System 具体契约

除了上表之外，还使用：

- `System::VERSION`：`001_Technical/001_MKXP_Compatibility.rb:528`，决定 `Graphics.delta` 的单位。
- `System.delta`：`001_Technical/001_Debugging/003_Errors.rb:65` 与 `005_PluginManager.rb:468`；这里明确按微秒等待 500000，必须为单调时间，不能用帧号。
- `System.game_title`：调试和旧存档迁移需要字符串。
- `System.user_language`：`019_Utilities/001_Utilities.rb:53` 与多个图鉴界面；调用者假设类似 `en_US` 的字符串，可以切片 `[0..1]` 和 `[3..4]`。
- `System.user_name`：`019_Utilities/001_Utilities.rb:263`、`:271`；用于建议训练家名，需要非 nil 字符串。
- `System.open`：仅保存目录菜单的 Mac 分支，Android 应改到平台分享/导出接口。
- `System.reload_cache`：`021_Compiler/001_Compiler.rb:733`，通常因 `main` 直接返回而不可达；不能因此误判它是首屏阻塞。
- 源码注释提到 `System.mount`，本次未发现实际调用；APK 资源挂载仍必须兼容 Ruby `File`/`Dir`，不能只保证 `Bitmap` 能读 APK assets。

### Graphics 时间契约与后加载更新

`001_Technical/001_MKXP_Compatibility.rb:526` 自己重开定义 `Graphics.delta_s`：当 `System::VERSION == "MKXPZ_VERSION"` 时将 `Graphics.delta` 除以一百万，其余情况原值返回。Android 运行时应提供正确秒值的 `Graphics.delta`，或在游戏该定义之后集中覆盖单位；单在预加载阶段定义 `delta_s` 会被覆盖。

`052_AddOns/Spped Up.rb:75` 再次重开 `Graphics.update`，`alias fast_forward_update update`，每次更新写窗口标题，并按 `$GameSpeed` 跳过部分原生更新。帧率和生命周期测试必须跑这套最终实现。直接 benchmark 裸 `Graphics.update` 不能代表游戏帧率，原生 delta 与跳帧也须实测。

### Bitmap 地图与闪光

- `Bitmap.max_size` 必须真实；地图包装会调用 `Bitmap#mega?`（`006_Map renderer/002_TilesetWrapper.rb:34`）。需要验证超大 Tileset 软件表面、裁切和 blit，而非把 `mega?` 恒置 false 后认定地图兼容。
- `Bitmap#draw_text` 在 `001_MKXP_Compatibility.rb:514` 调整高度；字体字宽和基线会影响原版界面。项目随附 8 个 TTF，默认 `Power Green` / `Power Green Small` / `Power Green Narrow`（`007_Objects and windows/002_MessageConfig.rb:10`）。
- 闪光缓存读路径在 `007_Objects and windows/008_AnimatedBitmap.rb:606`，写路径在 `:715`，为 `Cache/Shiny` 和 `Cache/Shiny/vanilla`。
- 逐像素 `get_pixel` / `set_pixel`、多次通道提取和 Ruby PNG/zlib 写出都存在。`008_AnimatedBitmap.rb:694` 的循环使用包含上界的 `0..width` / `0..height`，兼容实现应确认越界像素读写与 mkxp 的透明/忽略语义，不能直接以原生数组访问导致崩溃。
- `200_PIFStuff/AnthonyImprovShinies/Shinies_Bitmap.rb:3` 后加载增加 `Bitmap#hue_customcolor`，内有“每像素 × 每规则”的最近颜色匹配。基础 `AnimatedBitmap` 已在 `:450` 调用该方法；不能只审查 `001_Technical` 就认为只需要原生 hue_change。
- `049_Compatibility/MarinUtilities.rb:1024` 提供 Ruby `Bitmap#save_to_png`。首版可保留并测量，后续原生批量像素变换和 PNG 编码必须以逐像素结果/缓存键相同为前提。

## 网络、JSON 与启动时写入

1. 通用下载接口在 `001_Technical/002_Files/003_HTTP_Utilities.rb:42`；`HTTPLite.get(url, headers)` 返回 Ruby Hash，成功判断为 `ret[:status] == 200`，二进制数据取 `ret[:body]`。
2. 游戏直接下载接口在 `052_AddOns/HttpCalls.rb:66`、`:110`。部分异常只捕获 `MKXPError`、`Errno::ENOENT`；Android 网络桥需将断网/TLS/超时按契约归一，避免 Java 异常或无界阻塞穿到主线程。
3. `HTTPLite.post_body(url, body, content_type, headers)` 用于表单；Wonder Trade 另用三参数调用和 JSON parse/stringify（`052_AddOns/OnlineWondertrade.rb:7`、`:9`、`:88`）。首版若禁用 Wonder Trade，应写入已知限制，不能破坏普通精灵下载。
4. `HTTPLite::JSON.parse` 也用于本地服装/图鉴数据：`050_Outfits/001_OutfitsMain/OutfitsGlobal.rb:10`、`:31`、`:52`；`048_Fusion/FusedSpecies.rb:366`。即使关闭网络，也不能省略 JSON 实现。
5. 最终加载菜单 `052_AddOns/MultiSaves.rb:379` 先调用 `updateHttpSettingsFile`、`updateCreditsFile`、`updateCustomDexFile`、`updateOnlineCustomSpritesFile`，再检查版本；这些调用先于用户选新游戏/继续。离线首启、超时和取消策略是第一轮验证范围。
6. `001_Settings.rb:69` 把下载设置保存到 `Data/Scripts/DownloadedSettings.rb`；这是下一次启动会执行的 Ruby，加载顺序也与 `RemoteUrls.rb` 有关。Android 首版应通过平台配置将远程配置放入可写 Data 区并明确数据/代码加载策略，避免在 APK 只读脚本目录写入，以及热更新内容影响构建固定性。暂禁自动远程脚本更新应只影响 Android 路径。
7. 精灵会写入 `Graphics/temp`、`Graphics/Battlers`、`Graphics/BaseSprites`、`Graphics/CustomBattlers/indexed`，已有文件检查使用 Ruby IO。下载应先写临时文件再原子替换；半个 PNG 不能被当作已缓存素材。
8. 下载总开关实际是 `$PokemonSystem.download_sprites == 0`（`:117`），数值含义与布尔直觉相反。不要把 0 当作禁用。

## 存储、大小写与存档

### 实际生效的多存档

- 基础 SaveData 在 `002_Save data/001_SaveData.rb`；真正路径和 `exists?` 等方法由 `052_AddOns/MultiSaves.rb` 重开。默认 2 个自动槽与 8 个手动槽，路径 `SAVE_DIR/<slot>.rxdata`（`:77`、`:96`、`:106`）。
- 真正 `Game.save(slot, auto, safe:)` 在 `MultiSaves.rb:792`，而非基础 `003_Game processing/001_StartGame.rb:176` 的文件路径签名。平台代码若把第一参传完整路径，会产生错误文件名。
- `MultiSaves_Infinite Save Backups.rb:17` 再 alias `PokemonSaveScreen#doSave`，会额外保存含地图名、时间和用户名字的无限备份；不能只测试 `Game.save` 一次文件输出。
- 旧 `Game.rxdata` 检测后拷贝到 `File A.rxdata`（`MultiSaves.rb:149`）；原始 Windows 迁移分支仅在 `System.platform[/Windows/]` 执行。Android 应由显式导入流程复制到自己的存档区，保留原始文件。
- `Marshal.load` / `Marshal.dump` 在 `002_Save data/001_SaveData.rb:31`、`:65`。存档带游戏对象、RPG 对象和本地扩展类型；相同 Ruby Marshal 版本只能说明容器格式接近，不能证明跨运行时对象兼容。需实际 Windows 文件副本导入、加载、另存，再回 Windows 读取副本。
- 当前保存直接 `File.open(path, 'wb')`；进程在写入时被结束可能截断唯一槽文件。平台适配优先增加同目录临时文件、flush/close 和原子 rename，并验证 `read_from_file` 中版本迁移会回写的分支。

### 文件映射策略

项目大量真实 `File.read`、`File.open`、`Dir.foreach`、`Dir.glob` 和相对路径，因此“APK assets 内置后只修改一处 save 路径”不够。可行首版是内置资源包首次验证解包到 app 私有游戏内容目录，游戏工作目录指向该目录；存档目录单独存在，缓存/下载明确分区。后续减少重复资源拷贝再引入读写 overlay。

安全卸载重装不等于升级；升级重解包不能覆盖下载文件、存档和备份。首次解包需校验 manifest/hash、磁盘空间、版本标记和中断恢复。

分隔符风险为真实 Ruby IO，不仅是 native bitmap load：

- `052_AddOns/IntroScreen.rb:37`：`RTP.getSaveFolder + "\\NoIntro.krs"`。
- `052_AddOns/Spped Up.rb:108` 起：多个私有标记文件用反斜杠。
- `016_UI/015_UI_Options.rb:1640`：选项导出文件用反斜杠。
- `016_UI/013_UI_Load.rb:285`、`052_AddOns/GameplayUtils.rb:1473`：`System.data_directory + "keybindings.mkxp1"` 不插入分隔符。预加载目录契约应带尾 `/`，或改为平台 path join；多存档本身允许双 `/`。
- `001_Technical/002_Files/001_FileTests.rb:155` 的 `canonicalize` 只归一斜杠/点路径，不校正大小写；`safeExists?` 对 ASCII 路径直接 `FileTest.exist?`。Android 上 `Graphics/titles` 与真实 `Graphics/Titles` 的混用必须通过路径清单校验或完整大小写匹配映射解决。
- 普通存档/备份、配置、`ExportedPokemons`、`Cache/Shiny`、下载资源与打包不可变资源须分别保留。`016_UI/017_UI_PokemonStorage.rb:2477` 起有大量导入导出，不能只映射单一入口。

## 输入、音频、Mobile 与桌面功能

- 方向键、确认、取消之外，Input alias 是 `USE=C`、`BACK=B`、`ACTION=A`、`JUMPUP=X`、`JUMPDOWN=Y`、`SPECIAL=Z`、`AUX1=L`、`AUX2=R`（`001_Technical/004_Input.rb:2`）。首版触控需要这些快捷键的可达入口，尤其仓库和战斗。
- 鼠标接口为 `Input.mouse_in_window`、`mouse_x`、`mouse_y`（`:30`）；仅按键版仍须确认现有菜单不会无条件引用缺失方法。
- 默认 `$PokemonSystem.textinput = 1`（`016_UI/015_UI_Options.rb:184`）。键盘昵称输入依赖 `Input.text_input=`、`gets`、`triggerex?`、`repeatex?`（`007_Objects and windows/012_TextEntry.rb:236`、`:256`）。Android 可先提供软键盘桥，保留 `pbEnterText` 的 cursor 模式作为回退（`016_UI/024_UI_TextEntry.rb:818`）。自由文本窗口和备份名也用键盘，不能只修训练家昵称。
- `@on_mobile = false` 默认值（`016_UI/015_UI_Options.rb:188`），Mobile 选项在 `:1820`；已核实其只跳过部分天气/结束字幕，不能建立 Android IO、虚拟键或生命周期。
- 音频文件实际计数：1700 WAV、1267 OGG、270 MP3、35 MID。未发现随仓库提交的 `.sf2`。需为 MIDI 明确提供 SoundFont/fluidsynth 或可核对的替代方案，静音 MIDI 不应记为完整音频兼容。
- 更新器入口是最终 `MultiSaves.rb:390` / `:393` 的 `Process.spawn('.\\INSTALL_OR_UPDATE.bat', "auto")`。Android 必须明确禁止或替换这个入口；不能仅删除标题菜单上不生效的基础实现。
- Shiny Finder 在 `016_UI/017_UI_PokemonStorage.rb:2107` 至 `:2113` 检测 EXE 再 `system('start ...')`；首版集中通过能力接口隐藏/禁用入口。
- 保存目录菜单最后实现是 `MultiSaves_Infinite Save Backups.rb:103`，`explorer` / `System.open`。链接打开在 `052_AddOns/GameplayUtils.rb:1141` 顺序尝试 `xdg-open` / `open` / `start`，应统一 Android Intent。
- Native Runtime 负责 pause/resume、GL context 重建、音频恢复与返回键；游戏层存档必须在安全时机写入。不要在任意一帧异步 Marshal 全部可变对象后宣称生命周期解决。

## 集中平台接口建议

采用两段加载，避免平台判断散落和被后加载重开覆盖：

1. **早期引导**：运行时 preload 或 `Data/Scripts/000_Platform.rb`。建立 `KIF::Platform`、环境/目录契约、UTF-8、native System/HTTPLite 桥和必要兼容检测。若用根脚本，注意它在 `001_Settings.rb` 前，不能假定 Settings 已定义。
2. **设置与路径**：根级 `003_PlatformSettings.rb` 会在 Settings 后执行、在 RemoteUrls 前执行，适合平台下载/写入路径常量。只改 Android 常量，保持 Windows 默认值。
3. **最终补丁**：`998_Platform/001_AndroidAdapters.rb`，位于所有游戏扩展之后、`999_Main` 之前；修正 `Graphics.delta_s`/resize、桌面能力、文本输入、最终多存档和安全保存。切勿把该补丁只放到基础类附近。
4. 建议接口：`android?`、`writable_path(kind, relative)`、`save_root`、`open_url`、`open_export_folder`、`desktop_updater?`、`external_shiny_finder?`、`network_get`、`network_post`、`request_text`、`atomic_write`。跨端公共调用保持同签名，由平台实现选择行为。
5. 构建前生成路径大小写/重复文件清单；明确所有源文件编码和 loader 排序，不在打包阶段隐式丢失非 ASCII 文件名或重命名游戏存档。

## 建议的第一轮可执行验证顺序

1. 用实际选定 native Runtime 预加载能力探针：打印版本、Ruby/Zlib、max texture、System 返回类型、Graphics delta、音频/字体加载；缺接口立即失败并写 app 私有日志。
2. 按真实 loader 执行全部游戏脚本，记录最后一个已加载文件。验证首次首屏和标题前的加载画面，禁止把截图绘制占位当成游戏启动成功。
3. 在离线和联网模式进入最终加载菜单，确认网络超时不会阻止新开档。
4. 新档进入地图，覆盖 `power_state`、renderer `mega?`/delta、音乐、名字输入。
5. 按用户验收顺序做战斗/捕捉、融合/拆分、闪光、仓库；尤其首次闪光与已缓存闪光分别计时。
6. 保存 File A 和 File B、创建备份，结束进程，重启恢复；再导入 Windows 存档副本并另存。

本审查未执行 Android Runtime，因此启动、音频、可玩性、存档跨端和性能数值均仍须实际设备/模拟器验证。
