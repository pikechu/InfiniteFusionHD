# Android.16 高清素材整合

版本 `0.20.8-android.16` / code 16，ARM64，Android 11 及以上。由合并后的 main 完整重打 23,385 个逻辑资源；P1～P5 已全部结项，267 张高清化图片、1 张编码修复及 P5 的 1,850 张保留原图均与验收哈希一致。三张中文战斗按钮采用已验收版，并同步对应中英文图片清单；111 对图片核对通过。

手机 APK 沿用固定原版 ARM64 运行库和已有本地测试签名。JNI 输入/网络桥按 main 源码重新构建；完整原生运行库未从源码重建。模拟器 APK 单独使用已审计的旧 ARM 转译兼容变体，二者游戏 payload 完全相同：`0179f18c369f8c41902cac31`。

| 产物 | SHA-256 |
| --- | --- |
| 手机 APK | `e8fdc3783305d460051d4190e70ff85397cffa8a701cb51c2427006f0071074e` |
| 模拟器 APK | `5408b07ec22db66189800b616c1d02d904479889138f2d4ed093714ecabe634e` |

两个 APK 各 818,817,328 字节，签名、资源清单及完整 payload 的逐文件字节哈希校验通过。本地成品保存在项目 `output/texture-main-release-20261103/`；本轮未发布到下载站或新建 GitHub Release。

隔离 Android 11/API30 模拟器的正常启动至首次语言选择/开场、实际中文界面、12 次地图切换及 5 组事件图块像素、120 个中英文战斗菜单状态和 12 组 HP/EXP 动画通过。方向、确认、返回三个真实 Android 触控事件也已通过生产 JNI/Ruby 输入桥接收验证。正常启动截图已人工复核；没有用单纯进程存活代替画面验收。详见[汇总及限制](../gameplay-evidence/2026-11-03-android16-texture-release/summary.json)。

本机初始缺少硬件加速驱动；经用户确认，安装并验签 [Google 官方 AEHD 2.2](https://github.com/google/android-emulator-hypervisor-driver/releases/tag/v2.2)，服务运行后复测通过。使用新建隔离 AVD，未修改原有玩家 AVD 或 Windows 存档。

删除 3,481 个旧日志、字节码缓存和重复构建中间文件，共 49,594,097 字节；每轮构建/测试后停止本轮进程并清理原始日志和工作文件。保留源代码、回归测试、存档、正式证据、成品和必要工具。占用端口时不触碰其他会话的 ADB、标记和日志已有离线回归验证。

复跑使用 `scripts/android/run_localization_emulator_tests.py`，阶段为 `launcher`、`ui`、`map`、`textures`、`input`，通过 `--apk` 指定模拟器 APK，`--output-dir` 指定本轮证据目录。触控坐标对应固定 1280×720 隔离 AVD。真机、完整通关及其他 Android 系统矩阵未在本轮验证。
