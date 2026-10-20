# Payload v2 设备验收（2026-10-20）

**资源还原通过，重复启动已人工确认到标题。** 本报告针对修正字体诊断 loader 前的 b8 APK；
后续新版只改诊断脚本，但仍应在最终构建记录中分别标识，不能把本报告的 SHA 当作后续 APK 的 SHA。

| 项目 | 实际结果 |
| --- | --- |
| APK | `KIF-0.20.7-android.2-arm64-emulator-network-test.apk`，742,762,733 B |
| APK SHA-256 | `b8e19919adc12542391444ce750f3df9a4854d42ff9a19969aa013fe6665e2c7` |
| 源码节点 | `2975f43a`，字体诊断 `TOPLEVEL_BINDING` 单行修正前 |
| 内容 ID | `c3319515d0ca19e0cbf66284` |
| 逻辑资源 | 23,128 个路径，979,354,074 B |
| 归档布局 | 20,828 个 canonical 归档项 + 2,300 个单跳别名 |
| 设备全路径 SHA-256 | **23,128 / 23,128 通过**，实际耗时 73.656 s |
| 独立文件 | 检查全部 2,300 别名及对应 canonical，共 3,987 路径；device:inode 全部独立 |
| 清单与完成标记 | 安装后的 `.base-files.json` 与 APK 清单相等，`.complete` 与 active-content 均为目标 ID |
| 首次完整解包 | 日志实际 **805,278 ms** |
| 重复启动资源准备 | 日志实际 **1,407 ms**，复用已完成的同代内容 |
| 运行画面 | 自然进入 KIF 标题，0.20.7 / IF 6.4.5、横屏等比游戏画面和虚拟键可见；单张截图读数 31 FPS |

## 环境与前置状态

本次只操作自有 `emulator-5556` / `kif_network`，未操作主任务管理的 5554。
镜像为 Google APIs Android 11 / API 30 / revision 16，fingerprint：
`google/sdk_gphone_x86_64/generic_x86_64_arm64:11/RSR1.240422.006/12134477:userdebug/dev-keys`。
宿主使用 portable Emulator 37.2.12、WHPX、SwiftShader；客体 2 核、2,048 MiB RAM，
headless、no-audio、no-snapshot，并将 emulator/user home 指向项目 temp。
ARM64 APK 由 `libndk_translation.so` 运行；这是专用模拟器兼容包，不是 ARM64 真机验收。

AVD 沿用原数据，没有清理或重建。安装前只存在旧网络小探针内容目录
`d5ef709d0f57a7da6c0cf548`，目标 c331 目录明确返回 `ABSENT`。
所以本次覆盖的是**全新游戏资源代的安装**，不是清空整个 AVD 后安装；原探针与私有数据保留。
未读取 Windows 存档，未进行存档导入、故事选择或任何剧情按键。

启动进程身份已记录：launcher PID 66800、其 qemu child PID 60136，命令行明确为
`-avd kif_network -port 5556 ... -memory 2048 -cores 2`。本次没有终止或重新配置该 AVD；
最后保留运行在标题并交接给主任务。

## 安装与异常记录

第一轮 `adb install --no-incremental -r` 在 300 秒 host 超时，之后旧 base.apk 仍为
25,868,525 B，不能算安装成功。日志出现 AppIntegrity 超时、Google Search/Videos 的启动后台任务 ANR，
内存压力 PSI `some avg10=99.43%`、`full avg10=92.61%`；还保留了系统进程死亡和 Bluetooth 崩溃日志。
这些发生在未运行 KIF 游戏时，不能记作 KIF 剧情崩溃，也不能据此宣称支持 2 GiB 手机。

替代方案将传输和安装拆开：

1. push 完整 APK 到专用 `/data/local/tmp/kif-port-payload-b8e19919adc1.apk`，耗时 12.469 s，
   adb 报 57.1 MB/s。
2. 设备 `sha256sum` 耗时 4.015 s，精确匹配上述 b8 SHA。
3. 从已验证的本地文件 `pm install -r`，耗时 149.188 s，实际返回 `Success`。
   包元数据确认 versionCode 2，user 0 installed=true、hidden=false、suspended=false、CE available=true。

没有再安装同一个包。可选的旧 APK 回拉快照过慢，默认 pull 与 `pull -Z` 分别限时终止；
其本地残留已标记 `input-b8.apk.partial-unusable`，**不是有效 APK，也不是交付物**。
冻结二进制副本没有继续阻塞验收：已验证的设备输入 SHA、本地安装成功记录、历史 commit 与原 APK
清单足以定位本次输入，后续以实际设备文件校验为主。

第一次 `am start -W` 的返回码为 0，但正文为 Error type 3 / Activity does not exist。
当时没有 c331 目录，所以早期脚本的 `installing: Xs` 只是等待计时，**不是解包进度**；
这些无效等待不计入上表耗时。随后只读解析已能找到正确 Launcher，显式 user 0 / 完整组件名再次启动
返回 `Status: ok`，COLD TotalTime 8,830 ms，并确认 c331 目录已创建，才进入实际解包。
测试脚本已修正为检查 Activity Manager 正文和目录，避免再把零返回码误当成功。

可选 screencap 曾超时、系统处于 Awake / Display ON 却捕获黑画面；测试监控因此暂停，但没有停止 App。
后续将截图改为非阻断，并接着等待既有 Installer，没有重装或再启动安装器。
真正的解包进度另有私有目录磁盘占用快照，最终以 KIF-Install 的 805,278 ms 日志及完成标记为准，
不使用恢复监控后的局部等待时间冒充完整耗时。

## 游戏进程与重复启动

首次解包后自动启动 `:game`，系统记录其进程未在规定时间 attach，随后因 start timeout 被杀；
不能把这一轮自动进入游戏记为通过。本次没有 KIF Ruby/原生崩溃的对应证据。

完成全文件与 inode 校验后，测试按计划 force-stop 测试 App 再启动。
Installer 在 1,407 ms 内准备好同代内容，新 `:game` 启动并运行 SDL_main。
最初截图是 LOADING，未冒充标题；继续无输入自然等待后，`natural-title-final.png` 已人工确认
显示真实 KIF 标题、版本和虚拟按键，截图时瞬时 31 FPS。

这只覆盖标题启动和资源安装。未在此设备进行地图、战斗、捕捉、融合、闪光、仓库、保存或读档；
这些项目由其他报告分别验收。没有音频设备输出验收（此 AVD 使用 no-audio）。

## 性能解释和证据边界

- 2 GiB 客体在 boot 后台任务期间存在严重内存压力、系统重启/崩溃和很慢的首解包。
  805 秒是这个具体模拟器环境的真实结果，不是手机安装时间的估算，也不能与另一个负载状态的
  3 GiB AVD 耗时直接做压缩策略优劣比较。
- `all-files-device-sha256.stdout` 包含每个原始逻辑路径的校验结果，而不只是归档 canonical。
  `alias-inodes.json` 检查了所有别名组，不是抽样。
- `final-meminfo.stdout` 只匹配主进程 `org.kuray.kif`，PSS 50,342 KiB / RSS 140,040 KiB；
  **没有包括 `org.kuray.kif:game`，不能作为游戏内存数值**。后续应按 `:game` 或 PID 单独采样。
- 31 FPS 是单张标题截图的瞬时读数，不是平均 FPS 或地图性能测试。
- 未验证真机、16 KiB 页、其他 Android 版本、安装进程被杀后的恢复、图像跨代定制迁移或正式签名升级。

## 证据

完整证据位于工作区 `temp/evidence/payload-device/`，未提交二进制或大日志。

- `result.json`、`commands.json`：结果、命令、耗时。
- `content-before.stdout`、`new-content-absent-before.stdout`：目标代不存在的前置证据。
- `apk-payload-manifest.json`、`installed-manifest.stdout`、`complete-marker.stdout`：清单和完成标记。
- `apk-push-result.json`、`pushed-apk-device-sha256.stdout`、`local-pm-install-result.json`：输入和安装。
- `all-files.sha256`、`all-files-device-sha256.stdout`、`alias-inodes.json`：全量字节与独立文件证据。
- `actual-installer-log.txt`、`actual-crash-buffer.txt`、`final-logcat.stdout`：环境异常及安装日志。
- `first-launch-error3-before-retry.stdout`：保留先前启动失败，不与真实安装进度混淆。
- `repeat-title.png`：当时仍是 LOADING；`natural-title-final.png`：人工确认的标题画面。
