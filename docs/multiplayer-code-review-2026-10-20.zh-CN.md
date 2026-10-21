# 联机全面复审与修复记录（2026-10-20）

本轮重新检查当前源码，重点为断线重连、交易恢复、原存档保护。没有将10月16日的通过记录当作本轮结论。保留原工作区13处tracked修改，三个并行分工分别负责服务状态机、交易/池/托管、战斗/道馆；根代理负责客户端日志、入口、大厅/回放隔离和整合。

测试均使用独立身份、数据库和存档；未接触真实玩家数据，未部署公网。修复后进行了交叉复审和更严格的原生回归；最终结果见下文。Android/macOS/Linux跨平台同服当前不能标为支持，详细结论见 `multiplayer-cross-platform.zh-CN.md`。

## 已复现问题与修复方向

| 优先级 | 触发及影响 | 修复与已有证据 |
| --- | --- | --- |
| P1 | pending查询返回401时，共享definitive标记可让外层相同编号请求误删旧日志 | 001仅在当前已提交请求的明确4xx拒绝时清理；恢复GET错误不清旧pending |
| P1 | 恢复先删除pending再另存receipt，中间磁盘失败会同时失去操作与结果；清日志失败后内存也丢pending，可覆盖磁盘旧记录 | receipt和pending一次原子保存；失败回滚内存；20项真实Profile磁盘故障边界测试通过，最初12项有11项失败 |
| P1 | HTTP503等可能发生在上游commit后，原实现当明确失败清日志 | 5xx/408/425/429保持不确定状态，先查原编号；非法operation结果不清日志 |
| P1 | native确认窗口会miniupdate原Scene_Map，临时队伍隔离不保护地图、角色或传送 | 003中性scene，逐项清理并恢复；真实Game修前确认栈失败、修后原地图四种callback均0、原磁盘SHA不变 |
| P1 | 手动回放与结束消息仍可更新原地图；原验收automatic回放加Object.new掩盖了这条路径 | 012将全部消息纳入隔离和中性scene；13项scene恢复单测包含正常、异常及菜单返回 |
| P2 | 大厅离开时profile写失败会跳过后续ensure，遗留HallScene和wait callback | 008关闭失败记录日志，独立ensure保证scene/callback/资源恢复 |
| P2 | 联机主菜单长期等待仍运行原地图miniupdate | 002入口静止原世界，正常及错误提示后恢复scene和原单机设置 |
| P1 | 两个同身份房主引擎可交错计算/提交；心跳采用了较新turn后把旧结果贴到新turn | 单场不可转移authority_id、exact locked turn/digest；协议2拒旧端；四进程实测杀死真实房主，同身份冲突引擎被拒，读接口不能续命，唯一异常结束且无奖励 |
| P1 | 第二服务先打开同DB执行restart恢复，随后端口绑定失败，也会结束原服务战斗 | 先绑定端口，Store前获得同DB进程锁；init-db同样加锁；同端口/同数据库竞争均覆盖 |
| P1 | 原精灵已经durable escrow，但保存locked profile失败、尚未POST时恢复没有续传分支 | 006/009保存原报价编号后安全续传；交易/池专项故障测试已通过 |
| P2 | 本地DoubleAbilities开关使未改原对象的第二特性导出变化；已应用marker的纯ack还重新import，正常培养/设置变化可阻塞恢复 | 保留raw第二特性，已应用只验marker后ack；真实Game修前失败、修后与原对象字节保护通过 |
| P2 | SaveAs后绝对路径不同永久拒恢复；profile失败可删掉仍在磁盘的经济journal/草稿 | 同UUID谱系、真实新槽escrow/marker证明后迁移，不写旧槽；profile原子变更失败回滚；不宣称UUID防复制 |
| P2 | 道馆创建恢复结果单slot被后续恢复覆盖后，active挑战没有本地journal | 查询自己服务端active挑战恢复原ID，不重建或猜胜利；专项8项通过 |
| P1 | 客机迟到/无效动作先触发时间推进再返回409，外层rollback撤销了断线额度/默认动作 | 时间推进保留，业务动作通过SAVEPOINT单独回滚；累计额度精确扣减，迟到动作不复活控制权；租借断线和选人超时同样修正 |
| P2 | 大厅邀请先内存标记已打开，之后持久失败；服务已接受邀请但丢本地房间码后不能恢复 | handled与room_code原子保存后再打开；无本地指针时查询自己有效房间；9项故障/重启用例通过 |
| P2 | 新交换池收据缺少received_hash一致性检查；旧收据处理可能清除新操作指针 | import和已应用ack分支均绑定快照摘要；历史完成结果只清对应journal；独立CR后重测 |
| P2 | 原生普通闪光模式把合法高级通道12..25重随机，战斗选队受单机NO_LEVELS等影响 | 战斗快照在临时标准规则下导出并恢复原对象；展示保留其单独策略；原生高级颜色24/23/22修前失败、修后逐值一致；真实snapshot规则56项通过 |
| P1 | UI临时setter修改原PokemonSystem，交易编译完整SaveData时把临时下载/颜色设置写入原槽 | 改用当前线程的class getter覆盖，不改实例ivars；嵌套/异常/后台线程及Marshal字节保护回归；真实TradeSave修前disk为[[1,2],[1,2]]、修后[[0,1],[0,1]]，Game98136 exit0 |
| P2 | 新增中性scene在disposeSpritesets之前设置，Spriteset_Map.dispose跳过tileset/autotile释放 | 先在原地图上下文释放、再静止scene；真实Game68596修前所有资源引用1→2，Game75064修后均1→1 |
| P2 | 客机局部绘图状态落后于权威语义状态时继续假定可播放会展示错误对象 | 校验当前可视化帧与权威状态；不一致安全回退战报/状态板，不能据本地动画修改权威结算 |

## 测试与证据

- 新客户端日志回归：`tests/multiplayer/reconnect_journal_test.rb`，20项；目录 `temp/multiplayer/cr-20261020/journal-*`。
- 新scene回归：`tests/multiplayer/scene_restore_test.rb`，13项；菜单修前/修后日志在 `temp/multiplayer/cr-20261020`。
- 原生场景隔离：`tests/multiplayer/scene_isolation_game.rb`；修前Game89768失败，修后Game89296通过；分别保存在 `scene-isolation-{before,after}-fix-20261020`。
- 交易专项最终：trade88、transaction_recovery31、pool42、collections32、cards34。实际Game73792的codec/SaveAs/只ack检查72项通过，见 `trade-final-native-20261020`；Game108020的真实快照/规则验证56项，均保留strict exit0证据。
- 服务端全套：`python -m unittest discover -s server/multiplayer -p 'test_*.py' -q`，148/148通过，392.707秒，日志 `temp/multiplayer/server-cr-20261020-current148.log`。含权限/版本、逐回合锁定、累计额度、服务重启、交易唯一领取和数据库进程锁。
- 原生房主崩溃：`scripts/multiplayer/run-authority-restart-test.ps1`；实际房主85216被终止；108144同身份冲突引擎被拒；68756客机和97812只读恢复进程继续运行。只读66次/52.1秒不能延长死亡引擎；最终host_disconnected、奖励0，三个存活进程exit0，原磁盘SHA不变。此专项为较早b239构建，不能冒称最终feef构建重复跑过。
- 设置污染真实保存：`tests/multiplayer/ui_save_settings_game.rb`，修前Game106872 exit1，修后98136六项断言、exit0；首次60秒启动上限的未完成运行单独保留，未作为通过。

## 最终构建与加载

协议2，505个摘要输入文件，data_hash=`feef1f616182aebb3b836e09a4771e84b13892681ff867197c17d3be0d3f6b6c`；mods_hash=`76555b5b8dd130f83b6cd8099cb1f31c1e7960b994df771e6c5d11c9930473c6`。`build.py --check`通过；Game105412原生重新生成12个租借个体并将48招注册到真实战斗器，exit0；可信目录SHA256=`adf5fee624d456012c30dac7bd7e256fd891ed52f421bcef28a17b7862196c5a`。

普通启动不带customScript：Game89620实际经Game.ini→Data/Scripts.rxdata→Data/Scripts执行15个联机模块，最终方法来源015_Transport、003_Battle、012_Replay和feef摘要均有TracePoint记录。证据 `temp/multiplayer/cr20-release-production/saves/runtime.log`；采集完成后只停止本轮独立测试进程，不将强制停止写成自然exit0。

## 更严格综合验收与未验证项

综合场景已改用真实Scene_Map，回放驱动真实消息窗口，并在原地图miniupdate/map.update/player.update/transfer上安装越界哨兵。6769构建的 `20261020-104521-p18782-8dc512e8` 虽完成四战和唯一奖章，但设置字节检查失败，整轮仍判失败；本轮因此新增真实SaveData污染修复。日志和partial-evidence保留，不倒填通过。

最终feef综合场景 `20261020-110836-p18782-6597acaa` **117/117通过**：房主97724（50项）、客机22580（47项）、独立回放查看者24476（20项），三个真实Game.exe自然退出码均为0；服务62156实际停止并由106844接替。包含四战完整路线、HP/PP/麻痹/换人/道具携带与休整、唯一奖章、三方手动回放窗口、撤销后旧请求不能下载，以及第五战正常胜利提交后服务重启恢复。不是人工菜单验收。

只读审计 `tests/multiplayer/dungeon_replay_audit.py`核实SQLite完整性、5场唯一正常胜利/5个终局、最终奖章仅2行、completed+abandoned两条路线、重启胜利未消耗异常重试、回放已撤销；三份真实原存档SHA与原六globals摘要均未变，原地图四种callback为0。证据 `temp/multiplayer/cr-20261020/dungeon-replay-audit-evidence.json`，主runner日志 `native-full-release.log`。

并行负载下Ruby全套首次在TLS证书用例的1秒握手期限超时，独立负载时另一个正常partial POST的1秒期限也曾超时。只调整测试正向/证书fixture预算为5秒，生产015代码及Client默认8秒不变；0.025秒短读/短写、worker deadline、拒连等专用超时断言保留。空闲后独立transport74/74、exit0，证书链/可信CA+hostname/hostname mismatch均实际执行。最终`test-all.ps1 -SkipService`的**24组Ruby全部通过、exit0**，日志`ruby-all-release-retest.log`；它不冒称重新跑过148项服务或替代真实游戏。失败日志保留。

最后交叉CR复核001/002/008/012，独立再跑client61、identity53、scene13、hall invite9、gym/dungeon/replay29共165项，未发现新增P1/P2。交易代理亦复审客户端，服务代理复审权威与收据摘要，发现后已直接修复、重测；不把“未发现”解释成所有路径已穷举。

## 真实交换池领取后崩溃与进程恢复

最终同一feef构建执行`run-pool-restart-test.ps1`，run=`20261020-113512-p18785-cd205a72`：房主Game109328 exit0；首次客机91604在真实SaveData持久收到个体和应用marker后、ack前故意`exit!(1)`；独立Game102460使用同一隔离profile/存档重启，先完成普通bootup/角色读档再进入真实UI scope，恢复原事务并exit0。合计18项业务检查通过，非单纯mock接口。

重启时party与marker的Marshal摘要前后相同：只补ack，不重新导入。两端最终party=3、应用marker=1，pending/escrow均空；原System磁盘raw下载/颜色设置0/1仍保存。只读SQLite审计确认两个不同身份、2笔completed deposit、1个共同transaction、双方acked、互换的真实快照相等、锁0，未混入好友交易。证据为`pool-restart-20261020-113512-p18785-cd205a72.evidence.json`及两端`pool-collections-native.log`。

前三轮harness失败均保留，不改判：`110938-...a7f73f10`在5Game并发准备hash/codec期间超出等待，尚未到guest提交或ack；空闲timing确认构建复查约2.7–3.5秒、存盘约0.2–0.9秒。`112305-...18995faf`错误地在UI内执行普通读档；`112930-...418b47e2`虽移出UI，但诊断已初始化bootup，`mark_values_as_unloaded`只重置非bootup，仍漏恢复启动设置。最终只在测试启动器模拟全新进程的两阶段加载，不硬设恢复值、不放宽outer设置断言，不改生产Data。三份failure JSON已脱敏归档。

## 交付与接续

关键代码为001客户端请求/恢复、002UI与设置作用域、003/004战斗权威与隔离、005道馆恢复、006/009/010/013交易/池/托管/名片、008大厅及012回放；后端为`server/multiplayer/service.py`和`backend_v3.py`。本轮实际修复均在这些文件及测试/构建脚本中，原13处tracked修改逐个摘要保持一致。

脱敏证据与SHA256清单位于`docs/multiplayer-evidence/2026-10-20-review`。执行命令与启动流程分别见主测试报告和setup。自建测试进程/服务均结束，私密测试数据库和独立存档只保留在temp供本机复核。人工菜单、跨机/物理断网、平台设备及素材/原生warning限制仍按上文保持未验收，不宣称整份需求发布完成。

已知原生warning：Indoor.PNG为256×35968，超过pixman16 dirty-region范围。Game89568仅加载这一Bitmap（无游戏/联机/网络代码）也打印相同`Invalid rectangle`且exit0。此项是既有超高tileset渲染风险，未通过替换运行时或关闭GC隐藏。常量重复定义和缺Arial提示同样保留。截图检查中某些未安装的Boss融合素材显示问号安全占位；未使用不安全的原生下载补素材，不能将其写成所有立绘完整。

人工逐菜单输入、两台Windows局域网、公网、Android/macOS/Linux混合设备均未验收。当前协议无OS白名单不等于这些平台已经受支持；APK缺联机代码/manifest、Android无网络权限和生产adapter等阻断详见跨平台核实文档。当前仍是开发验证版本，不宣称不存在其他缺陷。
