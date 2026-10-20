# Android 正常入口 GUI 游玩测试

测试日期：2026-10-16 至 2026-10-17（Asia/Shanghai），更新截至 00:53。状态：**正常新档→移动→训练家/野外战斗→捕捉→普通融合→仓库存取→拆分→保存→强制结束进程→正常入口读档已实际通过一次完整核心闭环**。标题确认存在已复现的丢键问题；不能据此宣布全部功能、真机验收或剧情通关。

## 环境与证据边界

- 设备：`emulator-5554`，`sdk_gphone_x86_64`，Android 11 / API 30；运行 ARM64 APK，使用 Android ARM 翻译器与记录在构建材料中的临时原生兼容补丁。**不是真机结果，也不是 16 KiB 页兼容验收。**
- 应用：`org.kuray.kif`，`versionName=0.20.7-android.1`，versionCode 1，minSdk 30 / targetSdk 35，安装包 primaryCpuAbi=`arm64-v8a`。
- 对设备已安装 `base.apk` 直接执行 SHA256：`475d2bf3d872915a79c4996369696248d2f57fdb078f25de31f7d74450166279`。
- 游戏从 Launcher → 正常 Main 进入；未选择 customScript 探针。确认 app 私有 `writable/Mods` 为空；本轮未添加 fixture、未修改生产源码。
- 仅使用本 AVD 新建测试档 **QA / File H**。未发现、导入、读取或覆盖 Windows 玩家存档。
- 通过 ADB 操作屏幕上真实虚拟按键；普通按键采用同点 `input swipe ... 150` ms，方向持续移动时使用长按。没有在 Ruby 中直接改角色位置或构造成功返回值。
- 所有截图、日志和新 AVD 存档副本位于 `temp/evidence/gui-loop/`。日志/Android 状态栏原值为 UTC；下文如列北京时间，已按 **Asia/Shanghai (+08:00)** 换算。

## 已实际执行的闭环

| 步骤 | 实际结果 | 主要证据 |
| --- | --- | --- |
| 标题确认 → New Game | 原版加载菜单可响应确认键，进入正常首次开档问答 | `03-load-menu.png`、`05-new-game-loaded.png` |
| 开档来源问答 | 初次选择 Other 进入原版警告分支；源码确认该分支最终会打开浏览器并退出，故在未创建正式槽前安全重开新档，选择第一项继续 | `08-origin-options.png`、`22-origin-first-option.png` |
| 原版角色与昵称输入 | 默认 Male / 10 岁；进入 Mobile cursor 名字界面，按方向选 Q、A，Run(Z) 跳 OK，确认角色；实际存档独立只读解析为 `name=QA` | `30-name-cursor-ready.png`、`32-name-QA-ok.png`、`34-character-confirm.png` |
| 难度与首次保存 | 选择 Easy，Autosave=Yes；在真实存档界面从 File A 移至空 **File H** 并确认，生成正式槽文件 | `37-easy-difficulty.png`、`39-file-H-selected.png`、`40-first-save-result.png` |
| 正常剧情/地图渲染 | 原广告、精灵演示、送信场景和卧室地图顺序显示；这些开场演示不记为玩家融合功能验收 | `43-story-advert.png`、`47-story-demo-fusion.png`、`52-letter-scene.png`、`53-letter-scene-next.png` |
| 玩家实际地图移动 | 卧室 Map69 从 `(8,9)` 向右、向下各走 1 格；方向和地图相对电视位置实际改变，最终 `(9,10)`、朝下 | `53-letter-scene-next.png` → `54-bedroom-move-right.png` → `55-bedroom-move-down.png` |
| 原暂停菜单保存 | X 打开菜单 → Save → Save to File H；UI 明确显示 QA saved the game；正式文件更新成功 | `57-save-menu-selected.png`、`58-save-dialog.png`、`59-bedroom-save-result.png` |
| 结束进程与正常重启 | 保存提示完成后对本测试 app 执行 `am force-stop`；旧游戏 PID 13968 消失，Launcher 返回 COLD 启动，新游戏 PID 15814 | `60-before-force-stop.png`、`session-13968.log`、`session-15814.log` |
| 原加载菜单读正式槽 | 标题确认后加载卡显示 File H、QA's Room、角色与游戏时间；确认 Continue 后回到同一卧室位置、朝向及外观 | `65-continue-menu.png`、`67-readback-bedroom.png` |
| 读后文件保持 | 重启前、重新进入标题后、Continue 读后，正式槽文件 SHA256 完全相同 | 下节哈希；`FileH-bedroom-before-readback.rxdata` |
| 空仓库入口/切箱 | 正常菜单 PC 打开真实 PokemonStorageScene；S 将 Box1 切至 Box2，背景及箱名改变；X → No 退出回地图 | `68-pc-selected.png`、`69-pc-result.png`、`70-pc-next-box.png`、`71-pc-exit.png` |

首个菜单保存北京时间 **23:08:25**；force-stop 后重新读取正式槽约在 **23:14**。以上整个闭环没有用专用 probe 文件代替正式 SaveData 槽。

## 正式槽与位置证据

首次开档配置期的正式 `File H.rxdata`：675,694 bytes，SHA256 `0d85612ded76d8354d916dfe95ca52ba16dd41f01332233cf6521a2c32a3b76d`。

卧室移动后由真实菜单保存的正式文件：**683,479 bytes**，SHA256 **`9469d10cafb6e8f9cd8aa7b3f65d1ef705eb337179e31f3ee752097de5ae253a`**。读后哈希未改变。通过 app 私有文件只读导出该 AVD 新建文件，主机副本哈希与设备一致。

对这个副本的独立只读 Marshal 解析（没有运行游戏逻辑或写回）确认：

- `player.name=QA`，`save_slot=File H`。
- MapFactory 活动地图 `69`；`game_player x=9, y=10, direction=2`，`real_x=1152, real_y=1280`。
- `save_count=3`，`frame_count=17090`；菜单/保存均未禁用。
- `PokemonSystem screensize=1, textinput=0, on_mobile=true`。
- 存档版本 Essentials `19.1.dev`、Infinite Fusion 基线 `6.4.5`；该结构未单独写入 KIF 0.20.7 字段。

## 正常剧情、战斗与捕捉续测

以下操作延续同一正常入口、同一 AVD 和 **QA / File H**，未导入 fixture，未改动游戏源码或直接写入游戏状态。原最小读档闭环表和哈希保留在上文。以下“通过”仅指所列实际操作，不代表覆盖所有战斗类型、捕捉边界或完整剧情。

| 步骤 | 预期与实际结果 | 主要证据 |
| --- | --- | --- |
| 卧室下楼、睡衣剧情限制 | 楼梯从右侧入口进入，正常传送到妈妈所在房间；身穿睡衣被要求换装并送回卧室，符合原剧情 | `78-stair-left-enter.png`、`80-living-room.png`、`81-mother-dialogue.png`、`82-returned-for-clothes.png` |
| 原暂停菜单换装 | Outfit → Change clothes → Red jacket and Jeans → Wear；穿戴成功后再次下楼，妈妈继续剧情，不再因睡衣退回 | `83-outfit-menu-start.png`、`85-clothes-list.png`、`86-wear-clothes.png`、`87-clothes-worn.png`、`89-dressed-downstairs.png` |
| Trainer Card 与对手昵称 | 妈妈交付信件和 Trainer Card；进入原版对手昵称界面，保留默认 Blue 后正常结束对话 | `91-mother-letter.png`、`92-mother-card.png`、`94-rival-name.png`、`96-rival-name-accepted.png`、`97-mother-finished.png` |
| Pallet 与 Oak 接引 | 从家门步行到镇北触发 Oak 拦截，按原剧情进入实验室，地图切换和 NPC 移动完成 | `101-pallet-arrival.png`、`107-oak-trigger.png`、`108-oak-stop.png`、`110-oak-lab-transition.png`、`111-lab-intro.png` |
| 正常获取初始精灵 | 对桌上精灵球交互并确认 Charmander；实际显示获得提示，昵称步骤未设置自定义名；随后劲敌取走剩余精灵并完成 DNA Splicers 讲解 | `113-starter-interaction.png`、`114-starter-confirm.png`、`115-starter-accept.png`、`116-starter-nickname.png`、`118-rival-starters.png`、`120-rival-fusion-dialogue.png` |
| 劲敌首战 | 走入劲敌视线，进入真实训练家战斗；通过战斗菜单使用 Scratch，敌方倒下，获得经验并升级，胜利后返回实验室；通过原菜单再次保存 File H | `122-rival-battle-trigger.png`、`126-battle-command.png`、`127-first-scratch.png`、`130-rival-fainted.png`、`131-rival-victory.png`、`132-rival-defeated.png`、`133-post-battle.png`、`136-postbattle-save.png` |
| Route 1 野外战斗 | 正常地图移动进入草地触发野生战斗，执行 Scratch 并击败野生精灵，返回地图继续行走 | `145-route1-grass.png`、`149-wild-encounter.png`、`150-wild-scratch.png`、`151-wild-defeated.png`、`154-route1-position.png` |
| Viridian 包裹与融合道具 | 步行穿过 Route 1 到 Viridian PokéMart，与柜员对话，获得 Oak's Parcel 和 1 个 DNA Splicers；无需脚本授予道具 | `161-route1-gap.png`、`164-mart-door.png`、`168-mart-clerk.png`、`170-parcel-item.png`、`171-splicer-item.png` |
| 正常领取球和 Pokédex | 步行返回实验室，向 Oak 交付包裹，按原剧情获得 5 个 Poké Balls 和 Pokédex，随后重新前往 Route 1 | `183-pallet-from-route1.png`、`186-oak-parcel-return.png`、`188-oak-parcel-delivered.png`、`189-oak-ball-dialogue.png`、`190-pokedex-dialogue.png`、`191-lab-with-balls.png`、`197-balls-route1.png` |
| 真实玩家捕捉 | 野生 Pidgey 战斗 HUD 显示 Lv3；削减 HP 后打开战斗 Bag，选择并投掷 Poké Ball，显示捕捉成功，再进入捕捉后登记/昵称流程并返回菜单。捕捉后存档中的等级另列于下节，不将其混作战斗 HUD 的等级 | `198-capture-encounter.png`、`199-capture-weaken.png`、`200-battle-bag.png`、`201-ball-use-choice.png`、`202-ball-result.png`、`206-postcapture-name.png`、`208-postcapture-pause.png` |
| 捕捉后正式保存 | 原菜单 Save 保存 File H，设备正式槽与只读导出副本大小、哈希一致；独立 Marshal 解析确认队伍、道具及位置 | `209-capture-save.png`、`FileH-after-capture.rxdata`、`FileH-after-capture.decoded.json`、`saves-after-capture-listing.txt` |

### 捕捉后正式槽与等级校正

捕捉后正式槽文件为 **847,853 bytes**，SHA256 **`6c6b501d129eaca874741b88f0c967deaf3ba6c1bc3c4ee4bf9ab0ecb9c36c5b`**。证据副本 `temp/evidence/gui-loop/FileH-after-capture.rxdata` 与设备正式槽一致；解析前后再次检查哈希，源文件未改变。解析仅用无游戏逻辑的通用 Marshal 类型占位类，没有载入生产脚本或写回存档。

`temp/evidence/gui-loop/FileH-after-capture.decoded.json` 的 6 项断言通过，记录：

- `player.name=QA`，`save_slot=File H`，金钱 `3080`，队伍共 `2` 只。
- Charmander：存档 `level=7, exp=281, hp=17, totalhp=23`。
- Pidgey：存档 `level=5, obtain_level=5, exp=135, hp=13, totalhp=19`；获得地图 `78`。
- 背包 `POKEBALL=4, DNASPLICERS=1`，与用掉 1 个初始球的捕捉流程一致。
- 活动地图 `78`，位置 `(21,47)`，朝上 `direction=8`；`save_count=6`，菜单和保存未禁用。

**等级证据须分开解释：**截图 `198-capture-encounter.png` / `202-ball-result.png` 的战斗 HUD 确实显示 Pidgey **Lv3**，而导出的捕捉后正式槽存储 **Lv5**。前述口头“捕捉 Lv3”描述的是战斗 HUD；JSON 记录的是保存结果。当前没有以受控追踪证明变化来源，不把它擅自归因为游戏规则或 Android 缺陷，也不据此否定已经显示捕捉成功且队伍新增 Pidgey 的结果。

### 自动备份观察

设备私有 saves 目录的只读列表已保存为 `temp/evidence/gui-loop/saves-after-capture-listing.txt`。除正式 `File H.rxdata` 外，实际观察到 3 个逐次命名的备份：

| 备份文件 | 大小 |
| --- | --- |
| `File H 1 0h 7m QA's Room.rxdata` | 683,476 bytes |
| `File H 2 0h 27m Oak's Lab.rxdata` | 808,963 bytes |
| `File H 3 0h 41m Route 1.rxdata` | 847,853 bytes |

列表中正式槽与第三份备份的时间原值为 **2026-10-16 16:12 UTC**，即 **2026-10-17 00:12 Asia/Shanghai**。本轮确认的是备份文件存在及大小，**尚未恢复这些备份，也未验收备份内容、轮换或导入导出**。列表还保留了历史 runtime/probe 文件；它们不作为本次正常游戏存档或游玩通过证据。

### 补充观察

- 截图 `210-field-bag.png` 至 `216-fusion-animated.png` 最初仅证明使用道具、选择双方和形态并进入动画；后续已继续完成能力/招式选择、保存和拆分，完整结果追加于下节。未把早期动画中的过渡帧单独作为成功证据。
- Route 1 在持续向左移动时出现了截图 `159-route1-top.png` 的 “Would you like to cut it right down?” 提示；选 No 后已沿普通缺口继续进入 Viridian（`160-route1-cut-bypass.png`、`161-route1-gap.png`）。源码及地图事件的只读核查尚未定位该确切文案的调用，暂记为**未归因异常**，不直接断定为输入桥接或游戏业务缺陷。本轮未改源码绕过。

## 完整融合、第二次捕捉、仓库与拆分续测

以下结果延续正常 GUI 和同一 QA / File H，更新截至 **2026-10-17 00:40 Asia/Shanghai**。未通过 fixture 授予道具或改写精灵；新增的两个 DNA Splicers 来自普通 PokéMart 购买。

| 步骤 | 预期与实际结果 | 主要证据 |
| --- | --- | --- |
| 完整普通融合 | Bag 中使用 DNA Splicers，选择 Pidgey 与 Charmander、融合形态并确认；完成动画、登记、能力选择及招式步骤，队伍只剩真实融合个体，随后退出并经原菜单保存 File H。提示已用完最后一个 DNA Splicers | `210-field-bag.png`、`212-fusion-orientation.png`、`217-fusion-outcome.png`、`220-fusion-record.png`、`221-fusion-ability-select.png`、`222-fusion-confirm-ability.png`、`223-fusion-moves.png`、`225-fusion-ember-learn.png`、`226-fusion-party-final.png`、`228-fusion-save.png` |
| 融合个体真实战斗 | 正常草地遇到 Rattata；融合个体 Chargey 显示真实战斗精灵和招式菜单，使用 Ember，击败敌方并取得经验，流程正常返回地图 | `231-fused-battle-moves.png`、`232-fused-ember-result.png`、`233-fused-wild-victory.png` |
| 第二只野生精灵捕捉 | 遇到 Hoothoot Lv3；满血时投第一球失败，仍返回战斗菜单；削弱到红血后投第二球成功，完成登记并加入队伍。截图 `244-hoothoot-caught.png` 的文件名不代表捕捉成功：该图实际上仍显示活跃敌方和战斗菜单 | `241-upper-encounter.png`、`242-hoothoot-catch-bag.png`、`243-hoothoot-ball-result.png`、`244-hoothoot-caught.png`、`245-hoothoot-weakened.png`、`246-hoothoot-second-ball.png`、`248-hoothoot-record-loaded.png`、`249-upper-ledge-after-catch.png` |
| 普通商店补货 | 返回 Viridian PokéMart，在普通 Buy 界面购买 2 个 DNA Splicers，单价 300、总价 **600 游戏币**；完成购买并正常保存。未使用 PC 或 Kuray Shop 代替此项 | `255-mart-shopping.png`、`256-buy-splicers-quantity.png`、`257-buy-splicers-confirm.png`、`258-splicers-purchased.png`、`259-mart-checkpoint-save.png` |
| 有精灵的仓库存入 | 原菜单 PC 打开仓库，选中融合个体 Store 到 **Box2**；箱中实际出现融合图标与预览，队伍从 2 只减少为 Hoothoot 1 只 | `264-pc-box2-party.png`、`265-pc-fusion-context.png`、`267-storage-fusion-menu.png`、`268-storage-destination.png`、`269-fusion-stored-box2.png` |
| 仓库取回 | 选中 Box2 融合个体，执行 Withdraw，融合个体重新回到队伍，队伍恢复为 2 只；后续拆分存档显示所有箱子为空，与取回结果一致 | `270-storage-withdraw-context.png`、`271-fusion-withdrawn-party.png`、`FileH-after-unfusion.decoded.json` |
| 普通拆分 | 从 Bag 使用 DNA Splicers，选中 Chargey 并确认；逐条确认拆分中的 3 条消息后，显示拆分成功，队伍为 Hoothoot、Pidgey、Charmander 共 3 只。使用了 1 个本次购买的道具 | `272-unfusion-bag.png`、`274-unfusion-party.png`、`275-unfusion-confirm.png`、`276-unfusion-result.png`、`277-unfusion-done.png`、`278-unfusion-party-three.png`、`280-unfusion-three-party.png` |
| 拆分后正式保存 | 退出相关界面，通过原暂停菜单 Save → File H，显示保存完成；只读导出正式槽并独立解析，物种、经验、物品与金钱符合下节结果。`281` 文件名虽含 save，实际是退出商店后的地图，正式保存证据为 `283` | `282-unfusion-save-menu.png`、`283-unfusion-saved.png`、`FileH-after-unfusion.rxdata`、`FileH-after-unfusion.decoded.json` |
| 拆分后进程终止与读档 | **实际通过**：结束旧 PID15814，冷启动新 PID26302，经正常标题/Continue 回到同一 Viridian 位置；标题反复确认后才推进，单独记录缺陷。原菜单打开队伍，3 个普通物种仍存在；正式槽哈希与重启前完全相同 | `284-unfusion-before-kill.png`、`294-after-confirm-burst.png`、`296-final-three-party.png`、`second-restart-state.txt`、`final-readback-save-sha256.txt`、`session-26302.log` |

### 融合后正式槽证据

`temp/evidence/gui-loop/FileH-after-fusion.rxdata` 为 **847,866 bytes**，SHA256 **`436926cf947c416314ec9057b46007a8c84173478bc9f27ddfea0487fc906356`**。无游戏逻辑的独立解码结果保存在 `FileH-after-fusion.decoded.json`，**11/11 断言通过**：

- QA / File H，队伍 1 只；`GameData::FusedSpecies`，`species=B16H4`、数值编号 `8020=16×501+4`、名称 **Chargey**、Lv6。
- 嵌套身体物种 Pidgey（16），头部物种 Charmander（4）；原头部经验 `281`、身体经验 `135` 与捕捉后正式槽中的双方分别一致。
- 招式为 Ember、Sand Attack、Scratch、Growl；背包 DNA Splicers 为 `0`。
- 该融合存档保存的是原始**物种数据**与经验字段，不包含完整原始 Pokemon 个体对象；`@fused=nil`，不能用该旧字段为空误判为未融合。

### 拆分后正式槽证据

`temp/evidence/gui-loop/FileH-after-unfusion.rxdata` 为 **754,867 bytes**，SHA256 **`c4e4ae9a47faca16d94c9c84014158b845174f6a7975e46634aaee73b8c23b3b`**。独立解码记录为 `FileH-after-unfusion.decoded.json`；先提取实际值再设定对应检查，**13/13 断言通过**。解析未载入生产脚本，未运行游戏逻辑，源存档在解析前后哈希不变。

| 队伍顺序 | 普通物种 | 保存等级 | 保存经验 | HP | 保存招式 |
| --- | --- | --- | --- | --- | --- |
| 1 | Hoothoot | 3 | 27 | 3/16 | Tackle、Growl、Foresight |
| 2 | Pidgey | 5 | 135 | 19/19 | Tackle、Sand Attack |
| 3 | Charmander | 8 | 322 | 24/24 | Scratch、Growl |

三个个体均为普通 `GameData::Species`，不再是融合物种。正式槽还记录：

- 背包 `DNASPLICERS=1, POKEBALL=2`，金钱 `2480`。
- 购买前 3080、购买两道具扣 600 后为 2480；购买的 2 个道具用于本次拆分 1 个后剩 1 个。
- Poké Balls 在 Pidgey 捕捉后为 4，Hoothoot 两次投球后为 2。
- 活动地图 Viridian `79`，位置 `(25,29)`，朝下 `direction=2`；`save_count=12`，菜单和保存未禁用。
- 当前仓库索引 `1`（Box2）；所有箱子保存精灵数量为 0。此项支持本次已取回融合个体，不等同于大量仓库或长期存储验收。

本轮融合、战斗、存取和拆分完成一次正常操作验证；**反向融合仍待验证**。源码和地图公共商店事件显示，零徽章普通商店出售 DNA Splicers，但尚未出售 DNA Reverser；本轮没有以改包、授予徽章或修改商店库存绕过该剧情进度限制。

### 最终状态冷启动读回（00:41–00:53）

- 保存完成、提示关闭后，对本测试 app 执行 `am force-stop`。设备时间 `2026-10-16 16:41:09 UTC` 记录旧游戏 PID15814；启动 Launcher 后 `16:41:22 UTC` 已出现新 PID26302，原 PID 已消失（`second-restart-state.txt`）。
- 新进程使用正常 Main，没有 customScript 或临时 Mod。日志再次记录 `KIF_ANDROID_INPUT_READY`。从标题进入正常 Continue 后回到 Viridian `(25,29)` 朝下，与保存的商店门口位置和服装一致（`294-after-confirm-burst.png`）。
- 原暂停菜单打开队伍，Hoothoot、Pidgey、Charmander 均实际显示（`296-final-three-party.png`）。打开队伍前测试操作还误选并实际执行了一次原版 Heal Pokémon，截图 `295-final-party-readback.png` 是治疗提示，所以 **296 的满 HP 不作为存档 HP 原样恢复证据**；物种和等级与正式槽匹配，未再保存这次治疗。
- Continue 后、打开队伍期间只读取得的正式槽 SHA256 仍为 `c4e4ae9a47faca16d94c9c84014158b845174f6a7975e46634aaee73b8c23b3b`（`final-readback-save-sha256.txt`），与强制结束前的 754,867-byte 导出完全相同。仓库存入状态本身没有单独跨进程保存/恢复；本次读回的是已取出并拆分后的状态。
- 本次标题确认出现明确可操作性缺陷：数次 300 ms 及 1.2 s 确认仍停留标题，随后 16 次 150 ms 确认（间隔 200 ms）才成功进入并读档。源码中 `Scene_Intro.update` 在 `@screen.update` 后再次 `Input.update`，而动画 `wait(150)` 内也更新并消费 C 边沿；该路径能够丢掉确认。当前仅定位、未修改或验证修复，不能把密集按键作为正式交互方案。

## 性能和可视限制（实际观察）

- 标题和光标名字界面约 38–40 FPS；卧室及行走约 25–29 FPS；开场精灵演示约 18–23 FPS；空仓库约 34–40 FPS。
- 首次槽选择期间观察到约 8–15 FPS；已有正式槽的加载菜单截图曾出现 **2 FPS**。尚未做稳定采样分布，不能把瞬时数值写成统计均值或据此推断真机性能。
- Continue 恢复卧室后 `dumpsys meminfo 15814`：**TOTAL PSS 686,352 KiB，TOTAL RSS 798,256 KiB**。这是 ARM 翻译模拟器上的一次采样，未证明低内存设备可接受。
- 融合和第二次捕捉期间采样 **PSS 754,014 KiB / RSS 866,364 KiB**（`meminfo-after-fusion-hoothoot.txt`）；最终冷读后 **PSS 650,591 KiB / RSS 763,296 KiB**（`meminfo-final-readback.txt`）。未测峰值、长期增长或大量闪光仓库。
- 普通训练家/野战约 36–40 FPS，完整融合界面约 30–32 FPS，实际 Box2 存取约 40 FPS。捕捉/融合后首次图鉴界面观察到约 15–30 秒黑色过渡后正常显示，尚未定位是否由加载或网络等待导致；未以 native FPS 文本仍显示 40 推断该等待可接受。
- 多处菜单/消息字体下沿被裁切（名字、正文、选项等截图可见），影响阅读；本轮通过网格位置和存档解析确认名字 QA，不能把当前字体布局记为通过。
- 若干 ADB screencap 在 FPS/控件仍可见时得到黑色游戏区域，重复截图又恢复；尚未区分真实短暂黑帧、模拟器 GL/合成和取帧时机。保留相关原图，没有用这些图宣称画面验证通过。
- 当前已安装 APK 仍含首次复制桌面控制 profile 并提示重启的逻辑；父任务先前已接受该提示。源码已另行加 Android capability guard，但**本 APK 尚未验证这条新修复的全新安装行为**。
- 日志有 `KIF Android download write failed (ArgumentError)`，对应远程设置等被存储边界拒绝的路径；没有中断本次本地开档。下载功能仍需独立离线/断网/实际补图验收。
- 标题确认丢键已在最终冷启动复现并定位到重复更新输入的消费路径，详见上节；未改 Ruby 返回值绕过，也未验证修复。

## 尚未完成

已完成上述具体训练家首战、野外战斗、两次成功捕捉、一次普通融合/拆分、有精灵的 Box2 存取，以及拆分后正式槽的进程终止→重启读档；目前仍未完成反向融合/进化 UI、多只闪光同时显示、大量仓库压力、正式多槽切换、备份恢复与存档导入导出、升级、断网/缓存损坏、锁屏、不同设备/API 和 Windows 游戏回归。标题确认和字体裁切仍需修复及回归。

本报告会随继续测试补充，不应把已完成的最小游玩保存闭环扩展为完整可玩性验收、真机验收或公开发布状态。
