# Android.8 本地测试发布说明

2026-10-21，`0.20.7-android.8` / versionCode 8，`org.kuray.kif`，KIF Android Test。普通 ARM64 与模拟器专用 APK 均已构建并通过签名校验。仅本地测试签名，未公开发布；手机包未真机验证。

## 变化

- 「⋯ → 显示模式」新增 **保持比例（默认） / 拉伸填满**。点选后即时生效、自动保存，关闭进程后重启保留。
- 保持比例完整显示 4:3；拉伸填满不裁切内容，宽屏下横向变宽。方向键、确认、返回和菜单保持原有屏幕位置、形状与大小设置。
- 启动配置与运行中切换使用同一份私有偏好，不改写游戏存档。图形视口通过 mkxp 的现有接口在游戏线程更新；暂停和清除按键不重置显示模式。Windows 缩放行为保持原样。

使用说明见 [显示模式](display-modes.md)，原按键设置见 [虚拟按键](touch-controls.md)。

## APK 与复现

目录：`temp/artifacts/`。两个包各 742,775,021 字节（约 708.37 MiB），素材快照 ID `bfbb9a9a05db91abab51e7f2`。

| 文件 | SHA256 |
| --- | --- |
| `KIF-0.20.7-android.8-arm64-network-test.apk` | `3e60b2ef7ec0c5263fa56d44cf0e1df7d3292bcfb7d328d5523dfd672ab10d2c` |
| `KIF-0.20.7-android.8-arm64-emulator-network-test.apk` | `607103aad5242c17dce4e391277b17a8608d282306b35a06a953c804aee23976` |

每个 APK 附有 `.sha256` 和 `-build-record.json`。原生运行时继续使用固定上游预编译 core；本次重建的是 JNI 输入/设置桥。普通 ARM64 包用于手机，模拟器包仅适用于已记录的旧 ARM 翻译环境。

```powershell
& scripts/android/build_bridge.ps1
& scripts/android/run_host_checks.ps1
& '<Python 3.11+>' scripts/android/build_apk.py --with-network --refresh-ruby
& '<Python 3.11+>' scripts/android/build_apk.py --emulator-compatible --with-network --refresh-ruby
```

主机检查全部通过，含新增 10 项显示模式断言、原有输入/文本/选槽/平台/文件事务回归及 444 个 Ruby 文件编译。API30 上已安装的 .8 目标类通过 20 个触控案例 / 197 个断言，0 失败。这些组件检查与实际游戏画面分开记录；游戏操作和截图见 [Android.8 设备报告](android8-device-report.md)。

## 安装与边界

原 6 GiB AVD 直接升级因空间不足失败，旧安装与数据保持可恢复。随后使用 Android 包管理器的 `uninstall -k` 保留应用数据，再以同签名安装 .8；这不记为直接升级成功。安装后 31 个存档/备份文件与安装前逐文件 SHA256 完全一致，原按键大小 100% 保留。没有清理任何旧素材、下载、缓存或存档，也没有新建或扩容模拟器。

APK 仍约 708 MiB，解包素材约 934 MiB，历史素材暂留；自动容量治理仍待实现。没有新增真机、其他 Android/密度/刘海矩阵、16 KiB 页兼容、完整剧情通关或战斗/融合全量回归的验收结论。历史记录见 [Android.7](release-notes-android7.md)。
