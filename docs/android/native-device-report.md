# 原生组件与完整源码运行时探针实测

2026-10-20，Asia/Shanghai。**混合组件探针与完整源码运行时探针均已在模拟器实际通过基础闭环**：安装、原生库加载、Ruby 标准模块功能、私有诊断文件写读、JNI 桥、字体及 120 帧画面更新。两轮主游戏 QA 存档的前后哈希清单完全相同。

这是独立诊断 APK 的结果。未使用真机，未在完整源码运行时上验收 KIF 剧情、战斗、融合、仓库、生命周期或完整游戏存档兼容性。当前正常游戏 APK 的 GUI 结果见相应游戏报告，不能互相替代。

## 设备与固定输入

| 项目 | 本次范围 |
| --- | --- |
| 设备 | 自建 `emulator-5554` / `kif_api30`，`sdk_gphone_x86_64` |
| 系统 | Android 11 / API 30；4 KiB 内存页 |
| 系统 fingerprint | `google/sdk_gphone_x86_64/generic_x86_64_arm64:11/RSR1.240422.006/12134477:userdebug/dev-keys` |
| 执行方式 | WHPX、SwiftShader；ARM64 库由 `ndk_translation` 0.2.2 执行，非 ARM 真机 |
| 画面 | 1280×720 横屏截图，游戏画布 512×384 等比显示 |
| 应用 | `org.kuray.kif.nativeprobe`，测试签名，标签 `Native Ruby Probe`；与 `org.kuray.kif` 独立 UID/私有目录 |
| 源码基线 | mkxp-z `68653811c3c396f2d4c12225c52c407746285a3d`；源码 SDL2 `d3ac4c3742a405e719071fc4f5a7ba8a125c76a1` |
| 目标构建 | ARM64/API 30，NDK r25c `25.2.9519653`；Java compile/target API 35 |
| 实测 Ruby | `3.4.10` / `aarch64-linux-android-android`；Marshal `4.8` |
| 实测模块 | OpenSSL `3.0.12`、Zlib `1.2.12`、Socket、Digest SHA-256 |

设备配置延续[模拟器验证环境](test-report.md)；本轮 logcat 再次确认 ARM64 翻译器 0.2.2。未将 compile/target API 35 写成已测 Android 15。

| 包 | 字节数 | SHA-256 | 原生来源 |
| --- | ---: | --- | --- |
| `Native-Ruby-Probe-arm64-emulator-test.apk` | 25,426,026 | `436e448104b30f3d44a7cab5bdc65572ab30764e916560d23f1799fddce11c3f` | 固定历史引擎/SDL，替换本次源码 Ruby/OpenSSL，显式旧翻译补丁 |
| `Native-Full-Runtime-Probe-arm64-test.apk` | 26,642,468 | `4185c549967455c5fdd1a531ecbbdfc7b71bcaed73dd80224d06b7329acf4952` | 新源码 core/依赖/SDL Java，已有源码 JNI 桥；固定 NDK C++ 标准运行时例外，无旧 16 字节翻译补丁 |

完整源码包使用单独 packaged core，SHA-256 `fab5f32f2642d7ac58d552a3e3dd1f75fabc16e22f274e7ff70364d2a3d3a96c`。原 raw core 的 Meson RUNPATH 通过固定官方安装清理处理；所有 `.dynamic` 之外字节保持一致。详情见[构建记录](windows-native-core.md)及[依赖构建](windows-native-build.md)。

## 步骤、预期与实际

由根设备任务独占模拟器执行，构建子任务仅分析文件。每轮检查 APK 哈希，安装/升级诊断应用，冷启动专用 Launcher，等待 JSON 的 terminal `pass`/`fail`；Java `native_start_pending` 不被当作通过。保留私有结果、logcat、截图、内存快照及主游戏 QA 哈希。结束后停止诊断进程，再交回游戏 GUI 测试。

| 检查 | 预期 | 两包实际结果 |
| --- | --- | --- |
| 安装与原生初始化 | 可启动独立 ARM64 应用并进入 Ruby | PASS；最终 PID 分别 18937 / 19186，均有翻译器与 OpenSL 后端初始化日志 |
| 私有路径 | 同一应用的 Android 路径别名可解析，输出只在 `files/native-probe/` 子目录 | PASS；expanded files 为 `/data/user/0/...`，实际 canonical files/output 均 `/data/data/...` |
| 标准模块 | `openssl/socket/zlib/digest/digest/sha2` 均可 require | PASS；逐模块日志与最终结果齐全 |
| 摘要与 Socket | Digest/OpenSSL SHA-256 符合已知 `abc` 向量；Addrinfo 解析本地地址 | PASS |
| Zlib | 含 NUL/中文 UTF-8 字节的 768 字节数据压缩/解压相同 | PASS |
| 原始 Marshal | 必须存在 `_mkxp_load_alias`，私有新写 `probe.dat` 经原生加载后整个对象严格 `== original` | PASS，`nativeAliasStrictBinaryEqual=true` |
| 公共 RGSS Marshal | 严格等于独立构造的 expected UTF-8 对象；每个字符串字节及值类型保持 | PASS，`publicLoadStrictExpectedUTF8Equal=true`、deep bytes/types=true；明确观察 ASCII-8BIT→UTF-8，而非删掉失败断言 |
| JNI 桥 | 新 Ruby 可加载已有源码桥，`input_poll == [0,0,0]` | PASS |
| 字体与画面 | Power Green 可用、字形实际产生像素、可见诊断文本、更新 120 帧 | PASS；两轮均 1,859 个离屏字形 ink pixels，实际 PNG 均有蓝灰背景与白字 |
| 隔离 | 主游戏 QA 存档/设置在诊断前后不变 | PASS；两轮 before/after 哈希 JSON 逐字节一致，备份 tar 保留 |

无 INTERNET 权限，没有 TLS 握手、下载或音频播放测试。OpenSSL 摘要函数及 OpenSL 后端初始化不能替代这些验证。

## 性能快照

| 观测 | 混合组件 | 完整源码 |
| --- | ---: | ---: |
| 120 帧循环 | 3.13942 s | 3.09922 s |
| 该循环平均速率 | 38.22 FPS | 38.72 FPS |
| Launcher 到 terminal JSON 的 harness 墙钟 | 13.250 s | 11.406 s |
| 最大纹理 | 8,192 | 8,192 |
| 字体 ink pixels | 1,859 | 1,859 |
| 采样 TOTAL PSS | 145,470 KiB | 146,485 KiB |
| 采样 TOTAL RSS | 264,708 KiB | 265,324 KiB |

帧循环设置为 40 FPS。上述数值各只有一次成功样本；harness 墙钟含准备/加载/模块/字体/帧循环与轮询，不能解释为纯引擎初始化时间。`am start -W` 的 COLD 是应用进程启动状态，不是重新冷启动 AVD。内存是在静态诊断画面之后采样，未测峰值、完整素材、地图、大量闪光或仓库，不据此推断真机性能或两方案快慢。

实际两张 PNG 均为 1280×720、189 种 RGB 颜色，逐像素相同，SHA-256 均为 `523b14fc6c69514abb55bf4a07ecf9496cacf35bab5b3f430187cd36f799dae8`。主要像素为 680,515 个 RGB(25,38,55)、230,400 个黑色边栏和 2,380 个纯白字像素；独立 PIL 分析与文件哈希可复查，不依赖图片预览工具。

| 混合组件截图 | 完整源码截图 |
| --- | --- |
| [probe-screen.png](../../temp/evidence/native-ruby-device-contracts/probe-screen.png) | [probe-screen.png](../../temp/evidence/native-full-device-contracts/probe-screen.png) |

## 已保留的失败与修正

1. 首个混合包 `da1ff490...` 到达 Ruby 后路径 guard FAIL。Java canonical output 与 `getFilesDir.absolutePath` 的 `/data/data`、`/data/user/0` 表述不同。改为双端 `File.realpath` 后保留严格私有子边界；8 项主机 guard 回归通过，最终设备日志证实别名根因。
2. 修路径后的混合包 `686a8a3a...` 与完整源码包 `de264e77...` 在公共 Marshal 直接比较原二进制标签对象时 FAIL。固定引擎 `binding/filesystem-binding.cpp:215–295` 本就给公共 load 注入 `stringForceUTF8`，对 ASCII-8BIT String 仅改 UTF-8 标签。根任务导出的自己新写 829 字节 `probe.dat` 经 host Ruby 3.2 原始 Marshal 解码严格相等；最终设备诊断又确认 768 字节内容 SHA 相同、仅 encoding 不同。探针改成上述两套明确合约，运行时实现未修改；561 项主机诊断/负向回归通过，再由两次设备执行验收。

旧 APK、哈希、构建记录保留在两个 probe 输出目录的 `history/`。初始路径失败、初始编码合约失败的 device-result/logcat/截图也保留；未把历史失败覆写成通过。

## 证据与复现入口

- 混合成功：[device-result](../../temp/evidence/native-ruby-device-contracts/device-result.json)、[probe-result](../../temp/evidence/native-ruby-device-contracts/probe-result.json)、[logcat](../../temp/evidence/native-ruby-device-contracts/logcat.txt)、[meminfo](../../temp/evidence/native-ruby-device-contracts/meminfo.txt)。
- 完整源码成功：[device-result](../../temp/evidence/native-full-device-contracts/device-result.json)、[probe-result](../../temp/evidence/native-full-device-contracts/probe-result.json)、[logcat](../../temp/evidence/native-full-device-contracts/logcat.txt)、[meminfo](../../temp/evidence/native-full-device-contracts/meminfo.txt)。
- 独立文件摘要：[device-evidence-summary.json](../../temp/native-full-probe/device-evidence-summary.json)，包含截图颜色/哈希、性能和 QA 清单比较；未调用设备。
- 历史失败：`temp/evidence/native-ruby-device`、`native-ruby-device-canonical`、`native-full-device-initial`，以目录内的 APK hash / PID / stage 区分。
- 构建与主机检查：[mixed 说明](../../android/native-probe/README.md)、[full 说明](../../android/native-probe/full-runtime-README.md)。静态构建记录保持其构建时 `deviceExecuted=false`，设备结果追加在本报告和独立 evidence 中，不回填篡改旧记录。

完整源码 APK 的 21 个必要库、43 个 payload 和 3,727 个强导入已静态审查；GNU 版本/指定 provider 必须在各自实际 `DT_NEEDED` 可达闭包中满足，只使用 9 个实际需要的 API30 系统 stub。独立复核也从 `PT_DYNAMIC` 读取实际 APK 库，依赖/SONAME/无 RUNPATH 与记录一致。

独立审查另发现构建输出根被人为替换为 Windows junction 时的 IO 边界缺口，当前实际输出均为普通目录，未影响上述包。后续构建器在任何写入/清理前校验 lexical 与 resolved 专用 temp 边界并逐级拒绝 reparse point，递归清理前检查整个目标子树；11 项主机测试使用 11 个真实 junction 全部通过。修前构建器按 SHA 留存在 `temp/native-full-probe/history/tested-builders`；两个已测 APK 与构建记录哈希未变化，未为这个仅主机 IO 修复再次安装或改动探针运行时。

## 仍未覆盖

没有真机、其他 Android 版本、16 KiB 页、重负载/长时间/温控测试。NDK r25c 的固定 `libc++_shared.so` 是唯一未在此重建的工具链标准库例外，其 LOAD 为 4 KiB，因此**整体 APK 不具备 16 KiB 兼容结论**。

完整源码运行时尚需用实际 KIF 包重跑剧情、新开/读档、捕捉、融合/拆分/进化、仓库、闪光、联网/离线与生命周期等验收。这里没有完整剧情通关、Windows 玩家存档迁移成功或公开发布结论。
