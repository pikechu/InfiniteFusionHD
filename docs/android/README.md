# KIF Android 工程

本目录记录实际进展与限制。开发分支：`codex/android-port-v1`，从干净的 `main`（`7ed0deda`）建立，工作树位于原仓库 `temp/android-verify`。原目录后来出现并行联机功能开发，本移植已隔离，只迁入 Android 改动。未运行原安装更新器、未重置原工作区、未读取或覆盖 Windows 玩家存档。临时工具、下载、签名和构建产物全部在仓库 `temp/`，不提交。

2026-10-21 按用户要求，将 Android.8 特性合并到已有联机/统计功能的最新 main；dev 未改。合并检查与兼容清单更新见 [main 合并记录](main-integration-2026-10-21.md)。既有 Android.8 APK 和设备报告对应特性分支 `272e3f90`，不当作合并后全部功能的设备验收。

## 架构

独立应用`org.kuray.kif`，测试名称`KIF Android Test`，当前本地测试版本`0.20.7-android.8`（versionCode8）。手机/模拟器包已构建签名；新增默认保持比例 / 拉伸填满、即时切换和选择持久化，实际运行状态见[Android.8设备报告](android8-device-report.md)。半透明按键及大小设置历史验收见[Android.7](android7-device-report.md)，键盘、SAF及无Mod冷读见[Android.6](android6-device-report.md)。实验范围为Android11/API30以上、ARM64、4KB内存页；compile/target API35。范围是构建配置，实际兼容性以测试报告为准。尚未公开发布，最新状态见[发布说明](release-notes.md)和[滚动进度](progress.md)。

- 原生RGSS：固定warmwinter/mkxp-z `68653811c3c396f2d4c12225c52c407746285a3d`。游戏APK当前使用固定SHA256上游预编译库。Windows portable已实际编译固定依赖、Ruby3.4.10和完整core；独立源码运行时探针在API30模拟器通过模块、Marshal、JNI、字体和120帧验证，未使用旧二进制翻译补丁。尚未替换游戏APK，也不代表真机或游戏全功能通过，见[组件构建](windows-native-build.md)、[core构建](windows-native-core.md)。原运行时来源见[调查](runtime-research.md)和`android/runtime.lock.json`。
- Android 壳：Java + SDL bootstrap，512×384、40 FPS 配置、横屏默认保持比例，可在「⋯ → 显示模式」切换拉伸填满并记住选择，见[显示模式](display-modes.md)。半透明方向键、确认和返回悬浮于最大化的游戏画面；其他键、键盘、存档及按键大小设置收进「⋯」。支持65%–150%预览/保存/取消/默认，Android 返回映射 X。保留原 UI，Windows 保持原缩放行为。见[按键使用说明](touch-controls.md)。
- 字体：Android 配置 `fontHeightReporting=1`，保留原 TTF、字号与行距。真实运行时对照中，旧模式8/8字体裁切，新模式8/8完整像素与原生参考一致；见[字体报告](font-rendering-report.md)。实际菜单字体和新包回归另见[Android.2 GUI报告](gui-regression-report.md)。
- 虚拟输入：小型源代码构建的 `libkif_android_bridge.so` 为每个 APK 的必要扩展。Java 按钮通过互斥队列提交 RGSS 逻辑键，Ruby 轮询 held/triggered/released 掩码；此路径不调用 SDL 按键回调。物理键盘保留原 SDL 路径。启动/暂停清空所有虚拟状态，避免粘键或恢复时误触发。该后端已实现并编译，实际游戏连通性以随后运行报告为准。
- 安装：白名单收集 Audio/Data/Graphics/Fonts 和 Android preload，不收集 temp、Windows 可执行程序、存档、导出宝可梦。每文件 SHA256、总数和总字节校验；后台安装有进度，失败不启动半套素材；重复打开用同一进程互斥。
- 无损体积：全部资源DEFLATE6并按内容去重，安装时恢复所有原路径为独立文件。首次优化由800.14降至708.35MiB，当前Android.6为708.36MiB；备用模拟器已实际验证23,128条路径SHA与2,300个别名独立inode，见[资源设备报告](payload-device-report.md)。这不会同比缩小约934MiB的解包资源。
- 素材：`files/content/<payload-id>` 保存版本化基础素材；`files/writable/Graphics-<id>` 是该版本可写图片树，通过私有符号链接接入游戏。升级完成后迁移上一版本下载或修改的图片，旧版本仍保留供恢复，安装失败不改旧版本图片。Cache/ExportedPokemons/Mods 各有独立可写目录。后续需要容量治理。
- 存档：`files/saves` 独立于素材版本，preload 在 SaveData 定义前重定向 `System.data_directory`。保留原 Marshal 格式、多存档和备份实现。Android 卸载会删除私有数据，迁移前应导出。
- 网络：所有有效请求集中到 `KIF::Platform`。默认构建无 INTERNET 权限且保持离线；可选 Java TLS 桥使用 Android 平台证书/主机名验证，Ruby 适配器仅在显式开启且桥加载成功后安装，不回退到原生不验证证书的 HTTPLite。GET 有限重定向/重试，POST 不跟随重定向、不自动重放。精灵落盘使用同目录临时文件、fsync 和原子替换，失败保留旧缓存；PNG/GIF 检查 magic。真实 TLS、超时、离线和下载仍以设备测试报告为准，不能凭本地契约测试宣称已验收。
- 生命周期：独立 `:game` 进程承载 MRI，暂停释放虚拟按键并暂停 native；退出销毁游戏进程避免第二次初始化 Ruby VM。实际后台、锁屏、音频恢复仍需验证。
- Windows：共享平台接口在 Windows 透传原 HTTP，不改新存档默认值；BAT/EXE/Explorer 隔离仅作用于 Android。两个 500ms 异常窗口改用单调秒时钟，兼容新版运行时的时间单位。

## 构建与调试

在仓库根目录，用 PowerShell：

```powershell
./scripts/android/bootstrap-tools.ps1
./scripts/android/prepare-runtime.ps1
# 先准备 portable NDK r25c，路径见 toolchain.md：
./scripts/android/build_bridge.ps1
& '<Python 3.11+ 的完整路径>' scripts/android/build_apk.py
```

工具脚本固定 portable JDK、SDK 平台和 build-tools，不修改全局环境。受限网络环境需要限定下载命令的授权，脚本保留调用者代理设置。无需安装 Android Studio；Java/D8/aapt2/zipalign/apksigner 直接构建 APK，无 Gradle 在线依赖解析。环境版本与实跑证据见 [工具链](toolchain.md)。
当前游戏APK中本项目源码构建的原生部分是输入/HTTPS小型扩展；temp已有Windows portable源码构建的完整运行时探针及模拟器运行证据。游戏APK的原生库升级与完整玩法回归仍单独推进。
所有包均校验 helper 与当前 C 源码及 provenance 匹配，缺失或过期时提示先执行
`build_bridge.ps1`。默认离线包也包含 helper，但仍没有 INTERNET 权限；
`--with-network` 仅启用额外网络权限及 HTTPS 功能。

离线重建已有输入：`bootstrap-tools.ps1 -SkipDownload`、`prepare-runtime.ps1 -Offline`。更改游戏代码或 preload 后必须重打 payload；仅修改 Java 时可用 `build_apk.py --skip-payload`，运行前需核实 staged 游戏源码与当前代码匹配。

输出：`temp/artifacts/KIF-0.20.7-android.8-arm64-test.apk`、SHA256 文件、构建记录。启用网络时文件名增加 `-network`。开发签名只在 `temp/android-signing`；不能用于正式发行。不得提交密钥。重新生成测试密钥后，已有安装不能原地升级，需先导出存档。

Android 11 x86_64 AVD 的旧版 ARM 翻译器不能执行上游库中两处合法的 AArch64
标量转换指令。需要该特定兼容路径时，先生成独立、严格哈希固定的库，再显式选择模拟器变体：

```powershell
& '<Python>' scripts/android/patch_emulator_runtime.py --ndk temp/tools/android-ndk-r25c
& '<Python>' scripts/android/build_apk.py --emulator-compatible
# 可选启用安全 HTTPS（必要的 helper 已在前面构建）：
& '<Python>' scripts/android/build_apk.py --emulator-compatible --with-network
```

对应输出为 `KIF-0.20.7-android.8-arm64-emulator-test.apk` 和
`KIF-0.20.7-android.8-arm64-emulator-network-test.apk`；其构建目录与普通包分开，
不会覆盖普通手机 APK 或共享的原版原生库。首次生成某一变体必须先打完整 payload，
之后才能对该变体使用 `--skip-payload` 或 `--refresh-ruby`。
库或 provenance 缺失、输入/输出 SHA256 不符时立即失败，不回退为普通包。
构建记录包含 `emulatorOnly: true`、原版与补丁 SHA256、源级候选补丁及审计 provenance。
该游戏变体使用固定上游预编译库的16字节转换指令替换。另行构建的完整源码运行时已通过独立模拟器探针，尚未接入游戏包；两条证据不能混用，也不能据此声明普通ARM手机包已通过真机或16KiB页验收。
具体指令、寄存器审查及源码候选见 [模拟器兼容说明](../../android/native/emulator-translation-workaround.md)。

```powershell
& '<Python>' scripts/android/device_check.py install
& '<Python>' scripts/android/device_check.py launch
& '<Python>' scripts/android/device_check.py capture --label title
```

`runtime-smoke` / `game-smoke` 动作为明确选择的开发诊断，不是玩法验收；日志、设备属性、截图与内存在 `temp/evidence`。`build_apk.py --runtime-only` 产物仅含运行时探针，**不含游戏**，不能作为游戏交付。
`--runtime-only --with-network` 仍生成独立的 `KIF-network-probe-arm64-test.apk`；
另外选择 `--emulator-compatible` 时会生成 `KIF-network-probe-arm64-emulator-test.apk`，
不会覆盖已验证的普通网络探针。真实联网证据见 [网络探针报告](network-smoke-report.md)。

本地平台/传输/落盘回归，在仓库根目录执行：

```powershell
$ruby = (Resolve-Path 'temp/tools/ruby-3.2.9/rubyinstaller-3.2.9-1-x64/bin/ruby.exe').Path
& $ruby --disable-gems android/tests/platform_contract_test.rb
& $ruby --disable-gems android/tests/bitmap_path_contract_test.rb
& $ruby --disable-gems android/tests/http_adapter_test.rb
& $ruby --disable-gems android/tests/download_write_test.rb
```

`run_host_checks.ps1` 还执行输入桥、真实自由文本流程、桌面按键配置、独立启动说明和标题丢键回归，随后编译 Ruby 脚本并执行真实本地存档 ZIP/文件事务测试。主机测试不构成设备游玩验收。网络桥的主机测试使用 mock；落盘使用临时真实文件及断写/fsync/rename 故障注入。Windows 分支保留原 HTTP 参数透传和直接写文件行为，且不安装 Bitmap hook；真实 Windows 游戏回归仍需执行。见 [测试策略](platform-test-strategy.md)。

## 当前里程碑与后续门槛

| 阶段 | 状态 / 退出条件 |
| --- | --- |
| 环境和静态核实 | 已完成仓库检查、分支、依赖固定、官方源码接口核实；见各报告 |
| 最小工程和平台适配 | 已实现；平台契约62项、444 Ruby文件编译通过，实际结果按版本分开记录 |
| 独立 APK | Android.8手机/模拟器包已构建签名；原6GiB AVD保留数据重装，20案例197触控断言及两种显示模式/按键/选择持久化通过，31存档SHA不变，无真机证据 |
| 修复回归闭环 | Android.2 最终7279包已实际通过标题移动期单次确认、4种GUI字体、移动、野战/捕捉、普通融合/拆分、仓库存取、G槽保存、杀进程及相同位置/队伍/HP冷读；见[本轮GUI报告](gui-regression-report.md)。原Android.1新档/训练家结果单列[旧报告](gui-playtest-report.md)；.4/.5闪光与.6实际SAF/无Mod冷读已通过，见本版设备报告 |
| 产品适配 | 历史SAF导入/恢复/拒绝、资源中断恢复、空档说明已有实测；.7新增半透明控件、大小持久化、折叠IME、SAF后首次960×720通过，其他系统/生命周期/网络矩阵待补 |
| 性能 | 已记录模拟器 FPS、PSS、安装/配色耗时，见 GUI/集成报告；尚未测大量闪光仓库、峰值/长期增长，不能代表真机性能 |
| 源码发布构建 | Windows portable完整core/固定依赖编译及独立运行时探针通过；游戏包集成、整体16KiB、正式签名、干净环境重复构建仍待验收 |
| 发布 | 用户确认先本地测试包；没有上传任何测试渠道或公开商店 |

标题确认与字形裁切修复在Android.2实测；.3补充选槽绑定，.4/.5保留文本历史问题，.6重开IME及实际SAF/无Mod冷读通过。.7增加半透明控件、65%–150%大小与持久化，实际移动/队伍/满箱闪光/命名备份/保存冷读及SAF首启全屏通过；没有把历史战斗融合结果移记为本版全量通过。Windows portable完整源码运行时探针已通过，完整游戏接入仍待验证。当前工作量估算见[滚动进度](progress.md)，体积与QA存储分别见[APK体积](apk-size.md)、[AVD维护](avd-storage.md)。
