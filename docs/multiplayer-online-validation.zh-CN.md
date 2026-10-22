# 在线地图与云存档验证（2026-10-21）

分支 `codex/overworld-chat`，保留用户原有非本功能工作区改动。没有部署公网服务、发送消息给其他人或读取正常玩家存档。

| 层级 | 结果 | 证据/入口 |
| --- | --- | --- |
| Python完整服务回归 | 157项通过 | `scripts/multiplayer/test-all.ps1` |
| Ruby联机回归 | 原有套件及online、android_network通过 | 同上；online 21项、Android适配16项 |
| Windows真实Game三进程 | 启动认证、同地图互见、移动朝向、地图/世界聊天、切图隔离、远端手动/定时保存、新设备恢复、新角色空槽通过 | 异步修复后重跑 `temp/multiplayer/world-online-5f8ef5351e/`，三个进程自然exit0 |
| 真实游戏云序列化 | 中文、uint32、背包、剧情开关、复合键、融合精灵/可信物种缓存和地图重建通过 | `temp/multiplayer/cloud-codec-native-final/saves/feature-smoke.log` |
| Android实际网络运行时 | 10项通过，Ruby3.4.10、Android.8已安装运行时 | `temp/multiplayer/android-network-1b7aa80ab5/result.json` |
| Android异步HTTPS修复 | 独立测试APK的8项设备检查通过；4.57秒延迟期间168帧和168次Input更新，最长单次查询约0.060秒 | `temp/multiplayer/https-async-407a31b04f/result.json` |
| Java异步队列 | 取消、超时、排队、容量、结果消费和过期清理通过 | `AsyncHttpQueueHostTest` |
| Android构建接口 | Java+SDL源码编译、JNI桥接源码编译和符号/段检查通过 | `temp/android-online-compile/`、`temp/android-bridge-build/` |
| 构建清单及可信目录 | 新清单通过校验，十二只租借目录真实导出与招式实例化通过 | `temp/multiplayer/async-https-catalog/saves/rental-catalog.log` |

Android网络诊断覆盖大于64KiB的HTTP云存档收发、注册登录和Bearer凭据、Unicode、地图状态、两个聊天频道、可信HTTPS、不可信证书拒绝和期限。HTTPS云分片由Ruby桥接模拟和真实Python服务测试验证，包括更换登录会话后的断点恢复及唯一提交；没有把无可信证书的本机测试服务伪装成公网HTTPS部署。

诊断启动前确认Android游戏进程未运行，备份并恢复独立诊断脚本和mkxp配置。所有测试账号、SQLite、profile位于隔离测试目录。模拟器测试不等于真机矩阵或最终APK交付。

过程中发现并修复：阴影插件将远端角色误当本地事件、嵌入式Ruby缺少base64标准库、Windows拒绝未排空POST正文时可能RST、Android Ruby IO线程/原生域名TLS路径崩溃、旧JNI请求64KiB限制，以及分片校验包含旧session导致无法跨会话恢复。失败记录保留在独立temp目录；表格仅列最终通过记录。

Android壳平台契约38项、全部461个Ruby文件语法检查通过；Java存档ZIP/文件系统33项和统计协议主机检查通过。首次主机脚本的Java默认堆分配遇到宿主机内存限制，随后用独立128MiB堆重跑Java检查通过。旧APK payload复用被新打包检查按预期拒绝，不会静默发出缺少联机模块的旧包。

异步修复的测试APK使用独立应用ID `org.kuray.kif.httpsasyncprobe`，只在这个测试包中信任本机短期测试CA，生产证书策略未放宽。测试确认可信延迟HTTPS完成、画面/Input持续更新、0.4秒期限取消、取消后恢复、主动关闭和两条并行请求，以及不可信证书拒绝。原模拟器空间不足后使用临时AVD；测试后已停止并清理临时AVD，原游戏与存档未改动。

尚未验收：最终Windows/Android完整游戏混合同地图、完整游戏新版APK安装、人工软键盘/触控、慢公网/真机帧率矩阵及长时间压力测试。网络等待引起的主线程阻塞已修复；游戏资源加载与大存档编码的开销属于其他路径。
