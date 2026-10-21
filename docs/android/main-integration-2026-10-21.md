# Android.8 合入 main

用户要求将代码提交到特性分支，再合并 main。Android 特性提交为 `codex/android-port-v1` 的 `272e3f90`；合并目标先从 `7ed0deda` 快进到最新 `origin/main` 的 `8afd177c`，保留已经合入的统计和联机功能，再合并 Android 全部里程碑。原工作目录仍在 `codex/android-port`，未提交文件没有被纳入此次合并；dev 未改。

## 合并处理

- `.gitignore` 保留双方规则，包含 temp、构建输出、签名密钥、Python 缓存及联机原始证据排除项。
- 公共 `000_Platform.rb` 保留 Android 完整接口；主分支原有接口全部已包含于该实现，没有删除联机依赖的时间、路径及 HTTP 能力。
- Android 主机测试入口加入 main 已有的 `AnalyticsProtocol` 编译与协议测试，避免自动收集测试文件后找不到协议类。
- 按 main 的既有 LF 规则规范本隔离工作树的 Ruby 换行，重新生成联机兼容清单。仍为506个输入，`data_hash=592e5b0868296282e125e497b7fb43afd6d19a6e84d8e463bd42ee4f84775886`；否则 Android 对公共脚本的修改会使旧清单失效。
- 固定上游原生补丁的空白上下文按路径豁免行尾空白检查，保留补丁原字节。

## 实际检查

- Android 主机全套检查通过，包括显示、输入、文本、路径、下载、选槽及 ZIP/文件事务；460个 Ruby 文件编译通过。
- 合并后的 Android 壳和 SDL 共18个 Java 源文件对 API35 编译通过，统计协议检查通过。
- 24组联机 Ruby 回归全部通过，含模拟跨平台、网络适配、对战、交易、恢复及收藏卡牌。未重跑未改动的服务端或真实多客户端游戏验收。
- 统计 Ruby 客户端40项检查通过，包括本地隐藏 PowerShell 子进程及标准输入探针；无外部统计请求。沙箱内首次子进程启动失败，获作用域执行权限后原测试通过，没有修改测试跳过断言。
- Python `build.py --check` 与实际 Ruby 客户端对真实506输入清单的 `compatibility` 校验均通过。
- 工作区与暂存区无未解决冲突，空白检查通过。检查日志在本工作树 `temp/logs/main-merge-*`，临时编译输出和模拟数据未提交。

现有 Android.8 APK、SHA 和模拟器证据仍对应特性提交 `272e3f90`，本次没有重打或覆盖它们。源码合并后的联机/统计功能不因此获得 Android 设备验收结论。Android 统计生命周期及玩家开关仍待按 `android/ANALYTICS.md` 接线，未因合并启用收集。
