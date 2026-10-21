# Android.5 本地测试发布说明

0.20.7-android.5 / code5，org.kuray.kif，KIF Android Test。本地独立测试签名，未上传或公开发布。手机及模拟器包已构建、签名；模拟器已原地安装，解包中断恢复与设备补测进行中。

## 变化

继承[Android.3](release-notes-android3.md)的选槽安全绑定及[Android.2](release-notes-android2.md)的标题确认、字体和无损体积修复。[Android.4](release-notes-android4.md)保留初始自由文本问题、构建和实际测试记录。

提交`7538320d`将Android自由文本虚拟C/X与方向键集中接入extended查询，并跟踪Ruby成功设置的文本会话。隐藏IME后原生SDL状态即使变为false，仍按Ruby文本会话处理确认/取消；明确关闭会话后停止映射。原生setter先执行，保留其返回与异常，对外getter不变。

Android提交前通过平台接口消费末批字符，沿用原光标和maxlength插入，过滤IME提交键的CR/LF；取消时丢弃待处理字符，Windows接口不读队列。164项实际`pbFreeText`/键盘窗口/编辑助手主机回归、原69输入及全部主机检查通过。精确.4适配器和修复前Messages两个负对照分别在会话丢失与同帧末字处失败。该证据不代替Android实际IME测试，也不证明已定位或修复.4的ANR。记录在`temp/evidence/text-input-session-fix/`。

## 产物

| APK | SHA256 | 字节 |
| --- | --- | ---: |
| `KIF-0.20.7-android.5-arm64-emulator-network-test.apk` | `01f37fa99f2a06628528851621705ecda5ec8426163d224c3342b61ce666c728` | 742766829 |
| `KIF-0.20.7-android.5-arm64-network-test.apk` | `a1cab78124b9ca0ae48cf2659417184d4b54976b865d839dd7554a25baa75887` | 742766829 |

位于本worktree `temp/artifacts/`，各约708.36MiB；资源payload `16590ec82d1107a4bf628808`，两包源码哈希及资源快照完全一致。模拟器包使用单独固定的旧ARM翻译器兼容补丁，仅对已记录的API30模拟器成立；整体4KiB页，未完成16KiB兼容验收。手机变体确认保留固定原版core（SHA `6f90fabcb227eafa2a5b3a8967dbe34368cec06efab5cd3e709f538003186232`），没有真机运行证据。

## 验证范围与限制

- Android.2最终7279包：标题/字体及自然普通闭环通过；Android.3升级、G精确读回、新F角色/光标姓名/保存通过，见[普通GUI报告](gui-regression-report.md)。人工E六党/满箱闪光、缓存复用、混合融合与保存已在.3实际通过，.4继续反向/拆分/进化/双打及SAF，见[闪光存档报告](shiny-save-report.md)。
- Android.4原地安装：20个QA存档/备份的全文件哈希在清理前、清理后、APK更新后完全一致。仅删除两个确认非active旧代的基础Audio/Data/Fonts，当前素材、所有Graphics与共享可写目录保留，释放约1.48GiB；这属于本次AVD维护，不代表应用已实现自动容量治理。包管理服务初次dumpsys超时，重试后确认code4，正常Launcher启动；新资源解包/游戏回归继续记录。
- Android.4实际显示标题，单次C后显示明确E卡；正常Continue到Route1和五队。命名备份框第一次X发生KIF `:game`输入分发ANR（5006ms），选择Wait后退出文本并恢复原保存菜单；20文件全哈希仍不变。同期有memory PSI及25%iowait记录，缺少主线程stack，尚未定根因或算无故障通过。补测与原始证据见[Android.4 GUI报告](shiny-save-android4.md)。
- Android.5升级及资源恢复：23个QA文件与.4交接一致，旧代基础素材清理及APK安装前后均不变。新解包约4千个基础文件/774图片时，确认旧active/新未complete/无game进程后强停；23文件不变、5个保留文件SHA匹配。正常Launcher重启后新complete/active均为16590…，已进标题并正常读E到地图。证据`temp/evidence/upgrade-android5/`及[.5实际报告](shiny-save-android5.md)。
- Android.5真实文本：可见Gboard键入EBASE5→Back隐藏→单虚拟C提交→原UI保存，命名备份实际落盘；全24文件只有E改和EBASE5新增，队伍/箱/背包/位置与.4 checkpoint相同。CANCEL5→隐藏→虚拟X取消也通过，native getter=false且对应扩展查询=true已在设备日志观察。重开IME后的Z未进入字段（R5仍R5），这是本版已知缺陷；见[设备文本报告](text-input-device-report.md)。后续.6源码e9e31546补一次性重开请求桥，188主机文本检查通过，尚未据此宣称设备已修复。
- b8包的归档格式：独立AVD首解包后23,128路径SHA全通过，2,300别名恢复独立inode；未删资源或降音质。见[资源报告](payload-device-report.md)、[体积报告](apk-size.md)。
- 主机：平台/输入/下载/保存事务、35项选槽绑定、11组打包/快照回归及34项实际Java恢复通过。编译444个Ruby脚本通过；不代替设备玩法验收。
- Windows portable原生源码：固定依赖、Ruby及完整core已真编译；独立完整源码探针在API30模拟器通过OpenSSL/socket/zlib、两种Marshal合约、JNI、字体和120帧。未用旧16字节翻译补丁；NDK标准C++库仍4KiB，因此整体16KiB未通过。当前游戏APK仍采用固定上游预编译core，源码运行时未替换进游戏包。
- 未真机验收、未完整剧情通关、未公开发布；目标配置为ARM64/API30+/target35，具体兼容性以测试设备记录为准。

## 安装与保护数据

```powershell
& 'temp/tools/android-sdk/platform-tools/adb.exe' -s emulator-5554 install --no-incremental -r 'temp/artifacts/KIF-0.20.7-android.5-arm64-emulator-network-test.apk'
```

同包同测试签名支持原地升级；卸载会删除私有数据。先导出存档；导入只合并新文件并拒绝任何冲突。参见[迁移说明](save-migration.md)。APK缩小不等于解包资源缩小，仍需约934MiB完整素材及安装临时空间；旧资源版本目前保留供恢复，容量治理待后续完善。
