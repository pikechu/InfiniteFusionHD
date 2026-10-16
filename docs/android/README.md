# KIF Android 工程

本目录记录实际进展与限制。开发分支：`codex/android-port-v1`，从干净的 `main`（`7ed0deda`）建立，工作树位于原仓库 `temp/android-verify`。原目录后来出现并行联机功能开发，本移植已隔离，只迁入 Android 改动。未运行原安装更新器、未重置原工作区、未读取或覆盖 Windows 玩家存档。临时工具、下载、签名和构建产物全部在仓库 `temp/`，不提交。

## 架构

独立应用 `org.kuray.kif`，测试名称 `KIF Android Test`，版本 `0.20.7-android.1`。当前实验范围为 Android 11/API 30 以上、ARM64、4 KB 内存页；compile/target API 35。范围是构建配置，实际兼容性以测试报告为准。尚未公开发布。

- 原生 RGSS：固定 warmwinter/mkxp-z `68653811c3c396f2d4c12225c52c407746285a3d`。当前使用固定 SHA256 的上游预编译原生库；**原生源码重建尚未验证**。确切 Ruby 版本见运行时证据；二进制版本串为 3.4.10。见 [运行时调查](runtime-research.md) 和 `android/runtime.lock.json`。
- Android 壳：Java + SDL bootstrap，512×384、40 FPS 配置、横屏等比缩放。方向键和 C/X/Z/A/S/D/Q/W 虚拟键，侧边按键避免遮挡游戏；Android 返回映射 X。保留原 UI。默认用光标界面输入名字，软键盘入口需实机验证。
- 虚拟输入：小型源代码构建的 `libkif_android_bridge.so` 为每个 APK 的必要扩展。Java 按钮通过互斥队列提交 RGSS 逻辑键，Ruby 轮询 held/triggered/released 掩码；此路径不调用 SDL 按键回调。物理键盘保留原 SDL 路径。启动/暂停清空所有虚拟状态，避免粘键或恢复时误触发。该后端已实现并编译，实际游戏连通性以随后运行报告为准。
- 安装：白名单收集 Audio/Data/Graphics/Fonts 和 Android preload，不收集 temp、Windows 可执行程序、存档、导出宝可梦。每文件 SHA256、总数和总字节校验；后台安装有进度，失败不启动半套素材；重复打开用同一进程互斥。
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
NDK 只用于构建必要的小型输入/可选 HTTPS 扩展，尚未用于完整重建上游运行时。
所有包均校验 helper 与当前 C 源码及 provenance 匹配，缺失或过期时提示先执行
`build_bridge.ps1`。默认离线包也包含 helper，但仍没有 INTERNET 权限；
`--with-network` 仅启用额外网络权限及 HTTPS 功能。

离线重建已有输入：`bootstrap-tools.ps1 -SkipDownload`、`prepare-runtime.ps1 -Offline`。更改游戏代码或 preload 后必须重打 payload；仅修改 Java 时可用 `build_apk.py --skip-payload`，运行前需核实 staged 游戏源码与当前代码匹配。

输出：`temp/artifacts/KIF-0.20.7-android.1-arm64-test.apk`、SHA256 文件、构建记录。开发签名只在 `temp/android-signing`；不能用于正式发行。不得提交密钥。重新生成测试密钥后，已有安装不能原地升级，需先导出存档。

Android 11 x86_64 AVD 的旧版 ARM 翻译器不能执行上游库中两处合法的 AArch64
标量转换指令。需要该特定兼容路径时，先生成独立、严格哈希固定的库，再显式选择模拟器变体：

```powershell
& '<Python>' scripts/android/patch_emulator_runtime.py --ndk temp/tools/android-ndk-r25c
& '<Python>' scripts/android/build_apk.py --emulator-compatible
# 可选启用安全 HTTPS（必要的 helper 已在前面构建）：
& '<Python>' scripts/android/build_apk.py --emulator-compatible --with-network
```

对应输出为 `KIF-0.20.7-android.1-arm64-emulator-test.apk` 和
`KIF-0.20.7-android.1-arm64-emulator-network-test.apk`；其构建目录与普通包分开，
不会覆盖普通手机 APK 或共享的原版原生库。首次生成某一变体必须先打完整 payload，
之后才能对该变体使用 `--skip-payload` 或 `--refresh-ruby`。
库或 provenance 缺失、输入/输出 SHA256 不符时立即失败，不回退为普通包。
构建记录包含 `emulatorOnly: true`、原版与补丁 SHA256、源级候选补丁及审计 provenance。
这只是对固定上游预编译库的 16 字节转换指令替换，**没有完成整个运行时源码重编**，
也不能据此声明普通 ARM 手机包已经通过真机或 16 KiB 页验收。
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

本轮分别通过 38、11、52、38 项断言，共 139 项。网络桥使用 mock，本地落盘使用临时真实文件及断写/fsync/rename 故障注入，不连接网络或读取玩家存档。Windows 分支保留原 HTTP 参数透传、直接 `File.open(..., "wb")` 行为，且不安装 Bitmap hook；这些已有契约覆盖，真实 Windows 游戏回归仍需执行。见 [测试策略](platform-test-strategy.md)。

## 当前里程碑与后续门槛

| 阶段 | 状态 / 退出条件 |
| --- | --- |
| 环境和静态核实 | 已完成仓库检查、分支、依赖固定、官方源码接口核实；见各报告 |
| 最小工程和平台适配 | 已实现；平台契约 38 项通过，Ruby 语法检查通过；不等于 Android 运行通过 |
| 独立 APK | 已成功编译、打包和验证测试签名；设备安装与启动待记录 |
| 首个运行闭环 | 待实际执行：启动、新开档、移动、战斗捕捉、融合拆分、闪光、仓库、保存、杀进程读档 |
| 产品适配 | 安全下载、存档 SAF、中断恢复、输入、安全区与生命周期需按实际测试完善 |
| 性能 | 待记录设备、帧率、PSS、首次安装/启动/配色耗时；模拟器数据不能代表真机性能 |
| 源码发布构建 | 原生依赖及二级依赖锁、POSIX 构建环境、16 KB 页重建、签名和干净重建是后续门槛 |
| 发布 | 用户确认先本地测试包；没有上传任何测试渠道或公开商店 |

工期重新估算必须等首次 Android 启动和核心路径验证后进行。目前给出带前提的工程预算，而不是承诺：运行闭环及兼容修复约 3–10 工程日；安全网络/存储/生命周期和输入完善约 5–15 日；真机矩阵、性能和发布加固约 5–10 日。合计约 13–35 工程日，若 GLES/地图渲染或 Ruby 数据存在深层不兼容会超出该范围。首次闭环失败时先按具体日志修复或切换已调查备用运行时，随后重估。
