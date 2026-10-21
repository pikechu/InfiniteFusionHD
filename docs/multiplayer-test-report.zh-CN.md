# 联机测试报告

> 本文件早期章节为历史记录，其中“未实现”及“最终构建”只描述当时版本。**当前以2026-10-20协议2复审为准**，详见 `multiplayer-code-review-2026-10-20.zh-CN.md`；阶段状态见进度表，跨平台见 `multiplayer-cross-platform.zh-CN.md`。2026-10-16的成功不替代本轮回归。原生HTTPLite虽通过早期响应性探针，长流程已确认不安全，不能继续使用。

日期：2026-10-16。测试范围是独立身份、独立数据库与测试存档。此报告持续记录真实结果；没有执行或没有通过的项目保持未验证/失败。

## 运行环境与加载证据

- 项目目录：`D:\others\kurayshinyrevamp`，Windows PowerShell。
- 已有 `Game.exe` 运行时探针：Ruby3.1.3、mkxp2.4.2/a5d5749、OpenGL/NVIDIA。
- 解开可信本地 `Data/Scripts.rxdata`，只有 Main 递归加载器；不需要重新打包全部源码。
- 真实 Game.exe 完整源码探针记录 `SOURCE_LOADED count=439`，包括054下001/002/003。
- 测试 `System.data_directory` 明确指向 `temp/multiplayer/<profile>/saves`；未调用玩家存档加载/迁移。
- 日志：`temp/multiplayer/runtime-probe/saves/runtime.log`、`temp/multiplayer/smoke-host/saves/game-smoke.log`、`temp/multiplayer/smoke-guest/saves/game-smoke.log`。日志使用UTC，当前机器UI日期时间以 Asia/Shanghai 为准。

## 已执行命令

```powershell
& 'temp/tools/ruby-3.2.9/rubyinstaller-3.2.9-1-x64/bin/ruby.exe' --disable-gems -rzlib -e 'Marshal.load(File.binread("Data/Scripts.rxdata")).each { |s| puts Zlib::Inflate.inflate(s[2]) }'
& scripts/multiplayer/start-client.ps1 -Profile runtime-probe -CustomScript scripts/multiplayer/runtime-probe.rb
& 'D:/Users/meikun.zhang/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe' -u tests/multiplayer/transport_probe_server.py
$env:KIF_MULTIPLAYER_TRANSPORT_PROBE='1'
& scripts/multiplayer/start-client.ps1 -Profile runtime-probe -CustomScript scripts/multiplayer/runtime-probe.rb
& 'temp/tools/ruby-3.2.9/rubyinstaller-3.2.9-1-x64/bin/ruby.exe' --disable-gems tests/multiplayer/client_test.rb
& 'temp/tools/ruby-3.2.9/rubyinstaller-3.2.9-1-x64/bin/ruby.exe' --disable-gems tests/multiplayer/battle_test.rb
```

两个真实 Game.exe 已启动并加载游戏数据库及新模块。初次身份请求遇到服务 SQL 错误，已修复并重启；第二次真实 Pokemon 往返测试发现原生 JSON 拒绝合法 uint32 个体ID，正在修复重测。**这两次不算完整对战通过。**

## 结果分层

| 层次/场景 | 当前结果 | 证据/限制 |
| --- | --- | --- |
| 源码加载链路 | 通过 | rxdata加载器、439文件与新模块运行日志 |
| native HTTP后台等待 | 通过 | 延迟2秒，88帧，最长间隔0.1738秒，HTTP200 |
| native SHA256 | 通过（修复显式require后） | abc标准摘要；仅require digest会失败 |
| 客户端结构/幂等恢复/快照单元 | 独立Ruby50项、真实Game.exe51项通过 | 最终含无Mod规则保护、未适配变身携带物拒绝 |
| 战斗适配隔离/异常/动作单元 | 55项通过 | 使用桩验证适配行为，不能替代真引擎 |
| Python服务业务与真实HTTP | 41项通过，103.501秒 | `server/multiplayer/data/test-run-accepted.log`；含Windows端口排他 |
| 真实Pokemon快照往返 | 每个完整实例16项通过 | 含融合B1H4、特殊闪光、无损uint32、PP/道具/薄荷/超训练/ID/OT与原值保护 |
| 两Game进程完整对战/再战 | 三轮共六场正常战斗通过 | 两端12公开阶段/轮逐项比较，结果96项/轮通过 |
| 手工真实菜单全流程 | 未验证 | Windows界面helper连续超时，含重置恢复尝试 |
| 不同动画速度/倍率 | 房主4倍速开动画、客机1倍速菜单通过 | 客机完整战斗动画尚未实现，不能写成双端动画全验收 |
| 游戏内断线重连/超时/换人 | 短断线、实际60秒操作超时、主动换人和强制补位通过 | 失联超额、连续3次超时与所有阶段断线仍需专项游戏验收 |
| 两台电脑局域网 | 未验证 | 没有第二台设备的实测证据 |
| 公网 | 未验证、未部署 | 没有购买或更改公网基础设施 |
| Boss/道馆/交易/租借/大厅/托管/副本/分享回放 | 未实现，不适用通过 | 不用接口占位或假数据宣称实现 |

## 可复现人工验收

使用 setup 中两个隔离 profile，新建测试角色并准备三到六只支持精灵。两端连接同一服务，用不同身份创建/加入房间，发布和查看包含融合/闪光的展示，验证隐藏字段不出现在API；选择三只顺序后准备，房主开始，客机刷新进入。完成包含携带物、异常、主动换人和强制补位的战斗，比较 HP/PP/状态/天气、终局和战斗ID；再战必须新ID，原队伍等级/HP/PP/物品和存档文件不变。

分别在准备/选择/动画/结果阶段中断网络，在累计60秒额度内恢复、两次恢复累积消耗、额度耗尽、双方掉线、房主进程终止、服务重启；判定结果不能重复或补交本地胜利。对重发start/commands/resolve/ack、迟到消息、错误目标/替补/版本、不同动画配置分别验收。跨机需两台设备填写相同服务局域网地址，另记设备与版本；公网需另行授权部署与独立测试。

## 最终联调结果

已运行三轮（Asia/Shanghai，2026-10-16）：

| 场景/命令 | 两个进程PID | 两场battle_id | 结果 |
| --- | --- | --- | --- |
| `verify-game.ps1`，17:01–17:02 | 68128 / 5972 | `b_e47148fe1f9d8f1880ad46a130e3d7f0`、`b_694a1aea8f764053268bf0497619e042` | 两场各4回合、6输入阶段，正常结算与再战 |
| `verify-game.ps1 -Faults`，17:03–17:06 | 54568 / 51268 | `b_c8614c3042e5e1133d62fb8bfbbae7fa`、`b_8f44007e1788cea7f1f6b14321cccb2a` | 同样完整结束；真实提交响应丢失后GET operation恢复；无心跳12秒后恢复剩55.7秒；第二场等待63秒触发服务默认动作 |
| `verify-game.ps1 -DifferentSpeed`，17:08–17:09 | 75696 / 69280 | `b_d2e117022f83720a3c281bd4c63dec49`、`b_0c290f5a6960e0fd1bc736d5a4b71683` | 房主game_speed=4,battlescene=0；客机1/1；完整结算一致 |

各轮日志位于 `temp/multiplayer/verify-{host,guest}-20261016-<170101/170339/170827>/saves/game-smoke.log`，截图在对应host的saves目录，报告 `temp/multiplayer/verify-evidence-20261016-<同编号>.json`。每轮都核实两身份不同、原globals对象及Marshal内容摘要不变、唯一终局和新再战编号，逐阶段比较HP/异常/天气/场地/战报/自己的PP及换人选项；对手私有动作没有出现在guest响应。客机turn0未发observer日志，该初始化阶段不冒称经过双端日志比较。

证据验证命令：

```powershell
& $python tests/multiplayer/verify_game_evidence.py --host temp/multiplayer/verify-host-20261016-170101/saves/game-smoke.log --guest temp/multiplayer/verify-guest-20261016-170101/saves/game-smoke.log --output temp/multiplayer/verify-evidence-20261016-170101.json
```

三份报告各96/96通过；另对HP、winner、codec数量、原globals标记、缺失phase和泄漏host actions做了篡改拒绝检查6/6，并验证缺失文件exit1。此工具只分析已真实运行的日志，不生成游戏结果。

正常入口额外启动PID21212，`temp/multiplayer/production-load-check/saves/runtime.log` 记录三个 `PRODUCTION_SOURCE_EVALUATED ... trace_path=001_Client.rb/002_UI.rb/003_Battle.rb`，证明由原 rxdata 加载器实际进入新源码。正常标题逻辑自动下载的两张素材已移到该profile的generated-assets保存，下载限流日志已恢复原内容，未混入本次实现。没有碰真实玩家保存数据。

自动重启编排第一次健康检查超时，另一次手动编排未及时重启、被预期异常断言拒绝，均不计通过。最终改为显式本机直连和由测试脚本自己重启其拥有的独立服务，结果如下。

### 最终源码回归

最终构建493输入，`data_hash=21139d4b7aeae711c920a8f8086dcd41fcd5b500f9e2b4124a1d7921dbd0abb3`。客户端无Mod/变身拒绝及服务器终局处理均已包含。

| 命令 | PID/业务编号 | 实际结果 |
| --- | --- | --- |
| `verify-game.ps1 -RestartService -DifferentSpeed` | 游戏75132 / 75892；服务65788 → 55124；profile后缀172224 | 首场 `b_50dad5b0a23687cbe7e67a4076116e2b` 正常胜负；第二场 `b_b60dbd4d9455e7aa85eca08e31076d9d` 引擎启动后真实重启服务，两端decision=0、reason=service_restart、winner=null、rewards=[]，原globals不变；通过 |
| `verify-game.ps1 -Faults -DifferentSpeed` | 游戏69356 / 76636；profile后缀172549 | `b_4b5dc66ca137fe5e1e89464636c8fd4a` 5回合/7阶段、`b_3cdf3f3e4f8f18b0e67e49cb2a56230f` 4回合/6阶段；两场正常结算及再战，通过98/98一致性检查 |

最终故障日志：已提交请求 `5ff71338fa207616b69e312ccb54f2c6` 的响应被测试transport故意丢弃，随后真实查询服务器操作恢复；停止心跳12秒后剩余额度56.0秒；第二场保留心跳等待63秒，服务器按60秒选招期限提交默认动作后继续完整对战。一次真实网络等待触发 `reconnecting` 亦已恢复。测试使用自动输入与故障注入，**没有改变Windows网卡或拔线**；物理断网与跨机仍未验收。

已验收的正常对战共9场，另1场受控重启异常终止；手动编排失败的场次不计入以上数量。最终版本完整两场的13个公开阶段、终局和原状态保护由98项检查核对。不同阶段的多次长断线、耗尽额度、连续三次超时、房主进程崩溃恢复以及特殊动态形态未做完整游戏验收，保持待验证。

归档：`docs/multiplayer-evidence/2026-10-16`，含每轮host/guest日志、状态截图、JSON一致性报告、normal rxdata加载轨迹、native客户端日志、服务测试日志和最终构建清单；`manifest.json`保存证据文件SHA256。前几轮是修复过程中的构建，最终构建清单对应172224/172549，不能将不同构建的日志当成完全相同版本。

最后执行 `build.py --check`、`git diff --check`，以及全部5个PowerShell脚本AST解析均通过。运行时切换Game.exe/compatibility配置测试确认原始两个exe SHA256不变。构建不改rxdata，测试不加载玩家原存档。

真实战斗覆盖普通攻击、中毒、携带物回复、主动换人、强制补位和伤害/暴击随机分支；天气/场地字段在这些场次均为None，未覆盖主动更改天气/场地、全部目标组合、多回合招式和所有物种形态。自动场景通过不表示完整战斗机制穷举通过。完整人工名片、展示编辑失败保留、撤回、倒计时等体验仍属首版待完成事项。

验收完成后停止本次拥有的8765服务与18766延迟探针；18768重启测试服务由脚本自行停止。数据库与证据保留，按setup重新启动即可。启动客户端不显式传`-Server`时继续使用游戏内保存的服务器地址。

## 全玩法开发与最终复审（本轮当前记录）

本轮在第一版主体基础上完成004–015及001/002/003增强，继续按CR→修复→自动测试→真实游戏分项验证推进。下面区分历史模块快照验收与最终统一构建；不同源码哈希的测试不冒称同一版本。当前状态见进度文档，未通过的人工/跨机项目不补填通过。

### 已执行的自动测试

统一入口：

```powershell
& scripts/multiplayer/test-all.ps1 -PythonExecutable $python -RubyExecutable $ruby
# 等价服务命令：
& $python -m unittest discover -s server/multiplayer -p 'test_*.py' -q
# 单项示例：
& $ruby --disable-gems tests/multiplayer/transport_test.rb
& $ruby --disable-gems tests/multiplayer/identity_recovery_test.rb
```

本轮服务124项通过（最新独立运行121.113秒），包含房间/权限/兼容/锁定、Boss接管、版本化道馆、交易及投递竞态、托管owner/锁、租借迟到选宠、大厅、副本状态恢复与回放权限。Ruby各suite按独立进程执行；guest/boss等会加载基础battle断言，不能把包含关系误算为全不重复的测试数量。最新统一日志另行归档。

重点回归包括：合法move targets和PP、非本人槽位拒绝、swap/forced switch、原global身份与内容restore、动画输入不被双update吞掉、未知或非有限外观字段拒绝、跨服务器与跨身份pending/escrow禁止、原恢复码可返回正确身份、损坏回放不锁业务journal、发布草稿保留、托管来源不能改成local、收货应用后ack前重启、同一交易/奖励重复查询、活动副本房间绑定、完整六只authority状态原子落库、正常初始认输/失败不消耗重试、到期和双放弃、回放下架不走旧响应缓存。

### 真实Game分项结果（正式传输修复前的模块验收）

| 场景 | 实际执行和结果 | 证据 |
| --- | --- | --- |
| Boss→离线馆主道馆→好友交换 | 两个真实Game PID69440/25296；Boss共同胜利；挑战固定v1时馆主发v2/下架/离线；本地AI真实胜利；完整字段交易保存/重读；原世界不变 | `temp/multiplayer/v2-rerun-20261016-183522*`及profile日志；测试初轮队伍检查使用两次GET导致ready竞态，已修测试为单快照并重测 |
| 池/托管收藏 | 两Game PID45812/66444、真实HTTP/SQLite；30项；本地匹配/领取/撤回、一次starter、托管好友交换/池、owner唯一、asset锁清零 | `pool-live-evidence-20261016-181857.json`；详见pool文档 |
| 保存后ack前硬退出 | 客机68904实际退出→相同测试存档新Game74916；房主67740；10项，原交易只补ack，未重复加入精灵 | `pool-restart-evidence-20261016-182449.json`；首次runner未mark_values_as_unloaded属于测试脚本问题，失败保留 |
| 租借杯 | 十二只融合逐只由Game导出/导入/四招实际注册；两Game完成ABBAAB后真战斗，8回合12阶段、120项 | `rental-native-final-evidence.json`；已有早期138项场次另保留 |
| 四人大厅 | 实际启动2人及4人Game，专用场景移动/表情/退出/邀请，主线地图/global不变 | `hall-*-native-four/saves/hall-native.log`及PNG；纯表现同步 |
| 客机原生战斗 | 实际双方Game，自动按USE操作真实原生动作菜单/动画；57项，18个native事件，无fallback | `native-scene-final-evidence.json`；记录renderer实际HP/totalhp/status与authority一致 |
| Boss全灭旁观 | 初始一人三只HP0，另一人继续真实胜利；原global/世界时钟不变 | `boss-watcher-*-native-c`；隔离后网络callback污染时钟已修 |
| 默认60秒AI接管 | 两Game故意71秒无法fetch，服务按默认60秒累计额度接管；客机重新加入保留locked动作，下一阶段收回控制；5回合7阶段共同胜利；21项 | `boss-disconnect-20261016-202525-evidence.json`；不是修改网卡或跨机 |
| 名片与CJK | 真实Game13项、真实TrainerType头像截图、六槽/徽章默认私有/下架过滤；项目Noto字体6个中文不同字形 | `cards-live-evidence-20261016-1851.json`及字体文档；人工所有长文本未验收 |
| 固定副本与第三人回放 | 四场真引擎、HP/PP/麻痹/消耗道具跨节点、补给、最终唯一奖、三身份回放和下架曾完成；随后第五场native崩溃，因此整轮失败 | `dungeon-replay-20261016-202522.partial-evidence.json`，overall_pass=false |
| 已胜利、advance前服务真重启 | 独立两Game37872/72748，真实服务70728→57248，battle同一正常终局和完整六只状态；只传battle_id正常advance，非重试；40项 | `dungeon-replay-20261016-203031.evidence.json`，FaultOnly单独通过 |
| 强制GC诊断长流程 | 四战+回放+第五战+服务重启102项通过，但只用于定位时序 | `dungeon-replay-20261016-204235.evidence.json`；gc_probe=true，不算生产修复通过 |

### 原生HTTP崩溃、修复与重新验收

不带GC干预复测204616仍在第三场native动画退出；普通离线8场、014相同真实visuals无HTTP8场均通过。加入原native后台HTTP后第七场崩溃；仅参考Socket同一8场301请求通过。故不能归因为回放文件或只用强制GC绕过。

进一步最小化到**没有RPG脚本、没有Graphics/Sprite、没有Thread.kill**：HTTPLite后台GET+主线程GC不足25次请求就发生 `[BUG] object allocation during garbage collection phase`；C栈出现 `rb_hash_new` 和 `rb_thread_call_without_gvl`。本地引擎源码 `temp/runtime-research/warmwinter/binding/http-binding.cpp` 的httpGetInternal等在drop_gvl_guard中调用formResponse创建Ruby对象，违反MRI线程要求。

相同最小负载，诊断Socket 200请求/1970次GC通过；正式015生产Socket 200请求/2557次GC通过。验证器 `tests/multiplayer/verify_http_gvl_evidence.py` 14项通过，证据 `temp/multiplayer/native-http-gvl-comparison-evidence.json`。旧native崩溃stderr仍保留，不能抹去失败。

正式修复：001不再提供HTTPLite回退，015使用有界core Socket；统一deadline、非阻塞部分IO、严格header/body/chunk/UTF8解析、禁重定向；无TLS先拒绝再journal；worker自然关闭不异步kill；大厅同样不kill；在线scope关闭旧素材下载并恢复原设置，worker活跃时guard旧nativeHTTP。WindowsIPv6拒绝连接的exception fd与IPv4 fallback已修。独立OpenSSL环境的真实可信链/错误主机名/不信任证书均有测试；默认Game无OpenSSL，未声称可用HTTPS。

最终默认Game不干预GC的长流程及进程exit0记录在后续检查点更新；兼容版Ruby3.0.0结果独立记录，不能替代默认Ruby3.1.3。全部人工菜单、跨机器局域网、物理断网与公网仍未验证。已完成不受这些限制影响的开发、自动及原生运行测试。
## 最终交付检查点：92b6 构建与截图CR闭环

最终data_hash：`92b6c5b61df113c696ed5ae910f4dfaa92c400f804c6b6c87d3ecc50811c14e0`，505个输入；可信目录SHA256：`f0d90407412439903b2b8073fb3dd3501348a2e4b465a5d7bc5e8cafe9d9c0fd`。原生Game76164退出0，十二只融合逐只导出/导入、48次真实引擎招式注册通过，构建check通过。该版本与前文1966历史验证分开。

最终默认Game运行 `dungeon-replay-20261016-221148-p18782-67b83f6b` **105/105通过**：房主68832(45项)、客机42204(42项)、独立观众344(18项)，三者均真实exit0、Ruby3.1.3、core_socket；gc_probe=false、截图开启。五场真实引擎胜利、四战副本/补给/权威状态延续、三身份同意后回放及下架、服务73548→68456真重启、省略state正常advance与双方放弃均通过。SQLite integrity=ok，五笔全队state与result一致，恰两枚最终副本章；原globals/地图位置/实际原存档SHA全程不变。

上一轮105通过后的截图CR发现两项P2：三只sprite重叠遮住HP，回放没有应用已经保存的特殊外观。本轮003按实际bitmap列宽/高度缩放、名字/HP/状态分行；只使用完整校验的公开visuals应用形态/性别/闪光/颜色。012先验证整份记录的visuals、唯一slot、递增seq和相同slot的权威字段一致，错误转可恢复的invalid_replay；不能在后帧坏数据前先分配前帧对象。Board192项、Replay29项和身份47项定向回归通过，独立CR未见待修P1/P2。

专项原生Game59080退出0，实际640×480三/四列、支持闪光参数及原globals保持通过；最终第三观众的真回放截图也已目视确认清楚、不重叠。缺失融合素材仍为游戏备用问号图，保持已知限制。最终正常rxdata入口Game41800在离开最后模块后核实015调用方法、003 Board、012校验方法的真实source_location及最终摘要；全部15模块已执行，未重打包rxdata。

证据归档：`docs/multiplayer-evidence/2026-10-16-all-features`，包含当前及历史构建标识、真实游戏日志、PNG、JSON结果和SHA256 manifest；不含token、恢复码、profile凭据、SQLite或玩家存档。完整私密测试库及独立存档留在temp，供本机复核。旧native崩溃和harness失败仍保留，不倒改通过。测试自建服务/游戏已停止。

本次修改主要为 `Data/Scripts/054_Multiplayer/001–015`、`server/multiplayer`、`scripts/multiplayer`、`tests/multiplayer`、文档及OFL中文字体；原工作区13处tracked修改、Android相关文件保留。后续按setup执行人工完整菜单/单机回归、第二台设备LAN及物理断网；公网未部署、原生HTTPS不可用、任意Mod和全部特殊形态机制未验收，仍不宣称整份需求发布完成。
最终再次执行统一入口：服务124/124(61.216秒)、全部14组Ruby通过，包含新增Board192/Replay29；命令退出0。最终build --check、git diff --check、全部PowerShell AST和preloader Ruby语法通过。归档manifest的逐文件SHA256再次核验通过。

## 2026-10-20：协议2全面CR与最终feef构建

本节覆盖上文10月16日的“最终”说法。详细缺陷、优先级、修复代码、旧失败与复审记录见 `multiplayer-code-review-2026-10-20.zh-CN.md`。本轮保留原工作区13处tracked文件修改，最终逐个SHA256与开工前一致；未修改Android工作、未启动公网服务、未读写玩家真实数据。

协议2最终data_hash=`feef1f616182aebb3b836e09a4771e84b13892681ff867197c17d3be0d3f6b6c`，505个输入；mods_hash=`76555b5b8dd130f83b6cd8099cb1f31c1e7960b994df771e6c5d11c9930473c6`；原生可信租借目录SHA256=`adf5fee624d456012c30dac7bd7e256fd891ed52f421bcef28a17b7862196c5a`。Game105412实际校验12个租借个体/48招注册并exit0；普通入口Game89620不使用customScript，通过rxdata加载全部15模块及最终方法，记录摘要一致，随后只停止该证明进程。

| 本轮验证 | 实际结果 | 证据 |
| --- | --- | --- |
| 服务端全套 | 148/148，392.707秒，exit0 | `server-cr-20261020-current148.log` |
| Ruby最终整套 | 24组全部通过、exit0；包含identity53/journal20/scene13/pool42/transport74/cross_platform25 | `cr-20261020/ruby-all-release-retest.log`，不累加重复基础断言 |
| 默认Game综合 | 117项，host97724(50)/guest22580(47)/viewer24476(20)，三者自然exit0 | `dungeon-replay-20261020-110836-p18782-6597acaa.evidence.json` |
| 服务实际重启 | 62156→106844；第五场已提交正常胜利保持，省略state可advance且不消耗重试 | 同一综合证据 |
| 原存档和原地图 | 三份真实原档SHA、六globals对象/字节、位置不变；miniupdate/map/player/transfer次数均0 | 综合日志与 `cr-20261020/dungeon-replay-audit-evidence.json` |
| 唯一结算和奖励 | SQLite integrity=ok；5个唯一正常胜利、5个终局、2枚最终奖章；completed/abandoned各一条路线 | 只读audit脚本退出0 |
| 原生房主崩溃专项 | 杀85216，冲突引擎108144被拒；读进程66次GET不能续死引擎；最终host_disconnected、无奖励，存活三进程exit0 | `authority-restart-20261020-101520-40048-evidence.json`，较早b239构建独立记录 |
| 交易实际codec/SaveAs/仅ack | 72项、Game73792 strict exit0；快照标准规则56项、Game108020 strict exit0 | 对应 `trade-final-native-20261020` / `snapshot-rules-native-20261020` 日志 |
| UI设置完整SaveData落盘 | 修前Game106872 disk[[1,2],[1,2]]失败；修后98136 disk[[0,1],[0,1]]、6项通过、exit0 | `ui-settings-{before2,after}-cr20/saves/feature-smoke.log` |
| 池交易真实进程中断恢复 | 18项通过；host109328 exit0、first guest91604故意exit1、restart102460 exit0；两个deposit完成、唯一tx、各3只/1marker、无pending/escrow、原设置0/1 | `pool-restart-20261020-113512-p18785-cd205a72.evidence.json` |
| 地图资源引用 | 修前所有tileset/autotile1→2；修后75064均1→1 | `map-reference-{before,after}-fix-20261020` |
| 跨平台 | 25项仅mock协议/adapter通过；Android/macOS/Linux实机均未通过联机验收 | `multiplayer-cross-platform.zh-CN.md`，不得记为跨平台支持 |

本轮综合场景使用真实Scene_Map和手动回放消息窗口（由显式自动输入驱动），不再用Object.new/automatic跳过这些路径；仍不是人工逐菜单验收。6769构建曾在四场胜利后检测到System设置字节变化，判定整轮失败；因此继续修复真实SaveData污染并重新打包、重新导出目录、完整重跑。失败partial-evidence保留。

最终Ruby整套的前一次在并行原生负载下TLS正向fixture的1秒预算超时；调整测试正常请求预算至5秒后24组通过。没有改015生产代码、没有跳过TLS，0.025秒读写超时和worker deadline断言保留。真实池交易hard-exit/restart专项18项单列，不混入这117项；前三轮分别在并发准备超时、UI内读档、遗漏bootup设置阶段失败。最终按真正新进程的bootup→角色加载→联机UI顺序复验通过，不硬设原选项或吞掉非零退出；三份failure JSON保留并脱敏归档。

已执行的主要命令（PowerShell，项目根目录）：

```powershell
& $python -m unittest discover -s server/multiplayer -p 'test_*.py' -q
& scripts/multiplayer/test-all.ps1 -SkipService
& $python scripts/multiplayer/build.py
& scripts/multiplayer/start-client.ps1 -Profile rental-catalog-cr-release-20261020 -CustomScript tests/multiplayer/rental_catalog_game.rb
& $python scripts/multiplayer/build.py --check
& scripts/multiplayer/run-dungeon-replay-test.ps1 -Port 18782 -TimeoutSeconds 900
& scripts/multiplayer/run-pool-restart-test.ps1 -Port 18785 -TimeoutSeconds 600
& $python tests/multiplayer/dungeon_replay_audit.py temp/multiplayer/dungeon-replay-20261020-110836-p18782-6597acaa.evidence.json temp/multiplayer/cr-20261020/dungeon-replay-audit-evidence.json
& $python tests/multiplayer/review_source_audit.py
& temp/multiplayer/cr-20261020/archive-review.ps1
```

`$python`为setup所列本机Python路径。源检查包含 `git diff --check`、11个PowerShell脚本AST解析，均通过。额外独立交叉CR五套165项通过。归档为 `multiplayer-evidence/2026-10-20-review`，34个显式测试日志/脱敏JSON/PNG/构建manifest，逐文件SHA256复核；不含凭据、数据库或存档。各真实Game的Handle在退出前保留，严格拒绝null退出码。

尚未验收：人工菜单及离线单机完整回归、两台电脑LAN/物理断网、公网、Android/macOS/Linux联机、全部特殊机制/形态。当前Android APK没有联机模块或构建清单、无INTERNET权限/生产联网adapter，因此当前不可用。既有超高Indoor.PNG的pixman warning已用仅Bitmap探针复现，独立于联机；缺本地融合立绘可显示问号，占位图不算完整素材验收。
