# 游戏贴图高清化进度（2026-10-28）

## 当前进度

**P2 第 58～93 批已完成：783 / 2,223 张，10 张已应用、773 张保留原图，剩余 1,440 张；下一批为第 94 批。** 本轮完成第 77～93 批共 374 张，新增应用 4 张、保留 370 张。P1 和此前 P2 的已完成结果继续保留。

| P2 范围 | 完成数 | 已应用 | 保留原图 |
| --- | ---: | ---: | ---: |
| 第 58～63 批：战斗界面 | 121 | 6 | 115 |
| 第 64～76 批：队伍、背包、摘要与通用菜单 | 288 | 0 | 288 |
| 第 77～93 批：图鉴、仓库与命名界面 | 374 | 4 | 370 |
| 合计 | 783 | 10 | 773 |

全局 18,665 张：**262 张已应用、867 张保留、17,536 张待处理**。候选待验收为 0；第 94～151 批及 P3～P5 保留在后续计划。没有后台生成或定时任务。

本轮使用内置 `image_gen` 编辑 3 张壁纸，原始提案、完整提示词、尺寸/透明通道/轮廓验证保存在 `p2-dex-work/box*-job.json`、`box*-generated.png` 和 [壁纸结构检查](p2-dex-work/wallpaper-validation.json)。火鸟和水系剪影只引入内部柔和明暗，标题、按钮、边框、姿态、强轮廓和气泡/星点原位保留。已应用 `Graphics/Pictures/box16.png`、`box17.png` 与逐像素同源的 `Graphics/Pictures/Storage/box_32.png`、`box_33.png`；对应第 77、85 批，单通道变化不超过 12/255。草地提案主要改变亮度，未改善辨识度，连同在用副本共 2 张保留原图，候选已归档。

- [仓库原生前后验收](p2-evidence/dex/storage-native-validation.json)：两种语言各显示 200 种壁纸，并断言实际加载编号；498 组前后截图和动画/交互轨迹比对通过。壁纸内部以外的像素完全一致，光标 40 次更新、1,000ms 完整循环；抓取/放置各 17 次更新，换箱、队伍面板开关和壁纸淡入淡出轨迹相同。
- [在用壁纸原尺寸对比](p2-evidence/dex/wallpaper-native-comparison.png)，左为原图、右为交付；[完整光标循环对比](p2-evidence/dex/storage-cursor-loop-comparison.gif)。
- [图鉴与命名验收](p2-evidence/dex/dex-naming-validation.json)：146 张中英文原生截图，包含 16 组命名标签状态、首尾返回、三种光标区域、仓库命名图标、图鉴列表、七类搜索参数、资料和形态页。当前引擎跳过图鉴分布页，旧深色主题/分布页/兼容图只做用途、解码和布局复核并保留原图，不宣称当前场景实际加载。
- 111 张中文图片校验通过，关联表未被本轮修改。新增的 4 张均无中文配套映射。其他保留素材的逐文件理由见 [审查决定](p2-evidence/dex/review-decisions.json)及第 77～93 批 `validation.json`。
- [恢复点复核](p2-evidence/dex/checkpoint-verification.json)：2,223 张 P2 源文件、783 张已完成项和本轮 374 张交付副本哈希核对通过。进度继续由已完成批次的 `validation.json` 汇总。

第 77、85 批 `manifest.json` 仅列已应用结果；原图在 `originals/`，生成图在 `generated/`，应用候选在 `ready/`，最终交付副本在 `delivery/`。第 77、83 批另有 `candidate-manifest.json` 保存已拒绝草地候选，不能计为已应用。其他批次 `jobs.json` 记录未生成的具体理由。

原生测试每轮使用独立 Profile、隐藏窗口和隔离存档，设置超时，stdout/stderr 直接丢弃；每轮 `finally` 清理临时日志和配置，保留可复用的只读运行文件与存档。早期壁纸验收因缓存未刷新作废，修正并加断言后重跑；仅最终带 `-final`/`-verified` 的清理及验收记录用于交付。正式证据保存在约定输出目录。

此前背包 32 份候选因无可见收益归档，仍未应用；[背包原生验收](p2-evidence/bag-native-validation.json)的 280 组对比、8 帧/800ms 箭头循环，以及 [战斗 UI 验收](p2-evidence/ui-native-validation.json)的 120 种指令状态和 12 组 HP/EXP 动画轨迹继续有效。中文摘要学习招式页原有的文字/精灵区域重叠记录继续保留。

**完整游玩、人物/服装叠穿、Android 实机与发布包验证尚未完成。** 当前恢复点为 [p2-progress.json](p2-progress.json)、[p2-work/resume.json](p2-work/resume.json)、[本阶段恢复记录](p2-dex-work/resume.json)。

## P1 第 5～57 批（已完成）

**P1 第 5～57 批已完成验收，共 260 张：166 张已应用、94 张保留原图并逐文件记录原因。** 本次接续新增应用 24 张，包括 10 张地图图集、14 张水面/水流/瀑布自动图块。接续前已应用的 142 张地台继续保留。

| P1 范围 | 总数 | 已应用 | 保留原图 |
| --- | ---: | ---: | ---: |
| 第 5～11 批：战斗地台 | 142 | 142 | 0 |
| 第 12～13 批：纯色消息条 | 27 | 0 | 27 |
| 第 14～43 批：地图图集 | 30 | 10 | 20 |
| 第 44～57 批：自动图块 | 61 | 14 | 47 |
| 合计 | 260 | 166 | 94 |

P1 完成时的历史快照为 252 张已应用、94 张保留；当前累计以本文开头的 P2 进度为准。

在用地图图集：`Indoor`、`Outdoor2`、`Outdoor`、`Boat`、`cave`、`Cit - Interior Tileset`、`multivers`、`sewers`、`sky`、`Underwater`。大图集按页补绘细纹理后原位回填；保护 32×32 图块边界、原轮廓、透明区域、占位格和不足一行的末尾像素。同一图集中相同原始图块使用相同结果。

自动图块保留原始尺寸、帧数、帧顺序和逐像素透明通道，保护 16×16 拼接片的边界。仅在内部加入幅度不超过 6/255 的明暗细纹理；所有帧沿用同一份纹理差值，逐帧颜色变化和首尾循环差值保持原样。地图图集的单通道变化上限为 10/255。效果属于原尺寸细节增强，整体仍保持原来的像素画风格。

保留原因已记录到每批 `validation.json`：27 张消息条无需纹理；当前 809 张地图没有使用的图集/图格、纯黑功能填充继续保留；浅水图的候选版本在结构保护后只有 1 个像素发生变化，没有可见清晰度收益，因此保留原图。保留项不计入已应用数量。

### 本次验证与对比

- 全部 24 张替换文件及备份通过尺寸、透明通道和 SHA-256 校验；66 张初始保留项及浅水图均核对原图哈希。
- 809 张生产地图的引用与实际图格已核对，并保存地图数据哈希；没有修改地图数据、角色动作或游戏逻辑。
- 原生 Windows 引擎渲染 27 张代表地图的前后画面，覆盖全部 10 张在用图集。查看原尺寸对比：[室内与室外](p1-evidence/map-comparison-1.png)、[船只/洞穴/室内](p1-evidence/map-comparison-2.png)、[下水道/天空/特殊区域](p1-evidence/map-comparison-3.png)、[水下](p1-evidence/map-comparison-4.png)。
- 原生引擎检查 15 张自动图块候选/保留源、269 帧、每帧 48 种拼接形态，共 **12,912 个形态**。逐帧核对后确认拼接边界无变化，也未增加帧间或循环闪烁。完整循环对比：[海水](p1-evidence/native-autotiles/batch-052-ocean-comparison.gif)、[岸边](p1-evidence/native-autotiles/batch-051-ocean-shore-comparison.gif)、[水流](p1-evidence/native-autotiles/batch-054-water-current-east-comparison.gif)、[瀑布](p1-evidence/native-autotiles/batch-057-waterfall-comparison.gif)。左侧原图，右侧交付结果，每帧沿用引擎的 250ms 时长。
- [P1 机器进度](p1-progress.json)、[使用范围与保留原因](p1-evidence/map-scope-audit.json)、[浅水图复核决定](p1-evidence/map-review-decisions.json)、[动画拼接验证](p1-evidence/native-animation-validation.json)、[地图渲染结果](p1-evidence/native-maps/after-result.txt)、[动画渲染结果](p1-evidence/native-autotiles/result.txt)。

使用内置 `image_gen` 图像编辑工具；完整提示词和生成来源保存在相应批次 `jobs.json` 以及 `p1-map-work/`、`p1-autotile-work/` 的逐项记录。原图位于每批 `originals/Graphics/`，交付副本位于 `ready/Graphics/`，已同步替换项目 `Graphics/` 中的对应文件。逐文件清单见 [批次索引](execution-plan/batch-index.zh-CN.md)。

本次已验证图片结构、地图显示和完整自动图块循环，**尚未进行完整游玩流程、Android 实机回归或重新构建发布包**。其他会话的本地化、地图加载等改动未由本次提交或覆盖。

校验和恢复仍使用 `scripts/graphics/texture_batch.py verify/restore output/texture-hd/batch-NNN`；仅已应用批次具有 `manifest.json`。纯保留批次只需核对 `validation.json` 中的原图哈希。恢复前会检查当前文件是否仍为本批结果，防止覆盖后续修改。P1 地图批次统一记录工具为 `finish_map_batches.py`；它核对原生验收的候选哈希和地图数据哈希后才允许应用。

## 第 1～4 批历史记录（截至 2026-10-27）

下列数量是前四批完成时的快照；当前累计数量以上方“当前进度”为准。

已应用四批 **86 张**，其中 `Graphics/Battlebacks/battlebg/` 主目录的 **70 张独立战斗背景全部完成**，另有 16 张配套地台。重新扫描后，清单共 **18,665 张**，其余 **18,579 张待处理**；相较首次扫描新增了 111 张中文素材。本目录记录分批结果；全量工程尚未完成，也没有在后台运行剩余生成任务。

用户选择：允许 AI 补绘细节，全部类别分批推进；交付图片必须保持原宽高。

## 已应用的素材

覆盖全部独立战斗背景，包括常见户外场景的昼夜版本、洞穴、室内、道馆、四天王、瀑布、山峰、熔岩与特殊场景。第三、第四批本次新增 62 张。

| 批次 | 内容 | 数量 | 保留的结构 |
| --- | --- | ---: | --- |
| 001 | `Graphics/Battlebacks/battlebg/` 常用背景 | 8 | 原文件名、512×288、原透明通道 |
| 002 | `enemybase/` 和 `playerbase/` 配套地台 | 16 | 各自原始宽高、原位置和透明轮廓 |
| 003 | 户外昼夜、桥面、山地、沼泽、高空、水下、沙地及重复命名素材 | 27 | 原文件名、512×288、原透明通道 |
| 004 | 其余洞穴、道馆、室内、四天王、山峰、瀑布与特殊背景 | 35 | 原文件名、512×288、原透明通道 |

像素内容相同的原图复用同一份补绘结果，累计核对 14 对复用关系，包括城市/草地地台、海滩/水面的部分时段、森林傍晚的重复命名，以及高空/山顶/飞行道馆等。各文件仍单独备份并保留原始文件名。其他原有改动和游戏逻辑没有被本次处理覆盖。

## 效果与生成记录

- [背景对比 1：草地、海滩、森林、洞穴](batch-001/comparison-1.png)
- [背景对比 2：城市、雪地、水面、室内](batch-001/comparison-2.png)
- [敌方地台原尺寸对比](batch-002/comparison-1.png)
- [玩家地台原尺寸对比](batch-002/comparison-2.png)
- [本次代表性场景前后对比](continuation-preview.png)
- 第三批原尺寸对比：[1](batch-003/comparison-1.png)、[2](batch-003/comparison-2.png)、[3](batch-003/comparison-3.png)、[4](batch-003/comparison-4.png)、[5](batch-003/comparison-5.png)、[6](batch-003/comparison-6.png)、[7](batch-003/comparison-7.png)
- 第四批原尺寸对比：[1](batch-004/comparison-1.png)、[2](batch-004/comparison-2.png)、[3](batch-004/comparison-3.png)、[4](batch-004/comparison-4.png)、[5](batch-004/comparison-5.png)、[6](batch-004/comparison-6.png)、[7](batch-004/comparison-7.png)、[8](batch-004/comparison-8.png)、[9](batch-004/comparison-9.png)
- [原生引擎草地场景：原图](engine-check/field-before.png) / [补绘后](engine-check/field-after.png)
- [原生引擎验证结果](engine-check/result.txt)
- [第一批完整提示词与来源](batch-001/jobs.json)
- [第二批完整提示词与来源](batch-002/jobs.json)
- [第三批完整提示词与来源](batch-003/jobs.json)
- [第四批完整提示词与来源](batch-004/jobs.json)
- [逐文件待办清单](inventory.json)
- [剩余素材分类与处理分析](remaining-analysis.zh-CN.md)
- [全部剩余图片的优先级与分批执行计划](execution-plan/README.zh-CN.md)
- [固定编号的完整批次索引](execution-plan/batch-index.zh-CN.md)

使用内置 `image_gen` 图像编辑工具，以每张原图为编辑目标。提示词要求保留构图、原配色、地平线和空战斗区域，仅补绘表面纹理，不新增角色、文字、界面或场景物体。完整原文保存在各批 `jobs.json`。

AI 服务输出较大图片后，使用 Lanczos 缩小至原尺寸。透明地台按可见内容对齐，沿用原图逐像素透明通道；生成内容未覆盖的区域保留原图颜色。备份位于各批 `originals/`，生成大图位于 `generated/`，实际交付副本位于 `ready/`。

## 已完成的验证

- 86 张交付文件均可解码，原始宽高不变。
- 86 张的透明通道与原图逐字节一致；原透明轮廓不变。
- 替换后的文件 SHA-256 与各批 `manifest.json` 一致，原图备份也通过校验。
- 原生 Windows `Game.exe`（Ruby 3.1.3）加载全部 86 张，按游戏 512×384 画面和原有地台位置，针对 70 个背景渲染 140 张前后场景截图。
- 逐张检查第三、第四批原尺寸对比图；有明确物体的背景另核对瀑布、山峰及三块墓碑的数量、轮廓和位置。
- 清单覆盖检查确认 `battlebg/` 下全部 70 张均已应用，未漏文件。
- 处理脚本的尺寸变化、透明通道变化、目录越界拒绝，以及透明留白对齐自检通过。

这次验证涵盖图片加载与场景合成，尚未执行完整战斗流程或重新构建 Android/Windows 发布包。AI 补绘改变了部分表面细节，不能保证与旧画面逐像素相同；文件的原始宽高和透明通道已明确校验。

## 剩余范围

| 类型 | 待处理图片 |
| --- | ---: |
| 其余地台、全景、雾效、标题、动画及其他背景目录内容 | 578 |
| 地图图块与自动图块 | 98 |
| 界面、图标、道具与窗口皮肤 | 4,144 |
| 角色、宝可梦、动画及其他精灵 | 13,648 |
| 新增中文素材 | 111 |
| 合计 | 18,579 |

后续按其余地台与背景、地图图块、界面、角色与动画逐批推进。地图图集须保留图块坐标和接缝；角色和动画须按原分格检查动作、轮廓与帧间一致性；文字和 UI 须核对文字内容和边界。商城等有内容校验的资源须同步核对目录校验记录。不能仅凭整张尺寸一致就将这些素材视为合格。

## 验证与恢复

在项目根目录运行；所用 Python 需有 Pillow。

```powershell
python scripts/graphics/texture_batch.py verify output/texture-hd/batch-001
python scripts/graphics/texture_batch.py verify output/texture-hd/batch-002
python scripts/graphics/texture_batch.py verify output/texture-hd/batch-003
python scripts/graphics/texture_batch.py verify output/texture-hd/batch-004
```

恢复原图：

```powershell
python scripts/graphics/texture_batch.py restore output/texture-hd/batch-004
python scripts/graphics/texture_batch.py restore output/texture-hd/batch-003
python scripts/graphics/texture_batch.py restore output/texture-hd/batch-002
python scripts/graphics/texture_batch.py restore output/texture-hd/batch-001
```

恢复前会核对当前文件是否仍是本批的交付版本；如果文件后来又被修改，会停止，防止覆盖后续工作。原生验证入口为 `engine-probe.rb`，素材清单为 `engine-assets.rb`，只在独立测试配置运行，不引用玩家存档。
