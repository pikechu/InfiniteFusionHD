# 好友休闲交换：字段保留与故障恢复

日期：2026-10-16。实现：`Data/Scripts/054_Multiplayer/006_Trade.rb`。

本功能的来源标签固定为 `local_casual`，接收的是本地存档个体，不是服务器托管资产。原有本地导入、备份和主动回滚允许复制精灵；个体的 `personalID`、`veryunique` 或服务器交易流水均不能证明来源可信，也不能消除复制。

## 网络格式和字段表

报价结构固定为 `{version: 1, pokemon: <v1 快照>, preserved: <以下全部字段>}`。字段由双方客户端和服务端校验。客户端在报价前以及确认对方报价前实际构造独立 Pokemon，再次导出并逐字段比较；不能完整保留时拒绝确认。网络不调用旧 `load_json`、`eval` 或 Ruby 对象反序列化。

| 内容 | 保留字段 | 处理方式 |
| --- | --- | --- |
| 物种与身份 | species、form、name、gender、personal_id | 支持当前数据库物种及双融合，form 必须为 0；保持个人 ID |
| 等级与培养 | level、exp、nature、nature_for_stats、iv、iv_maxed、ev、happiness | 精确保留经验，不使用对战的 50 级归一化；等级和经验不一致时拒绝 |
| 双特性 | ability、ability_index、ability2、ability2_index、body_original_ability_index、head_original_ability_index | 读取原始第二特性，防止本地双特性选项关闭时丢失 |
| 招式 | moves 的 id、pp、ppup；first_moves | 保留当前 PP，不恢复 PP；逐项检查招式存在及 PP 上限 |
| 当前状态 | hp、status、status_count、pokerus | 保留当前 HP、异常及计数；HP 不得超出重新计算的能力值 |
| 道具与球 | item、poke_ball | 必须存在于双方同一数据库；变身绑定道具沿用首版禁用清单 |
| 训练师与获得历史 | owner 的 id/name/gender/language；obtain_method、obtain_map、obtain_text、obtain_level、hatched_map、time_received、time_egg_hatched、time_form_set | 精确保留；不是把收到的个体重建为自己捕获 |
| 融合培养记录 | exp_when_fused_head、exp_when_fused_body、exp_gained_since_fused、head_gender、head_nickname | 保留原始分量经验及支持的头部资料；不传递另一个嵌套 Pokemon |
| 闪光外观 | shiny；appearance 中闪光开关、色相、RGB、KRS 九通道、头部/身体参数及 PIF 参数；glitter | 使用首版受限外观格式，不携带本地文件路径 |
| 立绘与体型 | spriteform_head、spriteform_body、sprite_scale、size_category、sprite_asset、old_sprite_asset | 标准立绘路径转换为 base / fusion 受限素材标识，验证物种组成及本地素材已安装；保留大小和体型类别 |
| 装饰与收藏 | ribbons、markings、cool、beauty、cute、smart、tough、sheen | 缎带检查本地注册表，全部保留 |
| 其他原始个体资料 | veryunique、imported、kuray_no_evo、force_disobey、type1kuray、type2kuray、hat_x、hat_y | 保留支持的标记；`veryunique` 只作为本地标记，不作为可信唯一资产 ID |

`preserved` 的每个白名单键都必须存在，允许为空的字段仍以 JSON null 明确表示。范围和枚举以 `TradeCodec::INTEGER_FIELDS`、`OPTIONAL_INTEGER_FIELDS`、`SPECIAL_FIELDS` 及 `validate` 为准。未知额外字段被拒绝。

## 确认前阻止的个体

蛋、暗影精灵、特殊或强制形态、存储着另一个融合伙伴的精灵、携带邮件、饰帽、任意自定义立绘文件、激活的自定义属性覆盖均明确阻止。未知且有实际值的个体扩展实例变量也阻止，避免模组字段被静默丢弃。网络交换依赖相同构建数据与规则校验；未适配的 Mods 不能交换。

受支持的素材变体和自定义闪光颜色正常保留。实际游戏创建普通精灵会自动选择 `Graphics/BaseSprites/1a.png` 等标准素材；这类路径会转换为 `base:1a`，融合素材转换为 `fusion:4.1a`，不把路径作为网络输入。接收端仅能还原到代码指定的标准目录，缺少该素材则在确认前阻止。任意其他自定义 PNG 路径不属于支持范围，用户须先移除该外观再报价。交换界面显示双方完整报价及保留资料，服务端报价变更清除双方确认。

## 本地事务与恢复

1. 报价前持久保存 profile journal，包含服务器、联机身份、原存档绝对路径、存档绑定 ID、交换码和报价 ID。
2. 把原 Pokemon 原对象从队伍或电脑移入该存档的隐藏 escrow，使用完整 `SaveData.compile_save_hash` 写同目录临时文件，flush/fsync 后同卷 `File.rename` 替换存档。报价前必须成功。原个体继续保存在存档中，但普通单机队伍/电脑无法使用它；至少保留一只可战斗精灵。
3. 完成持久化后才上传固定 JSON 报价。服务器保存报价版本和内容 hash；双方确认须携带当前版本和两份 hash。相同 request_id 沿用通用操作恢复机制。
4. 更换报价先锁定新个体，旧个体仍保留在 escrow。查询确认替换成功后，原子释放旧个体。若服务端恰好提交旧报价，则按提交结果替换旧个体并退还未成交的新个体，避免竞态时丢失或解锁已成交报价。
5. 服务器双确认在同一数据库事务中生成唯一 transaction_id 和双方不可变领取凭据。客户端超时先查询，不凭响应缺失判断失败。
6. 客户端确认自己 escrow 的内容与服务端报价一致，完整导入收到的个体，在一次完整原子存档中移除成交原个体、写入收到的个体、清除 escrow 并写入 transaction_id 应用标记。成功后才 ack。
7. 保存失败时回滚本次内存变更，原持久 escrow 不变；服务端仍保留待领取凭据。保存成功但 ack 响应丢失时，重启后由存档内应用标记识别，不再次生成个体，只重发 ack。
8. 取消或过期只在查询服务器确认尚未提交后释放原个体，并安全保存。若队伍与电脑已满，保留 escrow 和 journal，提示腾出位置后恢复；不丢弃原个体。

当前普通 `Game.save` 由 MultiSaves 覆盖，并直接截断目标文件；交易使用独立 `TradeSave`。它仍保存已有完整 SaveData 注册字段，包括 `player` / `kuray_player` 和 `storage_system` / `kuray_storage_system`，没有用只改内存的方式冒充保存完成。

客户端支持存档 escrow 重建丢失的 profile journal。存档已应用而 ack 尚未发送时，也能从已保存的 transaction_id 应用标记和服务器未 ack 状态恢复 journal；不再次插入精灵。只有 journal、尚未完成首次原子存档时，先查服务端不存在自己的报价，再清除该准备记录。不能从网络报价自动复制原精灵补充缺失 escrow。更换存档槽、存档绑定不一致或恢复另一身份时阻止应用。未完成交换会阻止服务器和身份切换；删除 profile 的 journal 仍不能绕过存档 escrow 检查。

## 使用和验证边界

进入联机菜单的好友休闲交换入口，选择创建或输入交换码，双方报价、查看报价、确认并刷新恢复领取。返回菜单保留待处理记录；下次进入优先恢复。服务不可达时原个体继续锁定且单机剩余队伍可用，连接恢复后处理原交易。

事务自动测试：`ruby --disable-gems tests/multiplayer/trade_test.rb`。真实游戏数据与 Windows 原子覆盖测试：在隔离游戏 harness 初始化后调用 `KIFMultiplayerTradeGameTest.run(log)`。实际双游戏进程和跨机器验收结果以测试报告为准；模拟事务测试不能替代游戏验收。

本模块本轮独立执行结果：本地事务故障测试 88 项通过，证据 `temp/multiplayer/trade-unit/run-61132-1792144493/trade-test.log`；真实 Game.exe / Ruby 3.1.3 数据与文件系统测试 63 项通过，证据 `temp/multiplayer/trade-native-20261016-1908/saves/trade-native.log`。测试过程中先发现并修复标准素材被当成任意自定义路径拒绝的问题。原子覆盖在实际 Windows 游戏运行时成功，完整原始存档与模组存档字段均经重新读取确认。

最终整合双进程验收已实际通过：`temp/multiplayer/v2-final-20261016-214516.evidence.json`，构建 `1966bc2706370baea420e3a605a75c93c6ad61c75cef87aed1ce82447e4b5871`，默认 `Game.exe` 两个独立身份 / 存档（PID 51028、76440）使用正式 `core_socket` 传输，均自然退出码 0。双方完成同一交易 `263A31BD`，逐字段比对收到个体、重复领取不复制、真实原子存档重新读取和唯一应用标记持久化全部通过。日志位于两个 `v2-final-20261016-214516-host/guest/saves/feature-smoke.log`。这属于真实游戏运行时自动输入验证；人工菜单及跨机器验证仍分别保留未验证状态。
