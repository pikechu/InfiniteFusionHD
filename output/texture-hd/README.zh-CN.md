# 游戏贴图高清化进度（2026-10-30）

## 当前进度

**P2 第 58～103 批已完成：1,005 / 2,223 张，15 张已应用、990 张保留原图，剩余 1,218 张；下一批为第 104 批。** 第 103 批 20 张全部保留原图；星云增强提案因原尺寸局部暗块、没有明确视觉收益被拒绝，未替换任何游戏图片。此前已完成结果继续保留。

| P2 范围 | 完成数 | 已应用 | 保留原图 |
| --- | ---: | ---: | ---: |
| 第 58～63 批：战斗界面 | 121 | 6 | 115 |
| 第 64～76 批：队伍、背包、摘要与通用菜单 | 288 | 0 | 288 |
| 第 77～93 批：图鉴、仓库与命名界面 | 374 | 4 | 370 |
| 第 94～102 批：地区地图、导航、帮助与训练师卡 | 202 | 5 | 197 |
| 第 103 批：标题与片头分层素材 | 20 | 0 | 20 |
| 合计 | 1,005 | 15 | 990 |

全局 18,665 张：**267 张已应用、1,084 张保留、17,314 张待处理**。候选待验收为 0；第 104～151 批及 P3～P5 保留在后续计划。没有后台生成或定时任务。

第 103 批完成 138 组原生前后截图、每阶段 4814 个逐帧状态的比较。中英文当前 GenOne 标题的滑入、左右选择、融合停留、淡出与载入菜单构建一致；固定离线测试精灵对为 1/4。GenThree 为旧兼容风格，先记录其原有 Reset 阈值，再仅在测试夹具中延长上限以检查完整 768 更新组合循环（40fps 标称 19.2 秒）。片尾只覆盖前 160 更新的文字滚动与正常跳过，未声称完整片尾或五背景轮播。测试跳过版本联网查询、资源包启动、下载提示和键位写入。

[第 103 批验收与限制](p2-evidence/titles/native-validation.json)、[原尺寸场景对比](p2-evidence/titles/title-native-comparison.png)、[完整提示词](p2-title-work/job.json)、[恢复点复核](p2-evidence/titles/checkpoint-verification.json)。完整原生状态记录无损压缩为 `p2-evidence/titles/*-review.json.gz`，解压后仍是原 JSON；所有原图、生成图和必要截图保留。每轮测试结束即清理临时日志及配置，本轮另外清理 6 个 Python 缓存。远程查询没有 `codex/texture-hd-p2` 分支，历史图片尚不能确认远程可恢复，因此未删除，见 [清理记录](p2-evidence/titles/cache-cleanup.json)。

上一阶段内置 `image_gen` 编辑了地图与金/银/铜三种卡面，共 4 份原始生成图。地图结果制作成通关前、通关后两张交付图；仅增加海水内部细节，路线、城市、地形和海岸像素受保护，两状态的有符号像素差值完全保持。三种卡面共用细微材质明暗，并保护圆形水印、文字区、徽章区和透明边界；三种原配色之间的差值保持。交付仍为原尺寸，地图单通道变化最多 8/255，卡面最多 12/255。

已应用文件为 `Graphics/Pictures/map/map.png`、`map_postgame.png`，以及 `Graphics/Pictures/Trainer Card/backgrounds/BRONZE.png`、`GOLD.png`、`SILVER.png`。本轮五张均没有中文图片映射，关联表无需改写。其余 197 张保留理由见逐批 `validation.json` 和 [审查决定](p2-evidence/region/review-decisions.json)。

- [原生场景验收](p2-evidence/region/native-validation.json)：688 组原图/候选画面对比，保护区域像素完全一致；覆盖 93 种卡面、中英文、男女、通关前后、16 枚徽章、导航选中与循环、帮助四页及 Tutor.net 四种样式。
- [真实人物叠穿对比](p2-evidence/region/trainer-card-native-comparison.png)：48 组画面、16 组实际外观组合，包含 Red/Leaf 与初始睡衣。身体、服装、头发合成的肖像像素及锚点前后一致。主场景测试的新游戏默认临时服装另外由此补测覆盖；未将其当作完整换装动作验收。
- [地图原尺寸对比](p2-evidence/region/map-native-comparison.png)：四组地图运行，每组 802 次更新。完整组合动画循环为 480 次更新（按 40fps 标称 12 秒）；光标 24 次/600ms、飞行点 40 次/1,000ms、边缘箭头 32 次/800ms。前后帧序、周期、滚动与锚点轨迹一致，详见 `before-review.json` / `candidate-review.json`。这份完整循环证据是原生轨迹记录，不是 480 张逐帧截图。
- 15 组旧地图进度资源及中英文版本逐字节保留。Tutor.net 的四格 PNG 在当前界面中只绘制第一格，不伪称已播放四帧动画。旧申请表、旧地图和其他兼容布局按用途/原尺寸复核并保留，未宣称完成全部事件流程。
- 111 张中文图片校验通过。[最终恢复点复核](p2-evidence/region/checkpoint-verification.json)核对全部 2,223 张 P2 源文件、985 张已完成项及本轮 202 张交付副本。每轮隐藏原生测试均已退出，临时原始日志和配置由 `finally` 清理；必要截图与有界失败摘要保留。

完整提示词和生成来源见 [卡面记录](p2-region-work/card-jobs.json)、[地图记录](p2-region-work/map-job.json)。各批原图在 `originals/`、生成提案在 `generated/`、应用候选在 `ready/`、交付副本在 `delivery/`；`manifest.json` 记录已应用文件。逐批 `jobs.json` 也明确记录未生成素材的保留原因。

此前第 77～93 批的 498 组仓库画面对比、200 种壁纸和图鉴/命名记录在 [上一阶段验收](p2-evidence/dex/checkpoint-verification.json)。背包 32 份候选因无可见收益仍未应用，见 [背包验收](p2-evidence/bag-native-validation.json)；战斗 UI 的 120 种状态及 12 组 HP/EXP 动画证据见 [战斗验收](p2-evidence/ui-native-validation.json)。中文摘要学习招式页的原有文字/精灵区域重叠记录继续保留。

**完整游玩、人物/服装全部地图动作与叠穿、Android 实机及发布包验证尚未完成。** 当前恢复点为 [p2-progress.json](p2-progress.json)、[p2-work/resume.json](p2-work/resume.json)及 [本轮恢复记录](p2-title-work/resume.json)。Git 特性分支为 `codex/texture-hd-p2`；本地提交回执保存在 `commit-receipt.json`。

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
