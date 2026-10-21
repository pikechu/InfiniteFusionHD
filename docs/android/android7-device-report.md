# Android.7 虚拟按键与尺寸回归

日期：2026-10-21。状态：已实现、已构建、已在原 6 GiB AVD 原地安装；真实目标类触控和下列游戏 UI 回归通过。没有真机验收或公开发布。源码里程碑为 `c4421270`，在隔离分支 `codex/android-port-v1`，未合并 dev/main。

## 被测构建

- 包：`org.kuray.kif`，`0.20.7-android.7` / code 7。
- 模拟器 APK：`KIF-0.20.7-android.7-arm64-emulator-network-test.apk`，SHA256 `56acc7bb2d337e5259e4b6d5df6425d2e66db80594a3afaab004611bc1fccbe1`。
- 普通 ARM64 APK：SHA256 `d9e2f0e20693513332498b0db2419fbf01d66edb5b3df509600388cf7474ec13`；未真机运行。
- 两包各 742,775,021 字节，payload `0343ff43985ac933f2f66e5c`。
- 原测试环境：`emulator-5554`，`kif_api30`，Android 11 / API30，x86_64 + ARM64 翻译，3 GiB RAM，240 dpi，720×1280 横屏运行，4 KiB 页。
- 原运行时与原生输入桥版本沿用 Android.6，变化在 Java 悬浮控件和 Ruby 平台显示策略。

## 环境与数据保护

原有 30 个测试存档和备份已通过 `run-as` 导出 tar，文件清单逐一计算 SHA256；与 Android.6 最后恢复的 30 文件清单完全一致。备份与操作记录位于 `temp/evidence/touch-controls7/000-before-upgrade.tar`、同名 JSON 和 `actions.jsonl`。没有读取或修改 Windows 玩家存档。

AVD 在安装新版前冷启动缓慢：PackageParser 线程曾处于不可中断 I/O 等待，之后自行继续；约 74% iowait，系统 IMS 应用发生启动 ANR。本阶段尚未运行 Android.7，不能将其归为本版游戏 ANR。首个失败启动留下的 QEMU 孤儿已通过精确父 PID/命令行核实并停止，当前 AVD 正常完成启动和用户解锁。

首次原地安装新版返回 `INSTALL_FAILED_INSUFFICIENT_STORAGE`。剩余约 1.5 GiB，原 Android.6 仍保留；本次安装不算升级通过。

用户同意完整备份后扩容。已离线复制并逐文件核验 30 个文件、16,164,528,197 字节；`temp/avd-resize7/backup-6g/manifest.json` 的 `verified` 为 true，摘要 `86db36d69362996ac7dbf02dae7918de2de954f0965e526963b37052eca98491`。原 AVD、入口 INI 和备份均未改变。

副本的数据容器已扩大为 12,884,901,888 字节；扩大前后两轮虚拟内容比较均通过。SDK 自带旧 qemu-img 存在 raw 创建长度截断，已用 64 位稀疏文件预建并 `convert -n` 绕过。完整 metadata/cache 视图展平后副本成功启动，普通 `run-as` 验证原 30 个 QA 文件全部相同。

在线扩大 ext4 文件系统失败：kernel 报 `reserve_backup_gdb: reserved block 384 not at offset 383`，resize2fs 退出 1；文件系统仅从 6 GiB 部分增长约 128 MiB，未达到 12 GiB。失败后再次恢复普通 adbd（uid2000）并逐哈希确认 30 个 QA 文件仍完全相同。失败副本未提升为当前 AVD，不能作为可用扩容成果或本版游戏验收环境。

用户询问容量原因后，完成只读占用统计：两份完整基础素材各约 780 MiB，七代可写图片目录各约 311–313 MiB；大量占用来自历次 QA 版本累积。12 GiB 是当时的保守测试容量方案，不是一份游戏的最低需求。用户随后批准仅清理非活跃 `16590ec82d1107a4bf628808` 的 `Audio`、`Data`、`Fonts`（约 777 MiB），保留全部图片、下载、缓存和存档；旧版完成标记将失效以支持未来重新解包。

原 6 GiB AVD 已恢复，清理仅 unlink 4,606 份与旧 manifest 完全相同的文件；4 份修改或新增记录原地保留且 SHA 相同。实际回收 771,856 KiB（753.77 MiB），可用从 1,592,156 增至 2,364,012 KiB。全部 Graphics、Cache、Exported、Mods、saves/backups 根的轻量 stat 不变，active 仍为 be6a…；旧 `.complete` 改名失效，原 manifest 保留。

随后 Android.7 安装成功。清理后、安装后均以普通 uid2000 / run-as 重新验证 30 个 QA 文件全部原 SHA；证据为 `temp/avd-resize7/cleanup-result.json`、`install-android7-result.json`、`after-install7-result.json` 和 `handoff-result.json`。没有创建新 AVD，未更改新建 AVD 的默认容量。完整过程和恢复说明见 [AVD 存储](avd-storage.md)。

## 本版检查

| 检查 | 当前实际结果 |
| --- | --- |
| Java + SDL 壳、APK 签名、来源及资源快照 | 两变体均通过 |
| 主机平台/输入/文本/存档回归 | 通过；平台 62、输入 69、文本 188、选槽 35、真实 ZIP/文件事务 33；444 Ruby 文件编译通过 |
| 实际 Android MotionEvent 20 案例 | 原 API30 AVD、已安装目标类，20/20 通过、197 断言、0 失败；不启动游戏或访问存档 |
| 标题、选槽、读档 | 正常单次确认进入菜单；方向切 D→E；E 正常读入 Route1，见 008–014、031–039 |
| 默认布局与画面 | 只常驻方向、确认、返回和 ⋯；没有固定按钮栏；1280×720 屏幕中的游戏区域为 x160–1119、y0–719，即 960×720 / 4:3 |
| 65% / 100% / 150% | 真实滑块预览、65%保存及按键操作、150%保存、取消还原65%、恢复默认100%再保存均通过，见 016–037 |
| 设置冷启动保留 | 150% 保存后 force-stop 冷启仍150%，实际标题显示并可确认；100% 恢复保存后 SAF 冷启仍100% |
| 移动与原菜单 | 按住方向700ms产生移动，释放后停止；暂停、队伍、PC/满箱浏览及退出正常，见 040–056 |
| 闪光显示 | 沿用此前人工QA个体；队伍第1/2/6只有闪光标记；满箱30只可浏览，选中闪光显示特殊配色 |
| 折叠键盘入口 | 进入备份名字段，⋯→键盘，实际Gboard输入r→Android返回隐藏→重开→z，字段为rz；虚拟确认提交并正常保存 |
| 存档、备份与导出 | 仅改E主档，新增File E - rz.rxdata；无删除。SAF实际导出30个允许文件，逐文件SHA匹配；其余29份原文件不变 |
| SAF 后首次启动 | 实际打开系统文件选择器并导出后，第一次Start Game/读E保持960×720，未复现.6的512×384靠左下画面，见 075–086 |
| 后台恢复 | 一次Home→热恢复回地图，画面、按键及位置正常；不是锁屏/长后台/音频完整矩阵 |

设备 MotionEvent 测试通过以下脚本重建、安装并运行；它加载已安装目标类、不启动游戏、不访问存档，并拒绝在游戏进程运行时执行：

```powershell
& '<Python 3.11+>' scripts/android/run_touch_checks.py --run --serial emulator-5554 --expect-version 0.20.7-android.7
```

结果写入 `temp/android-touch-checks/result.json` 和 `instrumentation.txt`。这类控件测试与真实游戏操作分开报告。

## 存档与冷读证据

真实操作证据为 `temp/evidence/touch-controls7/`，截图、`actions.jsonl`、原始日志与 TAR/ZIP 均留档。`082-save-export-audit.json` 对照基线30份与新31份：新增 `File E - rz.rxdata`，唯一改变 `File E.rxdata`；19份非E文件及10份旧E备份全原SHA。新主档和rz备份都绑定两个Player到File E。SAF ZIP含30个允许条目，CRC及内容SHA全部匹配；`android-runtime-smoke.dat`按格式白名单排除。

复用既有惰性类桩工具，只读解码人工QA数据，未启动游戏或加载真实游戏脚本。保存前后队伍仍为：Charmeleon16 HP46/46、Squirtle15 HP38/38、Bulbasaur15 HP40/40、Charmander15 HP36/36、Pidgey15 HP41/41、Bulbasaur15 HP41/41；第1/2/6只闪光，Box1仍30只/15闪光。保存位置由map78 x15/y10朝上，变为x15/y11朝下，与本轮移动一致。

首次SAF后冷读实际地图见086，队伍实际HP/等级/闪光见091，与上述保存数据一致。最终094清单与071保存后清单逐项相同，说明随后导出、冷读、后台恢复没有再次改写存档。核验汇总为 `101-summary.json`。

## 尺寸与运行采样

对默认、65%、150%、150%冷启、SAF首启和最终地图共7张原始1280×720截图，在不受控件覆盖的第100行检测游戏左右边界，均为160与1120（右边界不含），结合固定4:3比例和完整截图确认960×720。调整按键没有预留布局宽度或缩小游戏区域。窗口和偏好分别保存在098及100证据，最终大小为1.0。

新素材准备实测177216ms，包含933MiB解包与下载/自定义图片保全。最终地图单点PSS635811KiB（约621MiB）、RSS763480KiB（约746MiB）；是单点采样，不是峰值或真机性能结论。截取日志未发现KIF ANR，不能据有限日志和本次短测承诺全部生命周期无故障。

## 尚待验证

- Android.7未全量重跑战斗/捕捉、融合/反向/拆分、进化或四闪光双打；既有各版玩法证据保留，不能移记为本版全量验收。
- 输入框取消、展开快捷键与方向的真实游戏组合、按住切后台和锁屏/音频仍需补；本版组件MotionEvent覆盖多指、取消和失焦释放。
- 三种组件layout尺寸是实际View测试，不是三种设备或全游戏渲染验收。真机、其他系统/刘海/屏幕、16KiB及Windows实际GUI仍未验收。
- APK仍用固定上游预编译游戏core；Windows portable完整源码core已另有独立探针证据，尚未接入完整游戏。自动旧资源清理未实现，本次仅为用户授权的QA维护。
