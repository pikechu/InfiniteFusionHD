# IF 上游改动移植清单与风险评估

文档保存日期：2026-10-22（Asia/Shanghai）  
状态：U01 已在本地完成文案合并、更新源修正及隔离验证，尚未提交/发布；其他项待实施。验证范围见 [图鉴合并记录](pokedex-merge.zh-CN.md)。  
目标仓库：pikechu/InfiniteFusionHD

远程 issue（2026-10-22）：[#3 上游移植计划：图鉴数据、遗漏逻辑修复与图集系统评估](https://github.com/pikechu/InfiniteFusionHD/issues/3)，已创建，状态为 open。issue 正文包含完整评估与验收清单；本文档尚未作为 Git 提交推送。

## 评估范围与基线

- IF：[infinitefusion/infinitefusion-e18 @ 064a0966](https://github.com/infinitefusion/infinitefusion-e18/tree/064a09664aca2e83e28dff436fa37fff72236481)，该提交日期为 2025-01-22。本评估针对这个仓库快照，不代表 IF 最新发行包。
- KIF：[kurayamiblackheart/kurayshinyrevamp release @ 7ed0deda](https://github.com/kurayamiblackheart/kurayshinyrevamp/tree/7ed0dedafd46e7476e358d8c243687b77185c091)。
- 原始评估：2026-10-21，本地 HEAD 为 `7132cef52053eb5b527cf5a407f3b40688f9314e`，并包含当时工作区修改。已比对 160 个不同脚本和 10 个上游独有脚本。
- 文档保存时本地 HEAD：`fb712846a441f27475c045cf0294bd793d8a1ef5`；复核确认 HP 形态回调、TrainerModern 禁止随机化检查，以及咖啡/火箭队制服处理仍存在下述缺口。其他项实施前按实际目标分支再次核对。

建议按功能逐项移植。文件不同不等于漏同步，也不建议用 IF 脚本或资源目录整体覆盖 KIF。

## 候选改动、工作量与风险

下表为一名熟悉本项目的开发者的工程估算，包含针对性回归。不同项可能共用测试准备，不能简单相加作为发布时间承诺；完整跨机器、跨平台发布验收另行安排。

| 编号 | 优先级 | 候选改动 | 已确认的差异与收益 | 预计工作量 | 风险与实施边界 |
| --- | --- | --- | --- | --- | --- |
| U01 | 高 | 新增图鉴文本（本地已完成） | 保留 KIF 8,411 条，追加 IF 6,594 条有效且不重复的文本，共 15,005 条；同时修正更新源并采用只增合并 | 原估 0.5–1 天 | 已通过隔离验证；不代表新 APK 或完整人工界面验收 |
| U02 | 高 | 火箭队制服与咖啡使用处理 | 编译数据中两者可使用，但本地缺少上游的制服换装和咖啡战内外回复 50 HP 处理 | 0.5–1 天 | 中；检查换装前后状态、取消、菜单返回、道具消耗及相关剧情条件 |
| U03 | 高 | HP 改变时的形态更新回调 | 本地 `Battler#hp=` 缺少 `checkHPRelatedFormChange(value)`，涉及 SHIELDSDOWN 对应的小陨星融合形态 | 1–2 天 | 中高；保留 KIF 双特性和个体外观，验证动画、客机状态与回放，避免重复变形 |
| U04 | 高 | TrainerModern 禁止随机化检查 | `replace_species_to_randomized` 缺少 `SWITCH_DONT_RANDOMIZE` 检查；普通 Trainer 路径已有检查 | 0.5–1 天 | 中；保持首次劲敌和道馆随机化条件，验证固定队伍及相关模式 |
| U05 | 中 | Debugger 道具完整修复流程 | 本地缺少 `pbCommonEvent(COMMON_EVENT_FIX_GAME)` 及明确返回值处理 | 0.5–1 天 | 中；公共事件会改变游戏状态，须核实执行条件和取消路径；保留 KIF 的支持渠道信息 |
| U06 | 中 | 新周目服装与帽子解锁继承 | IF 将 `unlocked_hats`、`unlocked_clothes` 迁移到新角色，本地未保留对应迁移 | 0.5–1 天 | 中；保留现有图鉴迁移，验证旧存档缺字段、独立数组和在线账号/角色隔离 |
| U07 | 中 | 基础立绘导入分流、素材索引与完成率 | 本地导入器缺基础立绘分流，`get_total_completion_percent` 直接返回 0.00 | 1–2 天 | 中；适配 KIF 独立 PNG 路径；索引可单独移植，不以迁移图集为前提 |
| U08 | 中 | 名人堂历史信息 | IF 保存日期、模式、难度及训练师外观，本地主要保存队伍数组 | 2–3 天 | 中高；兼容旧数组/新记录格式，验证旧档、读写及云存档往返，不伪造历史日期 |
| U09 | 后续专项 | 完整 spritesheet 图集系统 | IF 包含图集提取、缓存、队伍预加载及素材包版本失效机制，本地未完整同步 | 10–20 天 | 高；贯穿闪光、个体立绘、融合预览、图鉴及 Android；先明确收益，再设计与现有 PNG 共存的迁移方案 |

### U01 图鉴统计口径

比较对象为完整 JSON 记录（包括 sprite、entry、author 等实际字段），不是单纯按 sprite 去重。一个 sprite 可以有多条不同文本或作者记录。上述记录数使用多重集合统计，以免忽略重复项。

已核实下载的上游 `Data/pokedex/dex.json` Git blob SHA 为 `502cb28af8207e583fd682a3338687beab642470`。本地独有的 200 条记录应逐项保留或评审，不因上游文件较新而直接删除。

2026-10-22 实施结果：6,596 条上游独有完整记录中，有一条完全重复记录及一条数字正文（`241.241.png` 的 `entry: 222`）；排除后新增 6,594 条。KIF 原始记录逐条原样保留。进一步追溯发现 KIF 曾在 `efb8bc02` 导入新版，又在 `48fd73a0` 恢复旧版；默认更新地址仍指向上游旧 `Data/dex.json`。现已改用 `Data/pokedex/dex.json`，并在自动更新时保留本地记录、只追加有效新文本，以免再被较旧响应覆盖。

## 实施顺序与验收清单

### 第一批：内容更新与明确缺口

预计 3–6 个工程日，优先完成 U01–U04。

- [x] U01 本地源码：可重复合并命令、统计、作者保留、更新源及防回退已完成；数据逐条核对、27 项回归和真实 Game.exe 的 12 项隔离检查通过。未重打 APK，人工图鉴页面与全部立绘组合不在本次验证范围内。
- [ ] U02：补回制服和咖啡处理；验证制服穿脱、取消、还原先前装扮；验证咖啡在战内外回复和消耗行为，满血时行为正确。
- [ ] U03：补回并适配 HP 形态回调；覆盖半血上下变化、治疗、倒下及重复设置 HP；验证融合、双特性、房主/客机动画和回放一致性。
- [ ] U04：补回禁止随机化检查；开关开启时保留原物种，关闭时保持原随机化行为，并覆盖首次劲敌与道馆分支。
- [ ] 更新受影响的联机构建摘要/兼容目录；需要更新可信目录时使用真实游戏重新导出，确保客户端与服务端匹配。

### 第二批：存档体验和素材工具

U05–U07 预计追加 2–4 天；U08 单独预留 2–3 天。

- [ ] U05：核实公共修复事件后恢复 Debugger 流程；确认取消和执行返回值、事件结束及保存行为。
- [ ] U06：迁移新周目服装和帽子解锁，保留图鉴迁移；验证旧档缺字段和在线账号/角色隔离。
- [ ] U07：正确区分基础立绘与融合立绘的导入目标；重复导入不覆盖已有文件；对畸形文件名、缺目录与离线状态给出明确处理；从有效索引计算完成率。
- [ ] U08：兼容旧名人堂队伍数组，保存新记录的日期、模式、难度及外观；无历史信息时显示未知；验证保存重读和云端往返。

### 第三批：图集专项

- [ ] U09：先定义收益指标、目录和存档迁移策略、PNG 回退路径与缓存归属，再决定是否实施。
- [ ] 保留 KIF 闪光参数、个体立绘、导入导出、融合和反向融合预览。
- [ ] 验证缓存键覆盖物种、立绘变体、配色等实际输入；检查 Bitmap 生命周期和素材包更新后的缓存失效。
- [ ] 在 Windows 与 Android 记录启动、仓库切箱、图鉴翻页、内存及下载表现；性能收益用实际测量确认。

## 已同步或应保留的差异

不把下列内容重复计入待移植工作：

- Scraggy 雷达、钓鱼比赛难度及体重修正、粉红岛队伍恢复、美术馆取消菜单、三重融合戴帽限制、换装染色等，已通过 KIF 更新包含相应修复。
- KIF 的等级上限、多存档历史备份、闪光、双特性及战斗选项，属于替代或扩展实现，不能为了与 IF 相同而回退。
- `getFusedPokemonIdFromSymbols`：本地使用已转换的物种编号，上游快照仍传原参数，应保留本地修复。
- 地图文件差异需要逐事件核对，不能直接覆盖并丢弃 KIF 的本地改动。
- 应急哨子和呆呆兽尾巴也有处理差异，但当前编译道具数据限制了普通使用方式，暂列潜在兼容缺口；实施前先追踪脚本调用和实际可达性，不宣称已复现普通主线故障。

## 验证证据及限制

已完成：

1. Git 文件内容/目录对比、上游相关提交检查和当前本地调用检查。
2. 图鉴 JSON 完整记录统计及上游 blob SHA 核验。
3. 隔离 Ruby 探针：将 HP 设为 40 时，上游调用形态回调一次，本地未调用；禁止随机化开关开启时，上游返回原物种，本地进入随机化分支。
4. 本地编译道具数据核对：咖啡具备战内外使用标记，制服具备背包使用标记；应急哨子和呆呆兽尾巴的普通使用标记为 0。

探针验证的是特定方法行为，不等于完整真实游戏验收。尚未实施上述移植，没有因本清单重新完成 Game.exe、人工菜单、跨机器或最终 Windows/Android 混合构建回归。后续须按实际修改执行必要验证。

分析资料位于本地忽略目录 `temp/upstream-review/`，不作为交付或长期证据的唯一来源；关键发现、统计口径、基线和验收要求已写入本文。

## 上游代码与资料

- [图鉴数据](https://github.com/infinitefusion/infinitefusion-e18/blob/064a09664aca2e83e28dff436fa37fff72236481/Data/pokedex/dex.json)
- [道具处理（咖啡、制服、Debugger）](https://github.com/infinitefusion/infinitefusion-e18/blob/064a09664aca2e83e28dff436fa37fff72236481/Data/Scripts/052_AddOns/New%20Items%20effects.rb)
- [Battler HP 设置与形态更新](https://github.com/infinitefusion/infinitefusion-e18/blob/064a09664aca2e83e28dff436fa37fff72236481/Data/Scripts/011_Battle/001_Battler/001_PokeBattle_Battler.rb)
- [TrainerModern 随机化](https://github.com/infinitefusion/infinitefusion-e18/blob/064a09664aca2e83e28dff436fa37fff72236481/Data/Scripts/010_Data/002_PBS%20data/013_TrainerModern.rb)
- [新周目迁移](https://github.com/infinitefusion/infinitefusion-e18/blob/064a09664aca2e83e28dff436fa37fff72236481/Data/Scripts/052_AddOns/MultiSaves.rb)
- [基础立绘导入](https://github.com/infinitefusion/infinitefusion-e18/blob/064a09664aca2e83e28dff436fa37fff72236481/Data/Scripts/999_Main/999_Main.rb)
- [素材完成率](https://github.com/infinitefusion/infinitefusion-e18/blob/064a09664aca2e83e28dff436fa37fff72236481/Data/Scripts/052_AddOns/SpriteCreditsUtils.rb)
- [名人堂记录](https://github.com/infinitefusion/infinitefusion-e18/blob/064a09664aca2e83e28dff436fa37fff72236481/Data/Scripts/016_UI/001_Non-interactive%20UI/006_UI_HallOfFame.rb)
- [图集加载目录](https://github.com/infinitefusion/infinitefusion-e18/tree/064a09664aca2e83e28dff436fa37fff72236481/Data/Scripts/048_Fusion/Sprites)
