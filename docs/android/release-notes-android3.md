# Android.3 本地测试发布说明

0.20.7-android.3 / code3，org.kuray.kif，KIF Android Test。本地独立测试签名，未上传或公开发布。当前阶段为已构建、设备回归进行中。

## 变化

继承[Android.2](release-notes-android2.md)的标题单次确认、实际字体高度、无损压缩/去重、Android独立来源说明及构建一致性保护。
新增手动存档按实际选择槽绑定：导入E备份为D后，Android在Game.load前将vanilla和KIF两份Player内存对象绑定D，避免下一次保存回E。Auto槽保留原手动目标，Windows透传。35项真实Marshal/文件检查通过；实际SAF导入与保存验证等待设备回归，不预写PASS。

## 产物

| APK | SHA256 | 字节 |
| --- | --- | ---: |
| `KIF-0.20.7-android.3-arm64-network-test.apk` | `7e49605fa1948051ffc30ab8382bd777a31b538dc1b6a16bb4395ecd09424638` | 742762733 |
| `KIF-0.20.7-android.3-arm64-emulator-network-test.apk` | `c3a70ecd1eb05edfb0dd8356b798d74c6f3967b19fb14513c2b2b7aa9ca966fa` | 742762733 |

均位于本worktree `temp/artifacts/`，708.35MiB；资源payload `d5767c74f758589212589b2a`。
手机包使用固定原版ARM64 core，尚无真机验证。模拟器包使用单独固定的旧ARM翻译器兼容补丁，仅对已记录的API30模拟器成立；整体4KiB页，未完成16KiB兼容验收。

## 验证范围与限制

- Android.2最终7279包：8字体实际A/B与4种真实GUI字体通过；标题移动期单次C通过；移动、自然野战/捕捉、普通融合/拆分、仓库存取、G槽保存、杀进程后的同位置/四队员/精确HP冷读均实际通过，见[GUI报告](gui-regression-report.md)。.3在完整备份后升级并重新读档，随后测新档、闪光、备份/SAF。
- b8包的归档格式：独立AVD首解包后23,128路径SHA全通过，2,300别名恢复独立inode；未删资源或降音质。见[资源报告](payload-device-report.md)、[体积报告](apk-size.md)。
- 主机：平台/输入/下载/保存事务、35项选槽绑定、11组打包/快照回归及34项实际Java恢复通过。编译444个Ruby脚本通过；不代替设备玩法验收。
- Windows portable原生源码：固定依赖、Ruby及完整core已真编译；独立完整源码探针在API30模拟器通过OpenSSL/socket/zlib、两种Marshal合约、JNI、字体和120帧。未用旧16字节翻译补丁；NDK标准C++库仍4KiB，因此整体16KiB未通过。当前游戏APK仍采用固定上游预编译core，源码运行时未替换进游戏包。
- 未真机验收、未完整剧情通关、未公开发布；目标配置为ARM64/API30+/target35，具体兼容性以测试设备记录为准。

## 安装与保护数据

```powershell
& 'temp/tools/android-sdk/platform-tools/adb.exe' -s emulator-5554 install --no-incremental -r 'temp/artifacts/KIF-0.20.7-android.3-arm64-emulator-network-test.apk'
```

同包同测试签名支持原地升级；卸载会删除私有数据。先导出存档；导入只合并新文件并拒绝任何冲突。参见[迁移说明](save-migration.md)。APK缩小不等于解包资源缩小，仍需约934MiB完整素材及安装临时空间；旧资源版本目前保留供恢复，容量治理待后续完善。
