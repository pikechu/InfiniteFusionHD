# 联机功能代码审查记录

2026-10-20新增全面CR、直接修复与复测，见 `multiplayer-code-review-2026-10-20.zh-CN.md`。下文保留10月16日历史记录；当时“无待修问题”不覆盖后续复审发现的问题。跨平台支持结论见 `multiplayer-cross-platform.zh-CN.md`。

日期：2026-10-16。范围：当前项目第一至第三版及已新增的独立扩展。本文记录发现、修复、验证证据和未关闭的验收边界；阶段范围与最终启动方式以四份主交付文档为准。

## 当前审查结论

交易、公开资料、身份恢复、副本事务、菜单恢复及原生传输的高优先问题已修复并复测。最终截图审查后的两个回放P2也已修复，默认Game完整场景105/105、三进程exit0通过；当前CR未发现待修P1/P2。人工与跨机仍未验收，不能标记整份需求全部发布通过。

旧HTTPLite原生绑定的崩溃已独立定位，由015安全Socket替换，并通过实际默认Game压力和完整路线/三方回放/服务重启/自然exit0验证，阻断已关闭；未用兼容运行时或改变GC替代修复。

## 已发现并修复的问题

| 优先级 | 问题及触发条件 | 修复与复核 |
| --- | --- | --- |
| P1 | 外观字段只按宽泛 JSON 类型检查，`shinyKRS=true` 等值可能进入绘图路径 | 客户端和服务端按字段固定类型、九通道 KRS 和范围校验；真实 Pokemon 编解码、恶意输入与名片公开投影测试覆盖 |
| P1 | 恢复另一账号时可能保留旧账号 pending，并在新身份下重放旧 mutation | journal 保存身份；重放前检查 owner；恢复码请求携带服务端先行验证的 expected identity；多个绑定 owner 冲突时拒绝 |
| P2 | 凭据丢失但存档仍有 escrow 时，空身份或误建的新身份阻止恢复原账号 | 从同服务器的可信 escrow / journal 推导原身份；允许恢复明确绑定原 owner，而非仅比较当前误建身份 |
| P2 | 新 profile 默认服务器错误时，guard 连切回原服务器也禁止 | 仅允许返回所有待处理状态共同绑定的唯一原服务器；任意其他 URL、跨服务器冲突 pending 仍拒绝；覆盖显式设置和环境变量入口 |
| P1 | 回放 download 使用 POST，被当成业务 mutation；服务端不缓存该只读操作，解析超限后可能永久 pending | 标记已知只读 POST：保留协议 request_id，不写业务 journal；安全清除旧版 download journal，不丢弃或重放其他交易 pending |
| P2 | 房间暂时断线后，下一次成功响应内容未变，仍一直显示“连接暂时中断” | 成功重连时清除旧 heading 缓存；功能桩验证失败→相同 room 成功时提示恢复 |
| P2 | 道馆 challenge 创建已提交但响应丢失，未生成 gym_session，恢复后原挑战被遗留 | 接纳同身份已恢复的 challenge 创建响应，先持久 remember，再消费恢复记录；未完成本地战斗按异常结束恢复，不新造胜利 |
| P1 | 直接截断普通存档，或只改内存，就可能在交换中断后丢失原个体或重复领取 | 独立完整 SaveData 临时文件、flush/fsync、同卷原子替换；存档内 escrow 和 transaction_id 应用标记；落盘后才 ack；写盘失败回滚内存 |
| P1 | 更换报价前先释放旧原个体，可能与服务器提交旧报价竞态 | 新旧报价在服务器裁定前同时安全锁定；按实际提交的 offer_id / 快照释放未成交个体，或只退还被替换报价 |
| P2 | 收据未绑定领取人和已查看的对方报价 | 本地好友交换验证 owner、transaction、来源、双方 hash 和完整收到快照；托管交换额外绑定服务器 asset ID；不一致时拒绝应用 |
| P2 | 普通精灵自动选择的标准立绘被误当任意自定义文件而全部禁用 | 标准目录映射为受限 base / fusion 素材 ID；验证物种组成与本地素材存在；任意路径仍拒绝，不能静默换外观 |
| P2 | 本地更新可以覆盖托管展示，丢失 asset_id / source 和转让下架关系 | 服务端拒绝覆盖托管展示；名片管理仅提供查看、下架，客户端创建更新草稿也先拒绝 |
| P1 | 副本胜利已提交后、advance 前崩溃，储备精灵 HP / PP / 异常 / 携带物丢失 | 同一次权威 resolve 持久完整六只 team_states 与最终结果；正常 advance 可不传状态而读取已提交 authority；显式提交必须一致 |
| P1 | 副本节点结束后可普通 room/start；下一节点启动覆盖 room.battle_id，出现同房间两场 active battle | active route 锁定普通房间变更；内部 route 启动使用不可由 HTTP 指定的 Python 参数；节点启动再次检查 room 状态及所有同房间 active battle |
| P2 | 初始化阶段合法投降没有 engine frame，advance 因缺完整状态而卡在 battle | 正常败北直接终止为 failed；只有需要携带状态继续前进的胜利必须提供 durable authority；不消耗异常重试 |
| P2 | 任意一人 abandon 就结束路线，与双方确认要求不符 | 原双方弃权投票，重复单人请求不加票，只有双方同意才结束；继续节点时清票 |
| P2 | 已到期的托管资产锁必须先访问旧会话才释放 | 锁资产及读取收藏时先按服务端时间检查原 trade / pool 引用过期，再判断当前锁；不依赖用户先打开旧页面 |

副本异常恢复只允许使用节点开战前快照重试一次，第二次不可恢复中断结束；正常战败不走重试。24 小时失效、任意参赛者不能并行加入另一条活跃路线、途中 Boss 不发节点纪念奖、最终按玩家与副本编号领取一次，均已做独立复核。

## 默认原生传输崩溃：尚待最终关闭

默认 Ruby 3.1.3 运行时发生过客机中途静默退出，以及完成四战后进入后续场景时的原生 GC 崩溃。不能据此把错误归咎于界面、剧情数据或仅认为是测试控制器异常。

后续最小探针已移除 RPG 战斗、Sprite、014 客机呈现和 Thread.kill，仍能在旧 HTTP 原生调用与 GC 并发时复现：

- `temp/multiplayer/native-http-gvl-pure/stderr.log` 包含 `[BUG] object allocation during garbage collection phase`，Ruby 3.1.3。
- 参考原生源码 `temp/runtime-research/warmwinter/binding/http-binding.cpp` 的 `drop_gvl_guard(httpGetInternal, ...)` 内部调用 `formResponse`，后者使用 `rb_hash_new` 等 Ruby 对象 API；这与未持有 GVL 时分配 Ruby 对象的风险一致。
- 相同压力下，Socket 探针完成 200 个 GET、1970 次 GC sweep：`temp/multiplayer/native-socket-gvl-pure/saves/http-gvl-probe.log`。

新路径由 `015_Transport.rb` 实现，HTTP 字节收发使用核心 Socket / IO，解析和 Ruby 对象构造留在正常 GVL 路径；不以全局关闭 GC、减少测试次数或关闭客机动画掩盖问题。正式路径已通过默认Game8场261请求及完整105项验收；最终摘要与进程码见末尾检查点。

### 兼容程序对照，不能替代默认程序

使用项目已有 `Game-compatibility.exe`，未替换根目录程序、未改变全局 GC：

1. `dungeon-replay-20261016-210134.evidence.json`：同一冻结 c67 构建，实际 Ruby 3.0.0、platform 后端，四场路线战斗、三进程回放、第五场胜后服务重启恢复，合计 102 项功能断言通过。旧 runner 未保存各进程退出码，只能作为这一轮兼容程序功能对照。
2. `dungeon-replay-20261016-211503-p18789-990e302f.partial-evidence.json`：测试 runId 加长后超过 profile 的 48 字符上限，启动失败；已修为短前缀，属于测试 harness 回归。
3. `dungeon-replay-20261016-211745-p18789-1147a3b9.partial-evidence.json`：所有 102 项功能断言与三角色 finished 齐备，但 runner 获取到 `ExitCode=null`，严格验收未通过。此项不是已观测到的非零原生退出码，也不能写成严格整轮通过。

ExitCode 采集已用自建最小进程确认并修复：`Get-Process` 后不保留原生 Handle，进程退出后可能对 exit 0、exit 7 都返回 null；在进程存活时立即访问 `.Handle`，两者分别正确返回 0、7。runner 现保留句柄，等待真实退出，并明确拒绝 null 与非零值。根代理最后默认版运行应使用该修正版 runner。

## 独立验证证据

| 范围 | 实际结果 | 证据 |
| --- | --- | --- |
| 本地交换事务与故障 | 88 项单元 / 文件故障测试通过 | `tests/multiplayer/trade_test.rb`；`temp/multiplayer/trade-unit/run-61132-1792144493/trade-test.log` |
| 真实 Pokemon 完整字段与 Windows 原子存档 | 真实 Game.exe / Ruby 3.1.3，63 项通过 | `tests/multiplayer/trade_game_test.rb`；`temp/multiplayer/trade-native-20261016-1908/saves/trade-native.log` |
| 在线池 / 托管收藏客户端 | 26 / 27 项通过 | `tests/multiplayer/pool_test.rb`、`collections_test.rb` |
| 在线池 / 托管交换真实闭环 | 两个 Game.exe、两身份、真实 HTTP 和独立 SQLite，30 项通过；5 投递全部领取、2 个资产 / 2 位所有者、0 个遗留锁 | `temp/multiplayer/pool-live-evidence-20261016-181857.json` |
| 实际 Game 进程重启恢复 | 客机持久保存后 ack 前退出；同 profile 用不同 PID 读原档恢复，10 项通过，唯一 transaction 为 1 | `temp/multiplayer/pool-restart-evidence-20261016-182449.json` |
| 名片、多展示、草稿 | 31 项客户端测试；一真实游戏进程、两 HTTP 身份 13 项；最终头像和中文截图已查看 | `tests/multiplayer/cards_test.rb`；`temp/multiplayer/cards-live-evidence-20261016-1851.json` |
| 身份 / 只读请求 / 房间恢复 / 字体 | 独立回归 43 项通过 | `tests/multiplayer/identity_recovery_test.rb`；`temp/multiplayer/identity-regression/run-49304-1792153589/identity-recovery-test.log` |
| 副本并发与终止修复 | 只读 `Store(':memory:')` 探针确认伪造 node 请求被拒、初始投降 failed、单票不结束、双票 abandoned；初始视觉帧等 guest ack 后才推进 | 审查工具记录；服务端专项回归由服务代理保留 |

上表分别注明测试替身、真实游戏、真实 HTTP 和真实磁盘范围，不能把单元测试相加后冒充同等数量的人工游戏验收。最终 transport 与长场景结果以根代理最后补充为准。

## 必须保留的信任与产品边界

- 本地休闲精灵仍可被备份、导入或主动回滚复制。UUID、personalID、veryunique 或服务流水不提供可信来源；“交易不重复应用”不能写成“已解决本地复制”。
- 服务器托管资产只来自服务器认可目录与授权变更，以权威 owner_id 和资产锁登记归属；本地缓存和本地导出副本不能上传成为托管资产。
- 房主使用现有引擎计算，服务端负责操作锁定、持久化和唯一结果，并不独立验证完整游戏机制。修改客户端的房主可以访问计算所需完整队伍；没有可信排位或严格隐藏信息承诺。
- 道馆战果为休闲客户端上报，只发账号纪念章；合作和副本不产生可交易高价值精灵或主线资源。临时队伍、背包和地图保护须继续保留。
- 回放公开需双方同意；下载每次重新检查发布状态，不允许旧 operation cache 绕过下架。已被他人下载的副本不能远程撤回。
- 本次主要为同机独立身份、独立存档和数据库验证。完整人工菜单操作、跨机器局域网与公网验证未完成；不得将自动化原生场景验证表述为这些项目已通过。
- 未部署公网、未购买服务、未使用真实玩家存档或数据库。测试自建进程由各 runner 持有并清理，数据库、日志和证据保留。

## 最后总体验收

最终第二版同一构建的闭环已补充通过：`temp/multiplayer/v2-final-20261016-214516.evidence.json`，哈希 `1966bc2706370baea420e3a605a75c93c6ad61c75cef87aed1ce82447e4b5871`，正式 `core_socket`；默认 Game.exe 两进程 PID 51028 / 76440 均退出码 0。真实合作 Boss、固定版本 AI 道馆更新 / 下架后离线挑战、好友交换 `263A31BD` 的完整个体、真实重读存档和唯一标记验证通过。上述为修复回放画面前的第二版综合验证；最后截图CR后生成92b6构建并重跑完整长路线/三端回放/服务重启，见下方最终检查点。以下四项均已完成，仍保留人工/LAN/公网待验边界。

1. 最终 `001` / `015` 传输路径只使用安全适配，HTTP / HTTPS 的支持边界和不支持提示明确，旧 HTTPLite 不再被联机线程调用。
2. 固定最后源代码、构建清单与可信目录兼容标识，默认 Game.exe 完成完整长场景、三端回放、服务重启恢复，所有自建游戏进程退出码为 0。
3. 归档完整成功证据，同时保留默认旧适配崩溃、兼容版对照以及测试 harness 修复记录；不能只挑成功日志。
4. 根代理完成最终全套回归与运行说明，并在主进度文档保留人工 / LAN / 公网未验证状态。

## 根复核最终关闭记录

最终505输入hash=`92b6c5b61df113c696ed5ae910f4dfaa92c400f804c6b6c87d3ecc50811c14e0`，目录SHA=`f0d90407412439903b2b8073fb3dd3501348a2e4b465a5d7bc5e8cafe9d9c0fd`。默认Game最新105项及三个进程68832/42204/344的严格exit0已读取原始evidence确认；未干预GC、未更换运行时、未使用原型传输。原生HTTP崩溃阻断关闭。

105通过后的截图复审另外发现并修复：

| 优先级 | 具体问题 | 修复和验收 |
| --- | --- | --- |
| P2 | 回放三/四只大bitmap重叠，名称和HP不可读 | 003独立列等比缩放、局部20号字、名称/HP/状态三行；Board192项、真Game三/四列PNG及最终观众回放目视通过 |
| P2 | 回放只按物种创建Pokemon，已保存的特殊闪光外观未应用 | 先校验公开visuals，再按slot与最终species应用form/gender/shiny/appearance并复制可变参数；原生专项验证闪光和支持颜色字段，原globals不变 |
| P2 | 回放visuals尚未整份预检，坏外观可晚于前帧渲染出现 | 012全帧验证唯一slot/递增seq/权威HP等一致及appearance；格式异常变invalid_replay返回UI；29项及真回放通过 |

最终重跑 `221148-p18782-67b83f6b` 完整105通过，三进程exit0，五战/三端回放/真实服务重启/原磁盘存档保护均通过。根代理再次目视最终三列回放PNG；独立战斗代理的实际640×480四列闪光图也可读。Native fixture曾用固定性别精灵的非法测试性别导致断言失败，已更正合法fixture并重测；硬编码坐标元数据也已移除并重新生成真实观测证据，未改生产数据以绕过断言。

当前代码审查未发现待修P1/P2，不能据此保证不存在其他缺陷。人工逐菜单、跨机器LAN、公网、全部物种/招式/动态形态的验收边界仍在进度文档保留；缺失本地融合素材使用备用图，默认Game不支持HTTPS。安全Socket定向74/原生72、全套服务124及14组Ruby测试、真实游戏结果的具体日志见主报告。
