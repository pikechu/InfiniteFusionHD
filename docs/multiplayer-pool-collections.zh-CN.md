# 在线交换池与服务器托管收藏箱

实现文件：`009_Pool.rb`、`010_Collections.rb`。二者复用联机异步 HTTP、身份认证与操作编号恢复，不使用旧离线 Wondertrade 或本地任意对象导入。

## 在线奇迹交换池

自由休闲区接收本地精灵完整受限 JSON 快照，字段及不支持原因参见 `multiplayer-trade-fields.zh-CN.md`。服务器托管区只接收当前服务器资产编号，不接受本地快照。服务器按来源、完整兼容标识、不同账号进行匹配，两个分区不互相匹配。

一个账号同时只有一个未完成的投递。投递编号由客户端生成并提前持久化；服务器保存固定报价及 24 小时过期时间。客户端先真实存档锁定原个体，之后才提交自由区投递。失败、响应丢失或重启后查询原编号与通用操作状态，不重新随机生成投递。

未匹配可以撤回。匹配和撤回竞态由服务端数据库事务决定；若撤回返回“已经匹配”，客户端查询并领取原交换结果。未匹配满 24 小时进入过期取回状态，服务器时间为准。撤回和过期取回原始锁定对象，不重新构造替代品。

匹配、撤回和过期均有唯一结果编号与领取凭据。自由区一次完整原子存档同时写入收到的个体（或退还原个体）、清除 escrow 和写入结果应用标记，然后 ack。保存成功后 ack 失败，重启只补 ack；保存失败保留原 escrow。profile journal 丢失时，存档的 escrow 或已应用标记可恢复。任意原存档缺失不会从网络报价自动复制个体。

源于本地存档的精灵仍可能被备份、导入和主动回滚复制，不能把流水或 UUID 当成无复制承诺。

## 服务器托管收藏箱

托管收藏只认可服务器安装的受版本控制目录，由服务端给新账号发放一次固定初始资产，保存不可变资产 ID、权威快照及当前 owner_id。重复领取不生成第二个资产；已转让原资产也不恢复领取额度。客户端不接受“把本地精灵上传后升级为可信资产”的操作。

收藏箱内可以查看个体和外观、发布服务器快照展示、进行托管好友交换与托管奇迹池交换。它们不写入主队伍或电脑，不让导出的本地缓存重新充当资产。客户端 profile 缓存仅用于显示，每次归属和操作都以服务器返回为准。培养、融合、拆分未开放，界面没有虚假可用入口。

托管好友交换使用当前报价版本、双方资产与快照 hash 双确认。服务端在一个数据库事务中同时更新双方资产 owner_id，并生成各自不可变凭据。报价和投递通过 asset lock 防止同一资产并行参与好友交换和交换池。提交前取消解除锁定；提交后不能单方撤回。

客户端检查收据来源、领取者、当前交易编号、双方已查看报价 hash 和收到资产 ID/快照，再刷新服务器库存并 ack。客户端不执行本地个体替换，即使重新查询旧凭据也不会再次分配服务器所有权。

## 操作入口

- `KIFMultiplayer.open_pool_menu(client)`：自由休闲区、恢复、撤回、记录，以及托管区入口。
- `KIFMultiplayer.open_collection_menu(client)`：托管收藏、初始赠送、展示、托管好友交换和托管池。
- `KIFMultiplayer.open_managed_pool_menu(client)`：直接进入托管奇迹交换池。

自动化接口：`PoolSession#deposit/recover/withdraw/list`、`CollectionClient#starter/refresh/publish`、`ManagedTradeSession#create/join/offer/get/confirm/recover/cancel`、`ManagedPoolSession#deposit/recover/withdraw/list`。所有调用都使用真实 HTTP 服务；测试替身只用于故障单测。

## 测试与当前证据

本地故障单测：

```powershell
& temp/tools/ruby-3.2.9/rubyinstaller-3.2.9-1-x64/bin/ruby.exe --disable-gems tests/multiplayer/pool_test.rb
& temp/tools/ruby-3.2.9/rubyinstaller-3.2.9-1-x64/bin/ruby.exe --disable-gems tests/multiplayer/collections_test.rb
```

目前分别 26 项和 27 项通过，覆盖本地存档锁定、重启、重复领取、未上传恢复、撤回、过期、匹配后撤回、身份切换阻止、跨来源待处理投递在本地锁定前拒绝、来源与归属、目录重复领取、资产并行锁定、假缓存不能改权威所有权及主存档不变。服务端并发、来源和持久化测试由真实 backend 单测单独记录。

真实双游戏场景为 `tests/multiplayer/pool_collections_game_test.rb`，需两个隔离 Game.exe、独立测试身份、独立存档及独立真实服务数据库，使用共同的 `KIF_MULTIPLAYER_SCENARIO` 协调文件。它验证双方远端个体实际存盘、自由区撤回、服务器目录赠送唯一、托管展示、托管好友交换、托管池匹配及主存档对象摘要保持一致。最终执行结果、进程号和证据路径在测试报告中登记；不以测试替身结果代替实际游戏验收。

复现时先构建并启动独立服务数据库，再用新 profile 名称运行两个客户端（两条命令使用相同 Scenario 文件，profile 分别含 host / guest）。可复用的实际游戏 runner 位于测试目录，无需依赖临时脚本：

```powershell
& scripts/multiplayer/start-client.ps1 -Profile pool-host-new-run -Server http://127.0.0.1:18780 -Scenario temp/multiplayer/pool-new-run.json -CustomScript tests/multiplayer/pool_collections_game_runner.rb
& scripts/multiplayer/start-client.ps1 -Profile pool-guest-new-run -Server http://127.0.0.1:18780 -Scenario temp/multiplayer/pool-new-run.json -CustomScript tests/multiplayer/pool_collections_game_runner.rb
```

2026-10-16 本模块已实际执行：先用 `build.py` 生成 500 文件构建清单，再启动独立 18780 服务、两个独立 Game.exe（PID 45812 / 66444），使用真实 `client.compatibility` 完整校验同一构建。双方各 15 项、合计 30 项通过，自由区远端个体经真实 `SaveData` 重新读盘核对；托管流程前后主队伍与电脑对象摘要完全一致。两进程正常退出后，对 SQLite 只读核验：5 份投递全部已领取，其中 4 份匹配、1 份撤回；托管好友交换 1 笔已完成；服务器恰好 2 个资产、2 位不同所有者；初始赠送流水恰好 2 条；遗留资产锁为 0。

证据：

- `temp/multiplayer/pool-live-host-20261016-181857/saves/pool-collections-native.log`
- `temp/multiplayer/pool-live-guest-20261016-181857/saves/pool-collections-native.log`
- `temp/multiplayer/pool-live-evidence-20261016-181857.json`
- `temp/multiplayer/pool-http-20261016-181857.sqlite3`

本次服务 PID 69688 已在验证后停止，数据库与日志保留。上述属于两个真实游戏运行时中自动调用生产会话 API 的集成验证；人工菜单点击、跨机器局域网与公网验证仍需分别记录，不能视为已通过。

附加的真实进程恢复测试也已执行通过：`tests/multiplayer/pool_restart_game_test.rb` 在客机真实保存收到个体与 transaction_id 应用标记后，故意在发送 ack 前中断连接并硬退出 `Game.exe`；随后使用同一个隔离 profile 和真实存档启动另一个游戏进程。客机从 PID 68904 变为 PID 74916，恢复原身份和操作编号，只补 ack；房主 PID 67740 完成同一笔交易。共 10 项断言通过，SQLite 重新核验 2 份投递全部完成，唯一交易数量为 1，双方各 3 只队伍精灵、1 个应用标记。

测试首次重启曾因诊断 runner 先初始化新游戏、未调用 `SaveData.mark_values_as_unloaded` 而跳过存档玩家字段；该测试脚本问题已按正常读档流程修复并成功重测，生产交换代码未改动。原始失败与后续成功日志均保留：

- `temp/multiplayer/pool-restart-host-20261016-182449/saves/pool-collections-native.log`
- `temp/multiplayer/pool-restart-guest-20261016-182449/saves/pool-collections-native.log`
- `temp/multiplayer/pool-restart-evidence-20261016-182449.json`

重启测试使用独立 `pool-restart-snapshot-20261016-1823` 源码快照、18781 服务及 `pool-restart-20261016-182449.sqlite3` 测试库；服务 PID 67752 已停止。复现时在上述 runner 启动命令前设置 `$env:KIF_POOL_GAME_TEST = 'restart'`，先启动 host / guest；客机日志出现 `POOL_RESTART_REQUIRED` 并退出后，用相同 guest profile、Scenario、Server 和 GameRoot 再启动一次，完成后清除此测试环境变量。新的一轮测试必须使用新的 profile / Scenario / 数据库，不能复用已完成场景伪造一次新的崩溃。
