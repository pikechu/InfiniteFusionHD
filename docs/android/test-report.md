# Android 验证记录（持续更新）

日期：2026-10-16，时区 Asia/Shanghai。本文中的 PASS 仅覆盖所列步骤；不能推导为完整剧情、真机验收或所有核心玩法通过。

## 环境

- 自建 `emulator-5554`，Android 11 / API 30，`sdk_gphone_x86_64`，1280×720 横屏。
- WHPX，SwiftShader；`libndk_translation.so` 执行 ARM64 库，4 KiB 内存页。不是 ARM 真机。
- 系统映像 fingerprint：`google/sdk_gphone_x86_64/generic_x86_64_arm64:11/RSR1.240422.006/12134477:userdebug/dev-keys`。
- Runtime 源码 `68653811c3c396f2d4c12225c52c407746285a3d`，运行报告 `2.4.2/59cd2ca7`，Ruby 3.4.10，Marshal 4.8。
- 原生 runtime 使用固定上游预编译库；源码重建未通过，16 KiB 页不在兼容范围内。
- 测试包 `org.kuray.kif`、测试签名，API 30–35 构建配置；目前只实际测了 API 30。

## 已实际执行

| 检查 | 预期 | 实际 / 证据 |
| --- | --- | --- |
| Portable Java/SDK 工具 | 可运行并固定版本 | PASS；工具链报告与归档哈希见 toolchain.md |
| 平台契约 | Windows 透传、Android 路径/禁网络/私有存档 | PASS，38 项；mock native host，不是 RGSS 游玩 |
| Ruby 语法 | 游戏脚本与诊断可编译 | PASS，440 文件；既有 2 个赋值条件警告及 1 个重复 Hash key 警告，不由本次引入 |
| SaveTransfer ZIP/文件系统 | 拒绝覆盖、路径/CRC/大小限制、恢复 | PASS，33 项真实主机文件系统断言；Android SAF 尚未测 |
| APK 编译与签名 | 独立可安装包 | PASS，javac/D8/aapt2/zipalign/apksigner；真实 adb install 返回 Success |
| 模拟器启动 | 完整解锁后运行应用 | PASS，首次 boot 328,622ms；早期未解锁时安装/启动失败，待 boot=1 后成功 |
| 原生基础探针 | 画面、字体、Bitmap、zlib、Marshal | PASS，日志 KIF_SMOKE_PASS；120帧/3.266563s，实际平均约36.7fps；native显示39–41附近不替代该计时 |
| 原生路径环境传递 | Ruby 可取 KIF_SAVE_DIR | 首轮 FAIL：KeyError；修为 SDLActivity.nativeSetenv 后 PASS |
| 原生探针内存 | 记录 PSS/RSS | PSS 131,031KiB（约128MiB），RSS260,260KiB；仅静态诊断画面 |
| 切后台→恢复原生探针 | 同进程恢复帧循环 | PASS，PID8395保持，nativePause/onPause/onStop→onStart/onResume/nativeResume，恢复39–41附近FPS；一次模拟器测试，不含锁屏/音频实测 |
| 标准库能力 | 明确真实 require 范围 | socket/openssl可用；net/http、uri、json、fileutils、timeout不可用。OpenSSL默认CA指向构建机，不可用作Android信任库 |
| 完整素材安装 | 校验所有项后启动 | PASS，23,124项、979,316,402字节，128,028ms；payload d332581869f8b7a64805d679 |
| 完整脚本加载 | 按实际顺序加载，跳过Main无限循环 | PASS，18.3897s；最终融合、仓库和闪光扩展存在 |
| 编译数据/新对象初始化 | 原生读数据、Player/PokemonSystem、起始地图 | PASS，93.9773s；不读取玩家存档 |
| Pokemon/融合数据模型 | 真实构造、拆分/反向ID、IV helper | PASS，至16项断言；0.8864s；未执行融合/反向融合动画 |
| 普通/闪光图 | 真实非占位像素且配色变化 | FAIL，32×32占位。独立原生Bitmap探针确认 ENOENT，而Ruby File.file?为真；Graphics符号链接未进入native pathCache。显式mount仍失败；正在验证关闭路径缓存 |
| 失败时内存 | 记录而不推断真机性能 | PSS649,057KiB（约634MiB），RSS749,844KiB；游戏数据探针，非地图/战斗峰值 |

原生基础探针证据：原工作区 `temp/evidence/20261016-164613-runtime-pass`；第一次失败与冷启动：`20261016-164218-runtime-loaded`、`temp/nativeload-investigation`。隔离 worktree 的完整安装和图像失败证据：`temp/evidence/20261016-170242-full-installing`、`20261016-170759-game-smoke-sprite-failure`。每份捕获包含设备 JSON、PNG、logcat、内存、Activity 和存档目录。

## 验收矩阵（未执行项不得写作通过）

| 范围 | 状态 |
| --- | --- |
| 新装完整游戏→正常标题→新开档→地图移动 | 待测；当前仅独立诊断入口 |
| 野外战斗、捕捉、正常融合、反向融合、拆分、进化 | 待测；数据模型检查不能替代动画/交互流程 |
| 普通/闪光组合、多只闪光仓库、首次配色及缓存性能 | 待修图像读取后实测 |
| 仓库存取与多箱操作、正式保存、多槽、备份 | 待测；ZIP主机测试不能替代游戏存档 |
| 杀进程→重启读取真实游戏存档 | 待测 |
| Android SAF导入导出、Windows存档迁移后继续玩 | 待测；不使用用户原件 |
| APK同签名升级、安装中断/低空间/素材损坏恢复 | 待测；安装器已有实现和真实首次安装 |
| 断网、下载中断、TLS拒绝/超时/重试 | 当前测试包无网络权限；安全适配器未完成 |
| 锁屏、音频恢复、系统杀进程 | 待测 |
| 不同屏幕/API/性能与ARM真机 | 待测；无真机，未宣称真机验收 |
| Windows完整游戏回归 | 待测；目前仅平台契约/语法检查 |

## 发布状态

已生成并安装本地测试 APK。没有上传测试渠道或公开发布。安全网络、完整玩法闭环、原生源码重建/依赖锁、16 KiB页支持、真机矩阵和正式签名仍是发布门槛。用户已确认暂用测试应用标识与本地交付，暂无Linux资源，继续调查Windows portable原生构建。

## 后续里程碑：图像、持久化、网络与标题

- 关闭不能枚举 Graphics 符号链接的 native pathCache 后，实际图像问题修复。完整游戏探针首轮 **33 PASS**，杀进程后重启 **35 PASS**，明确读取上一进程生成的专用存档。第二轮：脚本8.886s、编译数据46.473s、真实普通/闪光处理6.099s、生产拆分/仓库1.230s、专用Marshal读写1.988s。普通图与闪光图均真实288×288，绝非占位。
- 第一次正常Main加载画面的反斜杠/大小写/无扩展名路径失败，已集中在 Bitmap 构造入口修复；没有逐处改剧情/资源路径。设备临时 preload 验证通过，待随最终完整包再验收。
- 正常标题遇到旧模拟器 ARM 翻译器不支持合法 `fcvtzs s1,s1` 的 native 退出，已精确定位并以两处、共16字节的显式 emulator-only 替换验证。普通 ARM 库不改，完整上游源码未重编。原版/补丁 SHA 和源级候选见 `android/native/emulator-translation-workaround.md`。
- 使用该独立补丁后，真实原游戏标题持续绘制并显示约40FPS，截图 `temp/evidence/20261016-192648-title-native-patch`。这次设备验证使用临时 preload 与库替换，不能替代完整打包产物回归，也不代表真机通过。
- 独立API30模拟器 **网络11/11真实请求通过**：PNG哈希完全一致、UTF8 POST、自签证书拒绝、404、GET重定向、POST307不重放、20.005s总超时及随后恢复。详见 `network-smoke-report.md`，没有回退不验TLS的HTTPLite。
- 已实际用 Windows portable NDK 生成ARM64/x86_64 ELF及16KiB对齐共享库，并用MSYS2完成libiconv configure/make/install；自研Ruby→JNI桥已可重复构建并在网络探针中实际运行。**全套Ruby/OpenSSL/SDL/mkxp源码重建仍未完成**。
- 标题触控与物理键未能可靠推进；原生只读诊断确认窗口焦点存在、事件类型启用。现改用独立平台虚拟输入队列，避免依赖旧模拟器的SDL事件回调路径；208项Ruby契约、33项ZIP主机检查通过，443个Ruby文件语法通过。新输入队列尚待完整APK设备操作验证，不能记为可玩。

当前可以确认独立APK安装、原生渲染、游戏数据/拆分/仓库/专用存档重启与安全网络；地图、新档、战斗、捕捉、完整融合动画及正式保存仍未验收。
