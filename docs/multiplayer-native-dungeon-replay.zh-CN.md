# 固定副本、回放与服务重启的原生验证记录

验证日期：2026-10-16，Asia/Shanghai。测试使用真实 Windows Game.exe、生产 001–014 联机模块、实际 HTTP/SQLite 服务与独立测试存档。自动化仅选择合法动作、推进原生消息确认及编排服务重启；不伪造战果或以模拟客户端替代游戏引擎。

## 可复现入口

新增：

- `tests/multiplayer/dungeon_replay_game.rb`：加载共享 `test-bootstrap.rb`，启动真实游戏数据库、地图、Mods 和保存对象。
- `scripts/multiplayer/run-dungeon-replay-test.ps1`：启动独立 18782 服务、两位参赛 Game.exe，以及只观看回放的第三位 Game.exe；只终止其自行创建的进程。

```powershell
& scripts/multiplayer/run-dungeon-replay-test.ps1 `
  -GameRoot D:/others/kurayshinyrevamp/temp/multiplayer/dungeon-replay-snapshot-20261016-final

# 仅运行真实胜利后、advance 前的服务重启恢复用例：
& scripts/multiplayer/run-dungeon-replay-test.ps1 `
  -GameRoot D:/others/kurayshinyrevamp/temp/multiplayer/dungeon-replay-snapshot-20261016-final `
  -FaultOnly
```

runner 启动前核对构建与可信目录，不接受 stale manifest。`-GameRoot` 可指向最终项目，也可指向完整源快照；快照必须有自己的 `server/multiplayer` 和匹配目录，不能借此改写项目根目录目录文件。

独立只读 CR 未发现提前跳过战斗/回放断言或误杀其他进程，但提出两项测试入口改进，现已实现：运行编号含端口和随机 GUID，避免同秒并行撞库；新增测试进程明确成功 `exit!(0)`、失败 `exit!(1)`，runner 要等所有自行创建的 Game 正常退出且退出码为 0 才记最终通过。204235 等早期结果仍保留其原始证据格式，不倒填新检查。

此次完整快照含 504 个构建输入、全部 001–014 模块，哈希 `c67e6ecdb4937a7aba606f7cf8ff3999a19c983c0e1f5d08c5e2ed8fe7e144ff`。独立原生目录导出 PID 39568 验证十二只融合与每只四招，目录 SHA256 为 `cb5e5987c7f90b9a4d069afc98fbd95a6052aac58a617de2684894c2d2e135d8`，兼容哈希完全相同。根目录构建与目录未被本次快照验证覆盖。

## 用例及真实夹具

双方原队伍为 31 级三只传奇精灵，原 HP 与首招 PP 均降低，先以原子写入保存独立 `.rxdata`，记录磁盘 SHA256。参赛临时队伍按生产规则转为 50 级，结算仍由房主原生引擎执行。

为确保覆盖真实异常与道具流转，房主首只 Palkia 携 Power Herb，使用 Solar Beam 实际消耗；客机首只 Kyogre 用 Glare 合法选择队友槽 0，产生麻痹，然后恢复正常攻击。目标必须在服务提供的合法 targets 中，不绕过选招或命中判断。双方后续按草系节点使用 Ice Beam，其余主要使用 Surf，并走真实换人选择。房主关闭动画、倍速 4；客机开启原生动画、倍速 2。

每次完成路线、播放回放及恢复后均检查：六个原保存全局对象的身份和 Marshal 摘要、地图与角色位置、独立原磁盘存档 SHA256 均不变。此为自动输入的真实游戏验证，不等于人工逐菜单操作或跨机器联网验收。

## 202522：完整路线与三身份回放已通过，随后发现原生崩溃

运行基名：`temp/multiplayer/dungeon-replay-20261016-202522`。

- 房主 Game.exe PID 72800，客机 PID 31248，第三位回放观众 PID 23036；三个服务身份独立。
- 实际完成普通战 0/1/2、双方休息、最终 Boss 4；四场均为实际引擎共同胜利。
- 服务器保存的节点顺序为 `[0,1,2,4]`，路线状态 completed；逐节点六只完整 HP、PP、异常及道具精确延续。
- 真实 Power Herb 消耗与麻痹状态进入下一节点；原生后续引擎读入的队伍状态与服务 pre-state 一致。
- 休息恢复 HP/PP/异常，保留权威 item，不自动补回已消耗物。
- 恰好两枚最终 `dungeon_medal`，没有途中 Boss 奖励；重复领取同一奖章。
- 双方同意、房主发布最终战斗回放后，三位真实 Game.exe 均播放所有权威帧并得出相同终局；下架后原 download request_id 不能取回缓存内容。
- 上述阶段的原 globals、位置、真实原存档 SHA256 断言均通过。

进入额外恢复夹具的第五场原生战斗时，房主在初始化后发生 native Ruby GC 崩溃：`[BUG] gc_sweep(): unknown data type 0x0`。栈位于 `pbUpdateSpriteHash → window.update → PokeBattleSceneElements.update → battle_wait_update`。不是可捕获的普通 Ruby 异常；runner 判失败并保留证据，不能把整轮记为通过。

证据：

- `temp/multiplayer/dungeon-replay-20261016-202522.partial-evidence.json`，明确 `overall_pass:false`。
- 相同基名的 `.host.json/.guest.json/.viewer.json/.sqlite3`。
- `temp/multiplayer/dungeon-live-host-20261016-202522/stderr.log`，native 崩溃栈。
- 三个独立 profile 的 `saves/feature-smoke.log`、原 `.rxdata` 与 PNG 截图。

只读 SQLite 审计：integrity=ok，完成路线有四笔历史、奖章仅两枚，回放最终 private。首次客机截图的融合 Boss 使用本机缺失素材的问号占位；原生动画呈现未退回轻量界面，此资源限制单独记录。

## 203031：独立真实服务重启恢复 40/40 通过

为完成不受上述累积 GC 场景影响的恢复验证，使用全新进程与数据库单独运行 `-FaultOnly`，没有先播放回放。

- 房主 PID 37872、客机 PID 72748；两进程实际完成节点 0 胜利。
- 重启前明确确认最终 `battle.state.team_states` 与 `result.team_states` 均存在且相同，包含两队六只的非活动精灵状态；尚未调用 `/advance`。
- 实际停止自建 Python 服务 PID 70728，并在同一个测试 SQLite 上启动 PID 57248。
- 重启后该战斗仍是同一笔正常 finished/victory；调用生产 `DungeonSession.mutate("advance", {"battle_id":...})`，没有提供客户端猜测的 state。
- 正常进入节点 1，全队状态与已提交权威记录相同，`retry_used=false`；另一真实 Game.exe 读取同样状态。
- 双方分别投票结束夹具，最终 abandoned；没有中途奖励。
- 原 globals、原角色位置及实际磁盘存档 SHA256 全程未变。

共 **40 项原生断言通过**。证据：`temp/multiplayer/dungeon-replay-20261016-203031.evidence.json`，明确 `fault_only:true`；同基名 SQLite 只读审计 integrity=ok、节点历史一条、正常 victory、retry=false、reward_count=0。测试服务已停止，所有日志和测试存档保留。

## 203900 / 204235：主动 GC 诊断对照

`-FaultOnly -GcProbe` 的 203900 对照再次通过 40/40。`-GcProbe` 的 204235 完整场景通过 **102/102**：房主 PID 73792、客机 62060、第三观众 5580，实际服务重启 PID 44416 → 63928。四场路线、三端回放、回放后第五场战斗以及缺省 state 的正常胜利恢复全部完成。

诊断仅在测试脚本中调用 `GC.start`，记录每场 `engine_finished`、`settlement`、奖章领取、每个回放 `BattleBoard.dispose` 及回放返回的 BEGIN/END。所有边界均通过；没有禁用 GC，也没有改生产 Data。证据为 `temp/multiplayer/dungeon-replay-20261016-204235.evidence.json`，其中 `gc_probe:true`，不能将改变 GC 时序的诊断通过称为产品崩溃修复。

只读 SQLite 审计 integrity=ok，五场均 finished/victory 且全队 authority state 存在；只有完成主路线的两枚 `dungeon_medal`，额外恢复夹具无奖。

203959 诊断在首战前因测试协调文件被 PowerShell reader 短暂占用而失败（`File.rename EACCES`）。仅为测试 reader 加 `FileShare.Delete`、writer 对同一文档短暂重试；此故障不属于游戏网络协议。runner 同时支持 `-Executable Game-compatibility.exe` 的独立对照，但目前本记录通过项均使用默认 Game.exe。

## 204616 与原生网络/画面诊断

204616 不带 GC 干预完整复测，客机 PID 69796 在第三场 Surf/HP 原生动画期间静默退出，尚未播放回放；stderr 没有普通 Ruby 错误，也没有外层 rescue 标记。保留 `.partial-evidence.json`、数据库及日志，不能记通过。因此现象不能仅归因于回放后的第五场。

新增两份仅测试诊断脚本：

- `tests/multiplayer/native_battle_gc_baseline.rb`：普通 `PokeBattle_Battle` 双方 AI、同样保存隔离/呈现清理，完全无网络、无回放、无客机呈现器。PID 57164 连续 **8 场真实战斗、16 项断言通过**；`temp/multiplayer/dungeon-native-offline-20261016-2050/saves/native-battle-baseline.json`。
- `tests/multiplayer/native_guest_gc_baseline.rb`：从自有 204235 测试库导出四场真实公开 visuals，重复呈现两遍，仅用于资源定位，禁止执行 combat。PID 38800 无 HTTP 时 **8 场全部通过**、自然 GC 计数 46→112；`dungeon-native-guest-recorded-20261016-2052/saves/native-guest-baseline.json`。
- 同一 guest 诊断加入实际 `Client` 每 0.5 秒 GET 自己的测试房间后，PID 62704 完成六场/244 次记录的 GET，进入第七场时 **native Segmentation fault**。无截图、无回放、无战斗运算；栈为 `001.raw_request → pump → 014.update → PokeBattle_Scene.pbFrameUpdate:112 each_with_index`。证据 `temp/multiplayer/dungeon-native-guest-http-20261016-2053/stderr.log:43`。服务 PID 74336 已停止，仅修改独立测试数据库。

随后仅测试的 `join`（不 kill 成功 worker）对照 PID 67204 完成 8 场/312 次 GET，主线程 HTTPLite PID 58380 完成 8 场/276 次 GET。样本通过不能证明并发安全，主线程只能用于本地诊断，不能直接作为会阻塞远端等待的产品方案。

运行时能力探针 `tests/multiplayer/native_socket_capabilities.rb` 证实 `socket`、`io/wait`、`fcntl` 可用，`openssl`、`timeout` 缺失。`Socket#connect_nonblock` 包装方法缺失，但底层私有 `__connect_nonblock(address, true)` 可调用；`IO.select/read_nonblock/write_nonblock` 均存在。证据 `temp/multiplayer/native-socket-capabilities-20261016-2104/saves/socket-capabilities.log`。

`tests/multiplayer/native_socket_transport.rb` 为仅诊断的 Socket 参考（HTTP/IPv4、非阻塞 IO、统一 deadline、有界 header/body、严格 Content-Length），不直接充当生产 HTTPS 方案。PID 76644 同样 **8 场+301 次实际 HTTP 请求全部通过**，自然 GC 计数 48→115，全局对象摘要保持；结果 `temp/multiplayer/dungeon-native-guest-socket-20261016-2106/saves/native-guest-baseline.json`。自建服务 PID 76440 已停止。另一个 curl 子进程尝试在 HTTP 前即 `IO.popen → Errno::EACCES`，独立 Ruby 3.2 同样失败；未规避系统限制，不计网络验收。

上述定位诊断未改生产 Data，也未禁用 GC。

## 正式传输修复与约束测试

定位后新增生产模块 `Data/Scripts/054_Multiplayer/015_Transport.rb`，桌面 `HTTPTransport.backend=core_socket`，不再通过 HTTPLite 执行联机请求。标准 Socket/IO 使用一次操作 deadline、部分读写、Windows connect exceptional fd/SO_ERROR、多地址回退；响应头、body、chunk、trailer 均有边界，支持 Content-Length、chunked 与 EOF 帧，拒绝压缩、重定向和冲突帧。JSON 仍由原 `WireJSON` 校验。

原生没有 OpenSSL 时，HTTPS 在请求和业务 journal 写入前明确拒绝；独立 Ruby 可使用验证证书链和 hostname 的 OpenSSL。Android 保留已有显式适配器及不可用时关闭网络的行为，未将其当成 Windows 验收。注册的 Ruby worker 仍活跃时，旧 `KIF::Platform` 原生素材 HTTP 返回 deferred/status0，避免旧入口再次与安全 worker 并发；线程自然结束后恢复原单机入口。

新增 `tests/multiplayer/transport_test.rb`：独立 Ruby **74/74**（包括实际 TLS 可信链、错误链、hostname mismatch），默认 Game.exe Ruby3.1.3 **72/72**（PID65340），Game-compatibility.exe Ruby3.0.0 **72/72**（PID75800）。包含单字节分片、实际 HTTP POST、非法帧/UTF8/大小边界、读写 deadline、真实 Socket 超时 journal 保留、成功自然 join、画面更新异常不杀线程、超时拦重叠请求、旧入口并发 guard、恢复单机和 Android 适配器边界。证据分别为 `temp/multiplayer/transport-unit/transport-test.log`、`transport-unit-native-20261016-2136/saves/transport-test.log`、`transport-unit-compat-20261016-2138/saves/transport-test.log`。

独立 CR 已检查正式模块，未见新增 P1/P2；Windows IPv6 首地址不通导致 IPv4 未尝试的问题已修并回归。正式传输修复后仍须重新构建、绑定目录并跑完整闭环，不能以约束测试替代。

最终 Root 构建为 505 个输入，全部 001–015 模块，data_hash `1966bc2706370baea420e3a605a75c93c6ad61c75cef87aed1ce82447e4b5871`，原生可信目录 SHA256 `e45e92c2af476b8d9242751df9f4058420ad4dceda7e96d5435a9c37a08bc7b5`。正式 Root 默认 `HTTPTransport`（未注入测试传输）的原生压力 PID68596，连续 **8 场、261 次实际请求通过**，自然 GC48→118、所有原全局对象摘要保持。证据 `temp/multiplayer/dr-prod-stress-20261016-2140/saves/native-guest-baseline.json` 与同目录日志；独立18783测试服务PID70692已停止。

## 214631：最终 Root 默认 Game 完整 105/105 通过

```powershell
& scripts/multiplayer/run-dungeon-replay-test.ps1 -Port 18782 -TimeoutSeconds 1800
```

基名 `temp/multiplayer/dungeon-replay-20261016-214631-p18782-da34df99`，直接使用最终 Root，505 构建输入、上述最终哈希与目录相同。`gc_probe:false`、`capture_images:true`，没有测试传输注入。实际加载全部 001–015 模块；三个身份均明确断言并记录 `http_backend:core_socket`、Ruby3.1.3。

| 角色 | Game PID | 原生断言 | 自然退出码 |
| --- | ---: | ---: | ---: |
| 房主 | 34768 | 45 | 0 |
| 客机 | 9572 | 42 | 0 |
| 独立回放观众 | 73420 | 18 | 0 |

完整通过项：

- 四场真实副本战斗、双方休息及唯一最终纪念章；节点顺序 `[0,1,2,4]`。六只 HP/PP/异常/道具逐节点精确延续，真实 Power Herb 消耗、Glare 麻痹、换人和休息恢复均经原生引擎执行。
- 房主动画关闭/速度4，客机原生动画开启/速度2，无轻量呈现 fallback；第三身份完整播放权威回放。双方同意后发布、三端同结果、下架后原 download request ID 拒绝。
- 回放后第五场真实战斗正常胜利；`state.team_states` 和 `result.team_states` 在重启前已完整提交，尚未 advance。
- 实际服务 PID34260→63656 在同一 SQLite 重启。省略客户端 team_states 的生产 `/advance` 恢复到节点1，沿用完整权威状态、`retry_used:false`，另一真实客机读取一致；双方投票结束恢复夹具。
- 原六个 globals 的对象身份、完整摘要、原地图位置及实际原存档 SHA256 全程保持。
- 三个 Game 进程都写入完成标记后自然退出，runner 用启动时保留的原生进程句柄确认真实 exit0；`.evidence.json` 明确记录每个 `client_processes.exit_code`，没有将 null 当0。

只读 SQLite 审计：integrity=ok、三个独立身份；主路线 completed/history4，恢复夹具 abandoned/history1、retry=false；五场均 finished/victory、每场完整 authority team_states 等于终局 result.team_states；恰好两枚主路线 `dungeon_medal`、无节点奖励；回放最终 private。三个 stderr 中未检出 BUG/Segmentation fault/Native fail/fallback。自建18782服务和游戏进程均已清理，测试日志、存档、数据库、截图均保留。

证据：上述基名 `.evidence.json/.host.json/.guest.json/.viewer.json/.sqlite3/.service.log`，及 `temp/multiplayer/dr-{host,guest,viewer}-20261016-214631-p18782-da34df99/` 内日志、原存档与截图。旧失败证据仍保留，未改成通过。

## 221148：回放 CR 修复后的最新 Root 再次 105/105 通过

上一轮真实截图发现回放图片/HP 标签重叠和公开外观未应用，已在 `003_Battle.rb` 中修复：每列等比限幅图片，名称/HP/状态独立分行，公开 appearance/form/gender/shiny 经完整白名单校验后复制应用。`012_Replay.rb` 在创建任何 Board 前校验全部帧，限制重复 slot、视觉 seq 倒退与权威状态分歧，并将坏视觉数据转为菜单可恢复的 `invalid_replay`。独立只读 CR 无新增 P1/P2，相关回归 192/192、29/29 通过。

新构建仍为 505 个输入、全部 001–015 模块，data_hash **`92b6c5b61df113c696ed5ae910f4dfaa92c400f804c6b6c87d3ecc50811c14e0`**；严格原生可信目录 SHA256 **`f0d90407412439903b2b8073fb3dd3501348a2e4b465a5d7bc5e8cafe9d9c0fd`**。与上一轮 1966 记录独立，不将历史通过结果回填为新版本。

执行相同默认命令，基名 `temp/multiplayer/dungeon-replay-20261016-221148-p18782-67b83f6b`。房主 PID68832（45项）、客机42204（42项）、第三观众344（18项），均 `core_socket`、Ruby3.1.3、自然 **exit0**，`gc_probe:false`、`capture_images:true`，完整 **105/105 通过**。四场副本、休息、唯一纪念章、逐节点 HP/PP/道具/异常延续、三端回放、下架旧请求拒绝，以及回放后第五场真实战斗均通过；服务 PID73548→68456 实际重启后省略客户端状态正常推进、retry=false；原 globals/位置/真实原磁盘存档 SHA256 不变。

只读 SQLite 再审 integrity=ok：五场均 finished/victory、完整 authority state 等于 result.team_states；主路线 completed/history4，恢复夹具 abandoned/history1/retry=false；恰两枚 `dungeon_medal`，没有节点奖励，回放最终 private。三个真实进程退出码均在新 `.evidence.json` 中记录。自建18782进程已清理。

已实际目视新三列回放截图 `temp/multiplayer/dr-viewer-20261016-221148-p18782-67b83f6b/saves/dungeon-replay-1-replay_frame.png`，图片和每列名称、HP、状态完全分开、中文清晰。另目视原生四列与公开闪光证明 `temp/multiplayer/battle-board-layout-native-b/saves/battle-board-4.png`，四槽信息和 `★ Shiny Palkia` 均清楚；该专项原生检查 PID71728 通过。缺少融合素材的问号仍明确保留为资源限制。

## 仍未由本记录验证

人工逐菜单操作、跨机器局域网和公网均未由本记录验证；捆绑原生运行时的 HTTPS 因没有 OpenSSL 明确阻止。首个融合 Boss 的本地素材缺失问号占位仍属资源限制。最初的 native GC/段错误已定位到不安全 HTTPLite 并发入口，经正式安全传输、原生压力和默认完整闭环复测解决；未用关闭 GC 或换兼容运行时来替代修复。早期 Digest、消息确认、marker 共享锁与退出码采集问题均为测试入口修正，历史失败记录保留。
