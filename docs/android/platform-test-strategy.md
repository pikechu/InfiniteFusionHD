# Android 平台层测试策略

日期：2026-10-16。本文区分可在 Windows portable Ruby 执行的平台契约测试和必须在 Android 实际运行的测试。

## 已实现范围

- `Data/Scripts/000_Platform.rb` 早于 Settings 加载，提供平台能力与 HTTP 入口。Windows 请求原样传给 HTTPLite；Android 在可信 HTTPS 适配器安装前返回明确的失败响应。JSON 解析仍由现有 HTTPLite::JSON 提供。
- `android/ruby/kif_android_preload.rb` 仅当 `System.is_android?` 为真时执行。Android shell 必须设置绝对路径 `KIF_SAVE_DIR=<app files>/saves`，并把该 preload 打包到游戏根目录、配置进 mkxp.json。目录先于 SaveData 常量求值创建；带尾 `/` 兼容旧 keybindings 文件拼接。
- Android 默认使用现有 Mobile 选项及光标名字输入，存档格式不变。仅在新建 PokemonSystem 对象时改变默认值；Windows 仍沿用原默认。
- Android 不显示 Shiny Finder，不能调用 BAT 更新器或 Explorer。URL 使用可注入的 Android opener；尚无 opener 时给出地址并尽可能复制到剪贴板。
- 两处异常窗口的 500ms 输入等待改用 Ruby 单调秒时钟，避免新版 System.delta 已返回秒而被误当成微秒；不更改 runtime 的 System.delta/Graphics.delta。
- Android preload 在原生未提供时补 `File.exists?` / `Dir.exists?` 为各自 `exist?` 的别名，满足 Ruby 3.2+ 删除旧 API 后 KIF/Essentials 的实际调用；Windows 不修改。
- `KIF::Platform.read_path` 仅为 Android 归一读取路径斜杠，并对不存在的精确拼写逐目录找唯一大小写匹配；不缓存 miss。`safeExists?`、`pbTryString` 和 `File.safe?` 使用它，后者返回/读取真实可访问的路径。未全局改写 File.open 等 IO。
- Android 默认离线；仅显式网络构建、native 桥成功加载且本地适配器就绪时，才安装 `KIF::AndroidHTTPAdapter`，经 Java 平台 TLS 发出请求。不会通过开关恢复不验证证书的 native client。GET 可有限重定向/重试，POST 的 Ruby 请求明确发送 `follow_redirects=false`，Java 同样只允许 GET 跟随，避免重放。
- Android preload 的 Bitmap 构造器 hook 仅解析 String 首参，通过集中 `read_bitmap_path` 处理反斜杠、大小写和省略扩展名；数字尺寸参数及其他参数不变，Windows 首次加载不安装 hook。
- 下载集中进入 `write_download`：Android 只写私有沙盒现有父目录，保护存档/备份和不筛扩展名的 Scripts 目录；PNG/GIF magic 验证后写 EXCL 临时文件，flush/fsync/close/rename 激活。失败不覆盖旧缓存，仅清理本次 partial。Windows 保留原直接写入及异常行为。

## 本地可执行检查

使用官方 portable Ruby 运行：

```powershell
$ruby = (Resolve-Path 'temp/tools/ruby-3.2.9/rubyinstaller-3.2.9-1-x64/bin/ruby.exe').Path
& $ruby --disable-gems android/tests/platform_contract_test.rb
& $ruby --disable-gems android/tests/bitmap_path_contract_test.rb
& $ruby --disable-gems android/tests/http_adapter_test.rb
& $ruby --disable-gems android/tests/download_write_test.rb
```

脚本只使用 mock System/HTTPLite，临时文件在项目 `temp` 下独立目录，结束后移除；不会启动游戏或加载真实玩家存档。断言覆盖：

1. 非 Android preload 不改变桌面保存路径；桌面 HTTP 参数、headers 及 3/4 参数 POST 透传。
2. Android 未安装 HTTPS 适配器时 GET/POST 返回失败，**原生 HTTPLite 没有被调用**。
3. 缺失/相对 KIF_SAVE_DIR 必须失败，合法路径在 SaveData 加载前创建，尾分隔符正确，重复 preload 不改变结果。
4. 独立临时槽文件可在指定路径做 Marshal round trip。此项只证明路径和 IO，不代表 KIF 真实存档跨端兼容。
5. 不合格 HTTP adapter 被拒绝，合格 adapter 收到请求且不回退原生客户端；URL opener 的有/无能力状态正确。

另用 `ruby -c` 或 `RubyVM::InstructionSequence.compile_file` 检查本次修改脚本。语法检查成功不是 Android 运行成功。

### 2026-10-16 本地执行结果

- 官方 [RubyInstaller 3.2.9-1 x64 portable release](https://github.com/oneclick/rubyinstaller2/releases/tag/RubyInstaller-3.2.9-1)，版本输出 `ruby 3.2.9 (2025-07-24 revision 8f611e0c46) [x64-mingw-ucrt]`。
- 免安装路径：`temp/tools/ruby-3.2.9/rubyinstaller-3.2.9-1-x64/bin/ruby.exe`；使用 `--disable-gems` 避免 RubyInstaller 的自动 Gem 环境初始化。
- Ruby archive SHA256：`d732a4d02236b623a18dedcfacc00dc0e09cf3a10b172d58255887693791d300`；已与官方 release API asset digest 一致核对。
- 解压器为官方 [7-Zip 26.04 standalone 7zr.exe](https://github.com/ip7z/7zip/releases/tag/26.04)，SHA256 `256feca8e274e5da655e2a284fabafd9f554365eb164862089dacd4e8276d282`，亦核对官方 asset digest；仅位于 temp，未安装系统软件。
- 平台契约：**38/38 断言通过**；含 Ruby 3.2+ 旧 API 缺失模拟与保留 runtime 已有实现、路径归一/真实目录大小写解析/新下载不受负缓存影响，以及实际游戏 FileTests 的三个接入点；日志 `temp/logs/ruby-platform-contract.txt`。
- 后续新增三项可执行回归：Bitmap 构造器入口 **11/11**；HTTP 适配器 **52/52**（模拟 mkxp JSON 整数返回 Float、MKXPError 继承 Exception，含三/四参数 POST 不跟随重定向）；原子下载落盘 **38/38**（真实临时文件，含断写、fsync/rename 失败保留旧文件、PNG/GIF 防 HTML 投毒及实际游戏四个写入入口）。连同平台契约共 **139 项**。HTTP 使用 native bridge/JSON mock，不能视为真实 TLS 验收。
- 编译语法检查：当时 `Data/Scripts` 与 `android/ruby`、`android/tests` 合计 **440 个 Ruby 文件，0 个 SyntaxError**。三条既有 warning 是 `Sprite_Character.rb:214`、`Move_Usage_Calculations.rb:403` 的条件赋值与 `OnlineWondertrade.rb:81` 的重复 Hash key，与本次平台修改无关。
- `git diff --check` 通过。

以上是实际执行的 Windows Ruby 检查，没有启动 KIF 游戏、没有修改玩家存档，不能计为 Android 启动/可玩性或 Windows 游戏回归。Windows 分支契约明确覆盖原参数透传、原 `File.open(..., "wb")`、无 Bitmap hook 和参数对象不变；实际 Windows runtime 启动/游玩回归仍须另做。

## Android 实际验证清单

| 测试 | 步骤及预期 | 必须保留证据 |
| --- | --- | --- |
| 首次解包与启动 | 安装后资源解包成功；preload 先创建 saves；真实 loader 完成并出现游戏标题 | logcat、解包 manifest、启动截图、开始/标题时间 |
| 无 preload 配置失败 | 测试副本故意移除 KIF_SAVE_DIR；明确错误且不写游戏根存档 | 日志与游戏根文件列表 |
| 离线新档 | 断网启动到加载菜单；不因版本检查/TLS停住；新开档、光标输入名、地图移动 | 视频/截图及完整日志 |
| 快捷键/返回键 | 方向、确认、取消、跑步、仓库和战斗所需快捷键可触达；系统返回键转为取消 | 输入记录、界面截图 |
| 桌面入口隔离 | Android 不显示 Shiny Finder；直接调用会友好提示；更新器和目录入口无外部命令 | 日志、仓库/保存菜单截图 |
| 网络恢复后下载 | 安装可信 adapter 后下载缺失 PNG，TLS错误/超时/404/断网返回可处理失败；缓存不留半文件 | HTTPS单元/集成日志、文件hash |
| 两槽保存重启 | 新建 File A / File B、备份；结束进程后重启分别读取正确地图与队伍 | saves清单/hash、重启视频、日志 |
| 真实 Windows 存档副本 | 导入副本、读取、多槽另存；Android输出副本回 Windows 验证，不覆盖原始档 | 输入/输出hash、双方runtime版本、截图 |
| 核心游玩 | 战斗、捕捉、融合、反向融合、拆分、进化、仓库各完成一轮 | 步骤、预期/实际、截图/日志 |
| 闪光首次与缓存 | 普通/闪光不同组合；同一闪光首次/缓存命中、大量仓库同时显示 | 帧时间分布、峰值RSS、生成耗时、像素对比 |
| 生命周期 | 切后台、锁屏、音频focus、系统结束进程、写存档时结束进程 | logcat、重启读档结果、文件完整性 |
| 屏幕适配 | 不同宽高比/安全区；虚拟按键不遮挡地图与菜单关键区 | 型号/API/分辨率/截图 |

## Windows 回归

使用未修改的真实 Windows runtime 对改动分支副本执行：启动标题、设置默认/加载已有设置、普通与闪光精灵、下载、保存/读档、Shiny Finder和保存目录入口。保存/下载位置必须仍是原 Windows 契约。测试使用存档副本，不能覆盖用户实际槽位。

## 尚未解决的边界

- 基础素材已版本化到 `files/content/<id>`，可写图片到 `files/writable/Graphics-<id>`，存档独立；升级迁移、缓存容量治理与中断恢复仍需设备测试。
- 本次没有改变直接写 Marshal 存档的实现；进程在写入期间死亡的原子性仍需后续修复和测试。
- Android 原生键盘、返回键、GL/音频恢复和触控 overlay 由 shell/runtime 提供；光标输入作为可玩回退不等于软键盘验证完成。
- 默认离线构建不能在线补齐缺失素材；可选 Java TLS 网络构建也必须通过真实证书、重定向、断网、超时和缓存测试，才可记为完整网络功能交付。
