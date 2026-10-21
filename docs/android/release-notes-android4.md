# Android.4 本地测试发布说明

0.20.7-android.4 / code4，org.kuray.kif，KIF Android Test。本地独立测试签名，未上传或公开发布。手机与模拟器包已构建、签名；模拟器已原地安装并开始实际回归，手机包没有真机运行证据。

## 变化

继承[Android.3](release-notes-android3.md)的选槽安全绑定及[Android.2](release-notes-android2.md)的标题确认、字体和无损体积修复。

修复Android自由文本输入只能等待物理Return/Escape的问题：集中在Android输入后端扩展普通虚拟C/X与方向键，仅在原生`Input.text_input == true`时接入extended查询。普通游戏、物理键、未知参数和Windows路径保持原行为。111项实际`pbFreeText`/键盘窗口主机回归通过，原69输入断言仍通过；旧后端负对照在真实`pbFreeText`超帧失败。实际软键盘、C提交和X取消正在设备验证，不预写PASS。

构建后的独立复核确认APK记录的467项源码哈希与当时源码一致，内层payload实际输入适配器与清单相符。另发现继承的文本顺序问题：`pbFreeText`在`window.update`之前检查Return，若最后文字与确认同帧到达，主机反例返回旧文字且`Input.gets`仍有待处理字符；分帧对照正常。证据在`temp/evidence/text-submit-race/`。真实Android IME同帧是否可达尚未验证；本版不宣称已修复此问题。后续Android.5源码提交`7538320d`补上会话与末批文字处理，164项主机回归通过，尚待新APK设备验证；不能回填为Android.4已修复。

## 产物

| APK | SHA256 | 字节 |
| --- | --- | ---: |
| `KIF-0.20.7-android.4-arm64-emulator-network-test.apk` | `636ce391a97330d9a8fb0e7135468318b305e45e4babdf356623667afbcc6000` | 742766829 |
| `KIF-0.20.7-android.4-arm64-network-test.apk` | `79e9b6eb6a5a94d8f760adb0db7b5e012ad63d2722e6c3977c5ab74031c6a51e` | 742766829 |

位于本worktree `temp/artifacts/`，各约708.36MiB；资源payload `4891b2121b1a64fa417082fa`，两包的源码哈希清单和资源快照完全一致。模拟器包使用单独固定的旧ARM翻译器兼容补丁，仅对已记录的API30模拟器成立；整体4KiB页，未完成16KiB兼容验收。手机变体已确认打入固定原版core（SHA `6f90fabcb227eafa2a5b3a8967dbe34368cec06efab5cd3e709f538003186232`），没有真机运行证据。

## 验证范围与限制

- Android.2最终7279包：标题/字体及自然普通闭环通过；Android.3升级、G精确读回、新F角色/光标姓名/保存通过，见[普通GUI报告](gui-regression-report.md)。人工E六党/满箱闪光、缓存复用、混合融合与保存已在.3实际通过，.4继续反向/拆分/进化/双打及SAF，见[闪光存档报告](shiny-save-report.md)。
- Android.4原地安装：20个QA存档/备份的全文件哈希在清理前、清理后、APK更新后完全一致。仅删除两个确认非active旧代的基础Audio/Data/Fonts，当前素材、所有Graphics与共享可写目录保留，释放约1.48GiB；这属于本次AVD维护，不代表应用已实现自动容量治理。包管理服务初次dumpsys超时，重试后确认code4，正常Launcher启动；新资源解包/游戏回归继续记录。
- Android.4实际显示标题，单次C后显示明确E卡；正常Continue到Route1和五队。命名备份框第一次X发生KIF `:game`输入分发ANR（5006ms），选择Wait后退出文本并恢复原保存菜单；20文件全哈希仍不变。同期有memory PSI及25%iowait记录，缺少主线程stack，尚未定根因或算无故障通过。补测与原始证据见[Android.4 GUI报告](shiny-save-android4.md)。
- b8包的归档格式：独立AVD首解包后23,128路径SHA全通过，2,300别名恢复独立inode；未删资源或降音质。见[资源报告](payload-device-report.md)、[体积报告](apk-size.md)。
- 主机：平台/输入/下载/保存事务、35项选槽绑定、11组打包/快照回归及34项实际Java恢复通过。编译444个Ruby脚本通过；不代替设备玩法验收。
- Windows portable原生源码：固定依赖、Ruby及完整core已真编译；独立完整源码探针在API30模拟器通过OpenSSL/socket/zlib、两种Marshal合约、JNI、字体和120帧。未用旧16字节翻译补丁；NDK标准C++库仍4KiB，因此整体16KiB未通过。当前游戏APK仍采用固定上游预编译core，源码运行时未替换进游戏包。
- 未真机验收、未完整剧情通关、未公开发布；目标配置为ARM64/API30+/target35，具体兼容性以测试设备记录为准。

## 安装与保护数据

```powershell
& 'temp/tools/android-sdk/platform-tools/adb.exe' -s emulator-5554 install --no-incremental -r 'temp/artifacts/KIF-0.20.7-android.4-arm64-emulator-network-test.apk'
```

同包同测试签名支持原地升级；卸载会删除私有数据。先导出存档；导入只合并新文件并拒绝任何冲突。参见[迁移说明](save-migration.md)。APK缩小不等于解包资源缩小，仍需约934MiB完整素材及安装临时空间；旧资源版本目前保留供恢复，容量治理待后续完善。
