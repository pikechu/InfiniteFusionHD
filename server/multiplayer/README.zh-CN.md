# 本地联机协调服务（协议 2）

2026-10-21新增账号、云存档、主线地图同步与聊天，完整使用/验证说明见 `../../docs/multiplayer-online-world.zh-CN.md`。新端点使用Bearer身份，其中auth/register、auth/login无需身份；本节POST不使用经济操作日志，上传和聊天分别以upload_id/client_id去重。

| POST路径 | 请求要点 |
| --- | --- |
| `/v1/auth/register`、`/v1/auth/login` | `username,password,protocol:2`，注册可带nickname；返回identity、token、username、expires_at |
| `/v1/auth/logout` | 撤销当前账号会话凭据；游戏退出先关闭云写入会话 |
| `/v1/cloud/open` | `session_id,compatibility`；单账号单写入租约，返回云槽位版本列表 |
| `/v1/cloud/heartbeat`、`/close` | `session_id`；续期或关闭 |
| `/v1/cloud/download` | `session_id,slot`；返回当前槽位save和revision |
| `/v1/cloud/upload` | `session_id,slot,revision,upload_id,save:{format,game_version,payload,sha256}`；版本CAS、幂等提交 |
| `/v1/cloud/chunk` | `session_id,upload_id,index,total,sha256,data`；16KiB分片、返回next_index或最终上传回执 |
| `/v1/world/join` | `session_id,compatibility` |
| `/v1/world/sync` | `session_id,seq,after,position`；position可null隐藏，或含map_id/map_hash/width/height/x/y/direction/character_id/moving；返回world玩家与消息增量 |
| `/v1/world/leave` | `session_id` |
| `/v1/chat/send` | `session_id,client_id,channel:map或world,text`；服务器填入真实发送者、昵称、地图范围 |

云端与账号记录保存在同一SQLite事务体系中；服务器不解释游戏对象、不执行上传数据。重启清空地图在线状态，保留账号、存档及上传回执。云数据应与身份数据库一起私密备份。

第三版和后续独立玩法服务状态机位于 `backend_v3.py`，由同一 `Store` 和 SQLite 写事务协调；客户端实现与原生游戏验收见根 `docs`，不能仅因服务测试通过就宣称游戏验收通过。

## 第三版及独立玩法协议

### 训练师名片与六槽展柜

GET `/v1/cards/me` 查询当前身份名片，GET `/v1/cards/{8位好友码}` 查询公开名片；返回 `card:{id,nickname,friend_code,avatar,show_badges,badges,showcases,showcase_codes,capacity:6}`。初始头像 `POKEMONTRAINER_Red`，徽章默认不公开，展柜默认空。POST `/v1/cards/me {avatar,show_badges,showcases:[展示码最多6]}` 加通用 request_id 保存配置，只能修改当前认证身份。

头像是受信任 TrainerType ID，不能是资源路径。服务附 `catalog-card-avatars-v1.json`，从项目可信 `Data/trainer_types.dat` 导出 140 个合法 ID；源数据 SHA256 为 `45ab5e4509612003afaec1aa7243b4595483643dd171d0096eb57942e4b55413`。客户端再通过本机 GameData 注册表生成素材路径，版本不兼容时阻止显示为任意路径。

`show_badges=true` 时才公开 rewards 表中当前账号真实获得的最近 64 枚 `boss_medal|gym_medal|dungeon_medal`。公开徽章只含 `id,kind,boss_id?/gym_code?/dungeon_id?`，不包含托管 starter 发放、资产 ID、战斗资料或私人领奖时间；这些是休闲纪念记录，不提供可信排名。

名片只能选择自己当前有效的公开展示，最多六个且不可重复。GET `/v1/showcases` 返回当前身份 active owned 展示的既有公开投影，供跨设备恢复多展示管理；不会返回未选择公开的本地快照。更新展示后名片引用最新公开版本，下架后立即过滤。托管展示还逐次核对资产当前所有权，旧所有者即使保留旧引用也不能继续展示已转出的资产。头像、凭据、展示和自愿公开徽章均按服务器身份隔离。

### 安装可信目录

`catalog-rental-v1.json` 由项目真实游戏运行时导出、逐只重新导入与招式实例化验证，固定含 `version:1,compatibility,pokemon:[12只完整快照]`，并附融合组成/类型等元信息与验证来源。每次租借开始、托管初次领取和副本创建都读取已安装文件，不接受客户端上传目录。租借与副本还要求目录 `compatibility` 与客户端完全相同；最终 Ruby 源码构建后必须重新原生导出目录，避免旧 `data_hash`。目录缺失、损坏或不兼容时明确拒绝创建，已有比赛已保存的完整候选不受文件更新影响。

### 随机租借杯

创建普通房间时使用 `mode:"rental_singles"`；两人加入后，房主 POST `/v1/rooms/{code}/draft {}` 开始新比赛。GET 房间返回 `draft:{id,status,pool:[{slot,snapshot}],order,pick_index,picks,remaining,next_owner_id,deadline,presence,reconnect_remaining,disconnected}`。服务保存完整十二只候选并随机排列、随机分配 A/B，顺序固定 A、B、B、A、A、B。每次 POST `/{code}/pick {draft_id,pick_index,slot}` 必须同时匹配比赛编号与当前 0..5 选宠序号，已选槽位不能再次获得。不同 `request_id` 的迟到点击也不能被错误用于同一玩家的下一次选宠。

每次选择限 30 秒，双方正常心跳时超时由服务器选择剩余首个候选；断线暂停并累计扣除额度，耗尽则取消。完成六选自动创建一场真实好友单打 `battle_id`，剩余重连额度带入战斗。租借房间拒绝本地 `/team`、`/ready` 或跳过草稿直接 `/start`；每个完整 draft 只生成一场战斗。再开一杯须开始新 draft，重新冻结候选。客户端只能把候选导入临时战斗队伍，服务不提供候选导出为本地交易或资产的端点。

### 在线奇迹交换池

| 请求 | 字段与结果 |
| --- | --- |
| POST `/v1/pool/deposits` | `deposit_id:"pool_"+32位小写hex,source,compatibility,offer_id`，本地另传完整 TradeCodec `snapshot`，托管另传 `asset_id`；返回 201 `deposit` |
| GET `/v1/pool/deposits` | 当前账号投递与待恢复回执，`deposits` |
| GET `/v1/pool/deposits/{id}` | 仅本人可读取 `deposit` |
| POST `/{id}/withdraw` | 仅未匹配可撤回；匹配已提交时返回 `deposit_matched`，应查询并恢复原回执 |
| POST `/{id}/ack` | `transaction_id`，客户端安全完成领取或原个体释放后确认，重复安全 |

每账号最多一份尚未 ack 的投递，服务只在不同玩家、相同来源区和完全相同兼容版本之间匹配。投递、匹配、撤回和 24 小时过期在同一 SQLite 锁及写事务下裁定唯一去向。状态为 `waiting → matched → completed`，或 `waiting → withdrawn|expired → completed`；`final_status` 保留原结果。`deposit` 带 `id/deposit_id,owner_id,source,status,final_status,offer_id,snapshot,asset_id?,offered_hash,compatibility,transaction_id,receipt,created_at,expires_at,acked`。

本地交换回执含 `kind:"exchange"|"return",owner_id,source,transaction_id,offer_id,offered_snapshot,offered_hash,received_snapshot,received_hash`；未匹配撤回或过期返回原快照，但客户端应解除原 escrow，不能凭网络回执复制第二只。托管回执只含 `received_asset` 与快照 hash，更新本地缓存，不写入主队伍。服务重启保留所有投递、所有权与未领取结果。

### 服务器托管收藏箱

GET `/v1/collections` 返回当前服务器权威拥有的 `assets`：每项含不可变 `id,owner_id,snapshot,source:"server_catalog",catalog_version,catalog_hash,created_at,locked,lock_reference`。POST `/v1/collections/starter {catalog_version:1}` 从已安装可信目录的固定首个模板发放，每个账号终身一次；重复调用返回原资产和真实当前所有者，即使已经交换给别人也不补发。没有本地上传、导入、客户端胜利奖励或主存档缓存回流的资产铸造端点。

POST `/v1/collections/{asset_id}/showcase {}` 仅当前所有者可创建托管来源展示；所有权转让会撤销旧所有者对该资产的公开展示。好友交换沿用 `/v1/trades`，创建必须 `source:"server_managed"`，报价为 `{asset_id,offer_id}`，不能混入本地快照。加入可传 `source`，来源不符在加入前阻止。双方同版本/hash 确认后，在一次事务内交换双方资产所有者、清理锁并保存回执；回执为 `source:"server_managed",received_asset,received_hash,offered_hash`。好友报价与交换池共用权威资产锁，同一资产不能同时用于两笔操作。查询收藏箱或再次操作资产会自动判定旧锁过期，无需先手工打开旧会话。

### 固定合作副本

POST `/v1/dungeons {room_code}` 由房主把已选三只临时队伍的合作房间建立为固定路线；GET `/v1/dungeons` 列个人会话，GET `/{id}` 查询。路线固定三场普通融合战、各自一次休息恢复、最终 Boss。创建时冻结队伍与所有敌人配置，`expires_at=created_at+86400`；旧会话迁移按原创建时间计算，重启或重连不延期。同一参与者不能同时进入其他 active 副本，即使另开房间也不允许。每一场必须双方 POST `/{id}/ready {ready:true}` 才自动生成该节点唯一 `battle_id`。

`battle.runtime_state` 首场为空，后续为 `owner→三只状态`，每项严格含 `hp,totalhp,status,status_count,pp,total_pp,item`。客户端临时导入后应用该状态。合作战斗的 `state.team_states` 可保存同一结构的完整六只队伍，最终 resolve 把它与胜负在同一事务中保存到 battle.state 与 result；好友单打与租借单打禁止此字段。结束后房主 POST `/{id}/advance {battle_id,team_states?}`：省略时从最终权威记录恢复，传入时必须与已提交记录语义相同，没有记录则返回 `post_state_unavailable`，不构造或接受事后猜测的 HP/PP。这样解决已胜结算成功、但客户端发 advance 前崩溃的窗口，包括非活动精灵的状态。

道具状态遵循既有引擎：Trick/Thief 可转移，Harvest/Recycle 可回收原物。服务器仅允许该副本冻结六只参赛精灵与各 Boss 初始携带物种类集合内的 item 或 nil，不把每个个体的道具永久固定为初始物。下节点只应用最终权威 item，不从初始快照补回已消耗物；休息不额外补道具。这属于临时局内状态，不进入主存档，也不提高房主上报结果的可信度。

服务器保存 pre/post-state 与结算记录并一次推进；重复 battle_id 只返回现状态。异常中断或服务重启后只允许整条路线一次恢复到该节点的 pre-state 重试，忽略客户端提供的新状态；第二次异常结束为失败。24 小时到期将未完成路线标为 expired，并异常结束正在进行的节点；GET、领奖请求或单独的 battle 心跳都能触发同一服务时钟判定，过期不能领奖。已正常完成的通关记录不因领取较晚丢失。途中节点禁止普通 Boss 纪念章，最终只从副本 claim 统一领取。失败和放弃不产生通关章。

休息节点各自 POST `/{id}/rest {choice:"heal"}` 恢复自己的 HP/PP/异常，每人一次，保留最终权威携带物。双方完成后进入最终 Boss。通关 POST `/{id}/claim {}` 按玩家加副本编号领取唯一 `dungeon_medal`。POST `/{id}/abandon {}` 记录当前身份的 `abandon_votes`；同一人重复不加票，单票不中止节点，只有原双方都同意才结束并异常中止当前战斗。继续进入新节点时清除旧票，24 小时到期仍自动关闭。所有资源只在临时副本队伍存在，不写主线进度或物品。

active 副本绑定房间后，普通房间 team/ready/start/configure/kick/leave 操作被拒绝，只能通过副本节点操作继续。节点内部启动使用服务进程内部参数，不把可伪造的 request_id 前缀当授权；房间正在 playing 或存在其他 active battle 时禁止覆盖 battle_id。即使是开场初始化阶段已确认投降、尚无全队状态帧，也会按正常失败结束副本；只有已胜节点的恢复要求完整最终权威状态。

### 战斗回放分享

POST `/v1/replays {battle_id}` 只允许该场参与者在已有权威状态记录的战斗结束后创建；同 battle 仅一份回放。GET `/v1/replays` 提供本人相关与公开列表，GET `/{id}` 仅元信息，不提前泄露完整队伍。双方分别 POST `/{id}/consent {consent:true}` 后，创建者才能 POST `/{id}/publish {visibility:"public"|"unlisted"}`。其他玩家通过 POST `/{id}/download {compatibility}` 获取 `replay.data`：双方完整初始队伍、Boss/副本初始状态、所有权威状态帧、已锁定指令、随机结果与最终结算。客户端按已记录状态和事件播放，不依赖再运行一次引擎得到相同结果。

任一参与者可撤销同意或 POST `/{id}/unpublish {}`，此后阻止下载；下载每次重新检查权限，不使用幂等操作缓存绕过下架。客户端版本/data/mod/rules 不同明确拒绝。当前单份回放限制约 1.8 MB，超过时拒绝分享并保留原战斗记录，避免突破游戏 JSON 接收上限；已被别人下载的副本无法撤回。回放不作为奖励或可信战绩来源。

Python 3 标准库 `http.server`、`sqlite3`，无需 pip。该服务用于好友休闲技术验证，由房主的真实 Ruby 战斗引擎结算；服务端不重实现伤害公式，不提供可信竞技防作弊承诺。

第二版已接入合作 Boss、异步玩家配置 AI 道馆和本地精灵休闲交换。SQLite 初始化使用 `CREATE TABLE IF NOT EXISTS` 自动增量添加表，保留原有身份、房间、战斗和展示。运行前关闭旧服务；同一个数据库不能同时启动两个协调服务（启动会把正在进行的真人战斗标记为异常结束）。道馆挑战、版本、战报、交易回执和奖励领取记录在重启后保留。

## 第二版协议与状态

下列 POST 均使用已认证身份和 `request_id`，超时后先查询 `/v1/operations/{request_id}`。版本与规则仍固定协议 1 / `friendly-singles-v1`，玩法由独立 `mode` 区分。

### 合作 Boss

创建 `/v1/rooms` 可增加 `mode:"coop_boss",boss_id:"training-golem",difficulty:"normal"`（或 `hard`）。配置使用已有 `/rooms/{code}/configure` 同名字段，并清除双方准备。Boss 固定为版本 1 的融合种族 `B76H95`，正常/困难强化配置由服务器下发；客户端按配置构建临时队伍及 2v1 战斗，不向主存档写入 Boss。房间成员 `team` 为完整三只队友快照；合作双方都可读取 `battle.initial_teams`。其余选队、准备、开始、指令、结算与播放确认沿用第一版端点。

`state.battlers` 新允许 `owner_id:"boss"`，场上 index 0/2 对应两位玩家、index 1 对应 Boss。招式可提供 `targets` 合法目标数组，服务端选招必须属于其中；Ruby 引擎再检查一次。只有服务器可补入 `{action:"ai"}`，玩家不能冒充 AI 提交。

非房主断线先暂停并累计扣除重连额度，耗尽后 `ai_controlled_ids` 加入该玩家、补齐未锁定动作并由房主既有 AI 控制，已锁定指令保留。AI 玩家自动确认播放，避免无人在线时锁死。重连标记为 `control_restore_pending_ids`，仅在下一个指令阶段且仍在线时恢复人控；已耗尽额度不会重置。普通操作超时也由引擎 AI 代选，不适用好友对战三次超时判负。房主超时、双离线或服务重启仍异常中断。

`POST /v1/battles/{id}/signal {signal:"support"|"focus"|"switch"}` 保存预设信号，不修改已锁定指令。胜利 `result.coop_outcome:"victory"`、`winner_ids:[双方]`；失败为 `defeat`，异常为 `abnormal`。`POST /v1/battles/{id}/claim {}` 按玩家加战斗编号返回唯一 `boss_medal`，失败和异常不能领取。纪念章是账号记录，不是可交易资产、捕获或主线资源。

### 异步 AI 道馆

| 请求 | 字段与结果 |
| --- | --- |
| POST `/v1/gyms` | `name,description,intro,compatibility,team:[1..6个快照]`，创建并发布版本 1，返回 201 `gym` |
| GET `/v1/gyms` | 已发布目录及自己的关闭道馆，返回 `gyms`；公开阵容只有预览字段 |
| GET `/v1/gyms/{code}` | 名称、介绍、开场、版本、规则、阵容预览；馆主另有完整 `team` |
| POST `/{code}/publish` | 同创建字段，仅馆主可用；生成不可变的新版本 |
| POST `/{code}/close` | 关闭新挑战；已有挑战仍使用固定版本继续 |
| POST `/{code}/favorite` | `favorite:boolean`，账号收藏 |
| POST `/{code}/challenge` | `compatibility,team:[3个快照]`；返回 201 `challenge`，含 `gym_version,team,defender_team,intro,rules` |
| GET `/v1/gym-challenges` | 当前身份挑战记录，`challenges` |
| GET `/v1/gym-challenges/{id}` | 仅该挑战者可读取完整固定快照与战报 |
| POST `/v1/gym-challenges/{id}/result` | `outcome:"win"|"loss"|"abandon"|"abnormal",turns:0..10000,summary`；一旦保存不可更改 |
| POST `/v1/gym-challenges/{id}/claim` | 胜利后按玩家加道馆编号领取一次 `gym_medal`；更新阵容版本不重发 |

此处战果明确为 `client_reported_casual`。馆主离线不影响已发布队伍，挑战不需要同步在线房间；服务不会把客户端上报胜利用于可信竞技或高价值发放。客户端本地完成草稿、预览与确认后才调用发布。

### 本地精灵休闲交换

本节本地休闲模式报价为 `source:"local_casual"`；服务器只协调原子交易及回执，不认证本地精灵来源，不声称防止备份回滚复制。`server_managed` 是上文另行说明的服务器托管模式，报价与所有权处理独立。

`POST /v1/trades {compatibility,source?}` 创建并返回 201 `trade`；`/{code}/join {compatibility}` 加入。每个账号最多一笔尚未确认自己领取的会话；自己已 ack 的旧交易不受对方离线影响。`GET /v1/trades` 返回本账号可恢复会话，`GET /v1/trades/{code}` 仅成员可读取完整报价和自己的回执。

`POST /{code}/offer {offer_id,snapshot}` 的 `snapshot` 固定为 `{version:1,pokemon:战斗快照v1,preserved:{完整保留字段}}`。报价 hash 为 UTF-8、对象键递归排序、无额外空白 JSON 的 SHA256；客户端应先验证完整收到的快照并比较本地记录，再使用服务返回的 hash 确认。任何更换报价都增加 `revision` 并清空双方确认。

`POST /{code}/confirm {revision,offer_hashes:{双方玩家ID:各自hash}}` 要求双方看到同一固定报价版本。双方确认后，在一个 SQLite 写事务内生成唯一 `transaction_id` 和双方不可变回执。`trade.receipt` 只包含当前用户的 `received_snapshot,received_hash,offered_hash,transaction_id,source,committed_at`。客户端以交易编号完成本地原子存档后，调用 `POST /{code}/ack {transaction_id}`；重复 ack 不重复提交。双方 ack 后会话为 `completed`。

提交前 `POST /{code}/cancel {}` 可取消；提交后禁止单方撤销或改价，必须恢复原回执。未提交会话按服务时钟 24 小时过期，保留原报价供客户端解除锁定。状态为 `waiting → offering → committed → completed`，提交前可转 `cancelled|expired`。同请求 ID 的确认重试返回原结果，不生成第二笔交易。

交换保留表除原 `pokemon` 全字段外：`exp,hp,status,status_count,poke_ball,first_moves,ribbons,cool,beauty,cute,smart,tough,sheen,pokerus,markings,obtain_method,obtain_map,hatched_map,obtain_level,obtain_text,time_form_set,time_received,time_egg_hatched,exp_when_fused_head,exp_when_fused_body,exp_gained_since_fused,body_original_ability_index,head_original_ability_index,veryunique,glitter,force_disobey,imported,type1kuray,type2kuray,kuray_no_evo,hat_x,hat_y,sprite_asset,old_sprite_asset`，全部键必传，允许空值的字段由 validator 明确限定。sprite_asset/old_sprite_asset 仅允许 default、base:编号或 fusion:头.身 的白名单素材标识，客户端映射到固定官方素材目录并在确认前检查物种和文件；不接收文件路径。客户端额外拒绝无法完整保留的蛋、暗黑、邮件、内嵌融合对象、特殊形态、任意自定义文件与装饰帽；服务不接受额外 JSON 字段，客户端必须在确认前检查物种、道具、配招和个体字段兼容。

身份恢复可携带 `expected_identity_id`；存在待处理本地交易或请求时，客户端发送当前身份 ID，恢复码属于其他身份会在轮换 token 前返回 `identity_switch_pending`。

第二版自动回归：

```powershell
& 'D:\Users\meikun.zhang\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' -m unittest discover -s server/multiplayer -p 'test_*.py' -v
```

在项目根目录运行：

```powershell
& .\server\multiplayer\start-local.ps1
# 其他端口/独立测试数据库
& .\server\multiplayer\start-local.ps1 -Port 8766 -Database .\server\multiplayer\data\second-test.sqlite3
# 安装了普通 Python 3 的电脑也可指定
& .\server\multiplayer\start-local.ps1 -PythonExecutable 'C:\Python312\python.exe'
```

默认仅监听 `127.0.0.1:8765`，独立测试库 `server/multiplayer/data/multiplayer-test.sqlite3` 自动初始化。局域网手动用 `-BindAddress 0.0.0.0`，另一台电脑填服务主机的局域网 IP。脚本不会更改防火墙或自动部署公网。公开部署需另外配置 HTTPS、反向代理和运维措施，当前未验证。

游戏端 `015_Transport.rb` 使用 core Socket 异步传输，统一限制连接/读写 deadline、HTTP 头和 JSON body；不会并发调用已确认不安全的原生 HTTPLite。当前捆绑 Game.exe/兼容版均没有 OpenSSL，HTTPS 在发送与写入操作 journal 前返回 `unsupported_https`，不会降级 HTTP。独立 Ruby 有 OpenSSL 时已测试证书链及 hostname 校验，但这不代表捆绑游戏支持公网 TLS；公网验收仍须先提供可验证的游戏端 TLS 适配器。当前游戏实际验收使用显式配置的本机 HTTP。

独立初始化（服务必须先停止）：

```powershell
& .\server\multiplayer\init-db.ps1
```

SQLite 数据包括身份凭据哈希、房间 JSON、冻结队伍与逐阶段结果 JSON、按身份隔离的幂等操作表、展示版本。使用 WAL 与 `synchronous=NORMAL`；服务进程重启保留已提交事务。突然掉电时最后的事务仍有丢失风险，不用于高价值资产。备份前停止服务，然后复制数据库；运行时不能只复制主文件并丢弃 WAL。不要对真实玩家存档或其他项目数据库运行初始化。

## 通用协议

所有输入仅允许有限 JSON；POST 必须 `Content-Type: application/json`，最大 512 KiB。认证请求使用 `Authorization: Bearer TOKEN`。响应为 `{ok:true,room|battle|showcase:...}`，错误为 `{ok:false,error:{code,message,details?}}`。日志不输出请求正文、token 或恢复码。

除身份创建/恢复以外，所有 POST 都必须有 8 至 100 位 `request_id`（字母、数字、下划线、短横线；客户端生成 128 位随机值）。同身份同 ID 同请求返回原提交结果，不同内容返回 `request_id_conflict`。超时先 GET `/v1/operations/REQUEST_ID`：成功返回 `{status:"completed",http_status,response}`；`operation_not_found` 后只能重发原 ID 和原内容。校验失败的操作不入成功流水。

| 方法与路径 | 请求要点 | 响应要点 |
| --- | --- | --- |
| GET `/v1/health` | 无认证 | `protocol:1,rules_version:"friendly-singles-v1",server_time` |
| POST `/v1/identities` | `nickname,protocol:1` | `identity:{id,nickname,friend_code},token,recovery_code` |
| GET `/v1/identity` | 认证 | 当前身份公开字段 |
| POST `/v1/identities/recover` | `recovery_code` | 原身份、新 token；旧 token 失效 |
| POST `/v1/rooms` | `request_id,name,compatibility` | 创建房间 |
| POST `/v1/rooms/CODE/join` | `request_id,compatibility` | 加入房间；最多两人 |
| GET `/v1/rooms/CODE` | 成员身份 | 房间公开字段；无完整队伍或选中下标 |
| POST `.../team` | `request_id,candidates:[3..6个快照],selected:[三个不同下标]` | 清除双方准备 |
| POST `.../ready` | `request_id,ready:boolean` | 准备状态 |
| POST `.../configure` | 房主；`request_id,name?,rules_version?` | 清除双方准备 |
| POST `.../kick` | 房主；`request_id,member_id` | 仅等待阶段可移除另一成员 |
| POST `.../leave` | `request_id` | 房主关闭房间，客人退出；战斗中阻止 |
| POST `.../start` | 房主；`request_id` | `battle_id,room`；战斗中重复 start 返回同 ID |
| POST `/v1/showcases` | `request_id,snapshot,public_fields,code?` | 发布或更新现有分享码，产生新版本 |
| GET `/v1/showcases/CODE` | 认证 | 按公开字段裁剪后的快照 |
| POST `.../unpublish` | 本人；`request_id` | 下架；后续访问 404 |

`compatibility` 必须恰含 `protocol:1,game_version,data_hash,mods_hash,rules_version`，后四项为字符串；固定 `rules_version="friendly-singles-v1"`。加入时五项逐项比较，返回不一致字段。物种、招式和效果实际存在性由带匹配数据哈希的 Ruby 客户端再次验证；协调服务本身只校验符号格式、类型、范围和版本。

房间状态：`waiting/configuring/ready/playing/settled/closed`。结算后双方重新准备，再 `/start` 产生新的战斗编号。没有额外 `/rematch` 空接口。

展示默认公开 `version,species,level,form,moves,ability,ability2,shiny,appearance`；`public_fields` 只可包含 `name,owner,iv,ev`。隐藏 `name` 同时删除 `appearance.head_nickname`。不会包含个体 ID、选队顺序、携带道具等未约定公开字段。展示只保存 JSON 快照，没有领取或导入接口。

## 战斗阶段

可选的 `state.visuals` 为原生客机呈现提供纯 JSON 事件：`{version:1,seq,complete,battlers,events}`，序号每次 resolve 严格增加，`complete` 表示录制是否完整，事件最多 128，公开登场精灵最多 4。公开视觉精灵只有 `slot,species,level,name,hp,totalhp,status,party_index,form,gender,shiny,appearance`；appearance 复用严格颜色/范围白名单，不接受路径、后排资料、未知个体属性或 Ruby 对象。所有槽位必须属于同帧公共战斗 state。

事件仅支持 `move{move_id,user,targets,hit}`、`hp{slot,from,to,totalhp}`、`replace{pokemon:公开视觉精灵}`、`recall{slot}`、`faint{slot}`，均另含 kind。招式动画只记录已经执行的动作，只有房主在指令锁定后发布 resolve 时才能传入，未锁定前不公开暗选信息。客机只播放动画、更新权威画面，不重新计算伤害或消耗主队伍。初始 resolve 带 visuals 时先停在 `turn:0,phase:playback,deadline:null`，客机完成入场并 ack 后才进入第一指令阶段，避免动画长短占用选招时间；无 visuals 保持原客户端行为。终局 visuals 保留在 finished snapshot，客机可以正常 GET 心跳并完成动画，不再提交终局 ack。

| 方法与路径 | 请求/返回 |
| --- | --- |
| GET `/v1/battles/ID` | 参战者；返回 `battle`，同时作为心跳 |
| POST `.../resolve` | 房主；`request_id,turn,state,digest,random_tape,decision` |
| POST `.../commands` | 自己；`request_id,turn,command` |
| POST `.../withdraw` | 自己；`request_id,turn`，锁定前撤回 |
| POST `.../ack` | `request_id,turn,digest`，确认展示完本阶段 |
| POST `.../abort` | 任一参战者；`request_id,reason`，仅异常结束、无胜者 |

`players` 固定 `[host_id,guest_id]`，不依赖 JSON 键排序。房主获得 `initial_teams:{player_id:[3只完整快照]}`；客人仅获得 `team` 自己的三只快照。完整对手配招对房主并不保密。`commands` 仅在锁定后提供给房主，其他状态只给 `submitted:[player_id]`。客人得到活动精灵的公开状态、战报和自己的合法动作列表，不运行第二套引擎。

创建战斗为 `turn:0,phase:"initializing"`。房主 `/resolve turn:0` 发布首个选项，服务进入 `turn:1,phase:"commands"`。双方有效动作到齐一次性锁定，房主取得命令，执行原有引擎，到下一个输入边界发布 `/resolve`；非终局为 `playback`，客人 `/ack` 后进入下一个递增阶段。`turn` 是输入边界编号，强制补位也占一个编号，不等于游戏回合数。`state.turn_count` 才是引擎回合计数。`phase_owner_ids` 中不需输入者自动提交 `wait`。

动作 `command` 为以下一种：

```json
{"action":"move","move_index":0,"target":-1}
{"action":"switch","party_index":1}
{"action":"forced"}
{"action":"wait"}
{"action":"surrender"}
```

`state` 结构为 `kind:"command"|"switch",turn_count,battlers,weather,terrain,events,actions,phase_owner_ids`。`battlers` 字段限定 `owner_id,index,party_index,species,hp,totalhp,status,name,level`。`actions` 按玩家 ID 存放 `moves:[{index,id,name,pp,total_pp,target?}],switches:[{party_index,species,hp,totalhp,name?}],can_switch,forced`；客人响应裁剪为仅自己的项。`events` 是文本数组，不是可执行脚本。`random_tape:[{limit,value}]` 只供房主诊断，客人响应删除此字段，不声称记录所有 `rand` 或可重放。`digest` 是房主状态 JSON 的 SHA256，客人仅原样 ACK，不构成独立计算证明。

操作时间 60 秒、补位 30 秒；播放阶段无操作倒计时。缺少输入时按照已公布的合法动作列表确定性选第一项；连续三次需要输入的阶段超时判负。8 秒没有战斗心跳视为失联，每人每场累计 60 秒保留额度，已提交指令保留，失联期间暂停操作期限。房主额度耗尽异常结束；客人耗尽判负；双方耗尽异常结束。恢复不会重置额度。

结算 `result:{id,winner_id,reason,turns,phases,abnormal,rewards:[],settled_at}` 唯一，不发任何主线奖励。`turns` 是引擎回合数，`phases` 是输入边界数量。`decision` 使用现有引擎枚举 0 至 5（0 继续、1 房主胜、2 房主负，其他无胜者）。同请求 ID 重复结算返回原结果；结束后新请求不能改写结果。

服务启动发现未完成战斗，一律 `abnormal/service_restart`。当前不能从 JSON 重建 Ruby 引擎调用栈；房主进程退出后不允许迁移权威或补写胜利。菜单中恢复到旧战斗时须明确异常结束；合作副本可按上文规则从本节点 pre-state 唯一重试一次。交换回执、奖励、Boss、道馆、租借、大厅、收藏箱与回放的持久协议见上文，其状态不能用旧战斗引擎栈是否可恢复来推断。

## 测试

```powershell
& 'D:\Users\meikun.zhang\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' -m unittest discover -s server/multiplayer -p 'test_*.py' -v
```

单测与真实 localhost HTTP 复用同一组业务场景，使用 `data/tests` 下唯一测试数据库。测试不打开游戏存档。服务接口测试不替代双游戏进程、局域网或公网验收；结果以项目的测试报告为准。
