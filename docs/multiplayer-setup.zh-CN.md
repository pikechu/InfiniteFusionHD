# 联机开发安装与使用

2026-10-21新增启动前在线/离线选择、注册登录、云存档、主线地图互见和地图/世界聊天，见 `multiplayer-online-world.zh-CN.md`。Android.8已有HTTPS桥接，本特性补充联机适配、非阻塞数字IP请求及云存档分片；下文旧“没有模块”描述属于历史状态，完整混合游戏仍需最终APK实测。

2026-10-20复审后使用**网络协议2**（API路径与精灵快照格式仍为v1）。客户端、服务端及可信目录须一起更新并重新构建；旧协议不能假装兼容。服务启动现在先绑定端口、取得数据库实例锁，再恢复未完状态；运行中的同库第二服务和初始化会明确拒绝。升级会关闭不兼容旧房间，并保留历史、将无法续战的旧副本安全结束；已提交交易的领取凭据保留，勿删除profile/escrow来绕过恢复。

当前只具备Windows开发验证结果。Windows/Android混合同服尚不可用，具体APK、权限、适配器及设备核实见 `multiplayer-cross-platform.zh-CN.md`，不要把Android单机启动当作联机验收。

当前是全玩法开发验证版；各版代码已接通，人工及跨机发布验收仍未完成，见 `multiplayer-progress.zh-CN.md`。未部署公网。默认绑定本机，不接触真实玩家数据库。默认Game使用015的安全Socket；缺OpenSSL时HTTPS会在发送前明确拒绝，不能改用原生HTTPLite绕过。

本轮新增实际进程恢复验收：`scripts/multiplayer/run-pool-restart-test.ps1 -Port 18785 -TimeoutSeconds 600`会自行创建隔离数据库/profile/存档，并故意让首次客机在领取落盘、ack前退出1；随后用新Game读同一测试存档恢复。仅这一预期中断允许1，最终两端必须0。启动期设置与角色存档先读完再进入联机菜单；不要在联机显示作用域内调用普通读档。最终18项及数据库唯一交易检查已通过，失败harness记录见本轮CR报告。

## 依赖与构建

项目已有 Windows `Game.exe`、Ruby DLL 和资源。联机服务只需要 Python 3，无 pip 依赖。构建工具也使用 Python。当前机器可用：

```powershell
Set-Location D:\others\kurayshinyrevamp
$python = 'D:\Users\meikun.zhang\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
& $python scripts/multiplayer/build.py
& $python scripts/multiplayer/build.py --check
```

在其他机器把 `$python` 换成自己的 Python 3。构建生成 `Data/multiplayer-build.json`，包含实际脚本、战斗数据库、Mods 与插件哈希。修改这些输入后重新运行构建；客户端准备房间前也验证实际文件。构建不覆盖 `Scripts.rxdata`：当前 rxdata 已经加载 `Data/Scripts`。不要把临时测试脚本复制进 `Data/Scripts`，因为加载器执行该目录中的所有文件。

本次随附 `Fonts/NotoSansSC-Regular.otf` 及OFL许可，联机菜单临时使用该中文字体并恢复单机字体。不要删字体后仍宣称中文显示已验收。联机时只用已安装/备用精灵素材，暂缓旧native网络素材下载；退出联机恢复原设置。

租借、托管starter和副本依赖服务的可信十二只目录。更改构建输入后，需要用实际Game重新导出并验证，不能手改目录哈希：

```powershell
& scripts/multiplayer/start-client.ps1 -Profile catalog-export -CustomScript tests/multiplayer/rental_catalog_game.rb
# 等这个进程结束，核对 temp/multiplayer/catalog-export/saves/rental-catalog.log
# 必须有十二条CANDIDATE_PASS和RENTAL_CATALOG_PASS，失败不能继续启动玩法。
& $python scripts/multiplayer/build.py --check
```

目录写入 `server/multiplayer/catalog-rental-v1.json`，客户端摘要必须与其中compatibility相同。托管starter每账号一次，不允许通过重新导入本地个体扩充可信资产。部署自定义目录需重新验证，而不是让客户端上传目录。

## 服务端

```powershell
& server/multiplayer/start-local.ps1 -PythonExecutable $python
```

首次启动自动初始化 SQLite，默认数据库 `server/multiplayer/data/multiplayer-test.sqlite3`，日志在同目录。也可显式指定独立测试库：

```powershell
& $python server/multiplayer/service.py --host 127.0.0.1 --port 8765 --database temp/multiplayer/local-test.sqlite3 --log-file temp/multiplayer/local-service.log
Invoke-RestMethod http://127.0.0.1:8765/v1/health
```

运行前确保日志父目录存在；`start-local.ps1` 会自动创建。停止服务按 Ctrl+C。实时未完战斗在服务重启后异常结束；身份、展示和已完成结果保留。不要对同一数据库并行启动多服务。

需要独立初始化时，在服务停止状态运行 `server/multiplayer/init-db.ps1 -Database temp/multiplayer/local-test.sqlite3 -PythonExecutable $python`。已有库按CREATE IF NOT EXISTS和文档迁移保留记录；此命令也会终止无法恢复的旧实时战斗，不能对正在运行的服务库执行。

备份：先停止服务，再复制数据库及存在的 `-wal`/`-shm` 文件到私密备份目录，恢复时保持服务停止。活动数据库需使用 SQLite backup API。备份包含身份凭据散列和非公开战斗资料，不用于分享。

## 独立测试游戏

```powershell
& scripts/multiplayer/start-client.ps1 -Profile player-a -Visible
& scripts/multiplayer/start-client.ps1 -Profile player-b -Visible
```

脚本在 `temp/multiplayer/<profile>` 准备独立的程序和 mkxp 配置，资源仍读本项目；preload 把 `System.data_directory` 指向该 profile 的 `saves`，避免读写正常游戏存档。每个 profile 的联机凭据也独立保存。启动输出提供进程号、stdout/stderr 和日志路径。新建测试角色后取得至少三只支持的精灵，再用暂停菜单最末的“联机”。不要为测试导入真实玩家存档。

入口：服务器与身份 → 连接测试与登录 → 创建/加入好友房间 → 选择3至6候选及三只顺序 → 双方准备 → 房主开始。客机在持续刷新的房间中自动进入。房主使用真实战斗引擎；客机使用同一原生场景播放权威招式/HP/换人等白名单事件，素材不全时明确降级。锁定前可撤回动作，界面显示服务端倒计时和重连额度；结果后重新准备再战。

展示：从队伍/电脑选择精灵，选择公开字段，发布后把分享码交给好友；更新生成新版本，下架阻止后续查看。收藏只保存引用，不领取精灵。特殊外观资源不全时会提示降级。

恢复码在“服务器与身份 → 导出恢复码”私密导出。更换服务器不会复用另一服务器身份。网络提交超时后通过“恢复当前房间”或再次连接处理已保存的操作；不要手工删除 pending 记录并重复创建业务。

直接从项目根 `Game.exe` 启动也会加载新联机代码，但使用正常单机存档路径；开发验收优先使用上述隔离脚本。

## 第二版与后续玩法

| 联机菜单入口 | 操作与边界 |
| --- | --- |
| 合作Boss / 固定副本 | 创建/加入合作房间，选Boss/难度、各三只，查看队友完整配置、准备；各控己方槽，可发送预设信号。非房主额度耗尽由AI接管，重连下一阶段收回；全灭继续观看。奖章可重复查询只领取一次 |
| 道馆挑战与回放 → AI道馆 | 创建/更新草稿并发布版本；目录查看/收藏/挑战。馆主无需在线；已有挑战使用创建时固定版本。异常后选择恢复战报，未跑完的挑战记录异常，不补写胜利 |
| 交换与托管收藏 → 好友休闲交换 | 明确选择本地来源，选精灵、检查完整报价/不支持原因后双方确认。需要实际保存测试存档；提交后恢复原交易，不自行重建。收到个体保存后才ack |
| 在线奇迹交换池 | 本地休闲区与托管区独立，查看投递状态；未匹配可撤回，24h过期可取回，已匹配恢复领取。不得删pending或换身份规避锁定 |
| 服务器托管收藏箱 | 每账号一次可信starter、查看/展示、托管好友交换和托管池；服务器权威所有者，只更新缓存。不是本地背包/电脑，也不能导入主存档 |
| 租借杯与走动大厅 → 租借杯 | 两人租借房间，房主开杯，公共12只按ABBAAB每人选三；30秒超时规则显示。完成自动进入单打，可再开新杯；精灵/物品不带出 |
| 走动大厅 | 创建或加入四人专用场景；方向键移动、表情、成员名片/邀请、同意后真实对战/交换；地图不符退菜单。退出回原世界位置 |
| 固定副本 | 在两人合作房间选好队后创建run；按双方准备进入三普通战、各自补给、最终Boss。节点间恢复原run；24h、一次未提交战斗重试、双方放弃。只有最终发一次副本纪念章 |
| 回放分享 | 输入已结束battle_id创建回放，各参赛者同意后发布；观众输入分享码观看，作者可下架。含完整队伍会揭示配招；只播放记录状态，不导入精灵或奖励 |

普通联机玩法只使用临时副本；休闲交换会按明确确认写入测试存档。字段支持和存档事务见 `multiplayer-trade-fields.zh-CN.md`；本地备份/回滚允许复制，因此休闲区没有防复制保证。托管区以服务认可目录和唯一owner为准，两种来源不可混用。

网络超时先恢复pending操作，再恢复房间/交易/副本。存在未完交易时禁止切到无关身份或服务器；误丢profile可先设回原服务器，再用原恢复码恢复保存escrow所属身份。不要把token、恢复码、profile.json或保存文件放到公开问题报告。

## 自动验证

```powershell
$ruby = 'D:\others\kurayshinyrevamp\temp\tools\ruby-3.2.9\rubyinstaller-3.2.9-1-x64\bin\ruby.exe'
& scripts/multiplayer/test-all.ps1 -PythonExecutable $python -RubyExecutable $ruby
& scripts/multiplayer/start-client.ps1 -Profile client-unit-native -CustomScript tests/multiplayer/client_test.rb
```

真实双游戏自动输入场景（先启动服务）：

```powershell
& scripts/multiplayer/verify-game.ps1 -PythonExecutable $python
# 实际响应丢失、停止心跳12秒后恢复、实际等待60秒选招超时
& scripts/multiplayer/verify-game.ps1 -PythonExecutable $python -Faults
# 不同速度；历史V1报告和新增客机原生动画报告分开记录
& scripts/multiplayer/verify-game.ps1 -PythonExecutable $python -DifferentSpeed
# 自行启动/重启/停止独立18768测试服务：第一场完整结束，第二场入场中重启
& scripts/multiplayer/verify-game.ps1 -PythonExecutable $python -RestartService -DifferentSpeed
```

它建立两个全新身份和内存测试队伍，启动两次真实 Game.exe，运行真实场景/数据库/战斗引擎，依次创建、加入、展示、选队、准备、战斗、结算和再战。日志保留在两个 `verify-*` profile 下。只自动化输入，不替代人工菜单验收、跨机局域网或公网验收。测试中的 Marshal 只比较/复制受信任本地内存对象，不处理网络输入。

`-RestartService` 使用独立测试数据库，自动在第二场引擎启动后重启其拥有的服务，要求两端均得到无胜者、无奖励的 `service_restart`。此模式不需要另开服务；不要单独使用供人工编排的 `-ExpectRestart`，除非你会在指定阶段实际重启服务。

当前标准联机不支持任何Ruby Mods或非空插件；即使双方文件相同也会阻止开战。红色/蓝色宝珠和究极奈克洛Z也在未适配变身清单中。未知形态或其他不兼容个体应在选队时处理，不能忽略错误强行开始。

独立长流程与默认60秒重连测试（各自启动独立服务/库/身份，自动停止自己创建的服务）：

```powershell
& scripts/multiplayer/run-boss-disconnect-test.ps1
& scripts/multiplayer/run-dungeon-replay-test.ps1
# 只测胜利已提交、advance前真实重启服务，不能替代完整长流程：
& scripts/multiplayer/run-dungeon-replay-test.ps1 -FaultOnly
```

完整副本runner启动两个实际Game和第三位回放观众，检查四战/补给/唯一奖章/回放/原存档，再做第五战及真实服务重启；默认不干预GC。只有全部断言且各Game退出码0才overall_pass。`-GcProbe`仅诊断，不能当正式稳定性验收；`-Executable Game-compatibility.exe`是另一运行时，结果单列。

其他原生场景脚本在 `tests/multiplayer/{rental_game,hall_game,native_guest_game,pool_collections_game_test,pool_restart_game_test,cards_game_test}.rb`；对应命令、独立profile、测试数据库和证据见测试报告及分项文档。它们不能指向真实玩家保存目录。

## 局域网与公网边界

局域网可显式 `-BindAddress 0.0.0.0` 并将两端设置为服务电脑的局域网 IP；各自的 localhost 不是同一服务。当前没有修改防火墙、路由器或公网部署。跨机器测试尚须单独验收。

公网必须使用可信HTTPS入口、验证证书/主机名、限制请求、备份和运维方案。默认mkxp缺OpenSSL，现阶段只验收本机HTTP；不能将公网URL改为HTTP绕过TLS，也未授权公网发布。HTTP开发服务和房主结算不提供防作弊竞技能力；托管仅有目录starter/展示/交换，不构成主线统一经济。
