# 游戏贴图高清化进度（2026-11-02）

## P4 处理与验收已完成（2026-11-03）

**第 541～816 批全部完成：5,065 / 5,065 张，全部保留原图，待验收候选为 0。** 完成包含逐项审查后保留原图；本阶段没有获准应用的 AI 重绘。图标、功能遮罩、精确切片和连续帧的原有轮廓已清楚，添加纹理没有确定的原尺寸辨识收益。`item001` 试制改变比例和红色标记，已拒绝，提示词、生成图及对比继续归档。

| P4 范围 | 文件数 | 结果 |
| --- | ---: | --- |
| 第 541～604 批：图标 | 3,066 | 保留全部像素、双格和识别色 |
| 第 605～615 批：足迹与阴影 | 654 | 保留稀疏轮廓及功能透明度 |
| 第 616～621 批：窗口 | 83 | 保留边框切片、光标和侧车配置 |
| 第 622～737 批：招式与球特效 | 925 | 保留图格、渐隐及连续颜色 |
| 第 738～769 批：天气、雾和转场 | 243 | 保留粒子、渐变和功能遮罩 |
| 第 770～816 批：长条/GIF | 94 | 保留完整编码、帧序、原始延迟和文本 |

原生证据及边界：

- [图标与功能层](p4-evidence/icons-review.json)：3,720 张解码，13,720 个图标状态和 1,297 个道具图标检查；旧数字路径与当前命名解析器分开记录。
- [窗口](p4-evidence/windows-review.json)：83 张、996 组中英文/尺寸/开合及完整光标周期。原有全闭窗口异常和 `Windowskin.PNG` 扩展名解析差异保留，未修改游戏源码。
- [招式](p4-evidence/effects-review.json)：925 张解码，2,546 组正常/反向动画数据播放至结束、238,484 个图格检查；8 个原有越界图格来源已单列。音效调用被观察但不播放；未引用来源不冒称完整招式实战。
- [精灵球](p4-evidence/balls-review.json)：92 张球资源、44 组配对经过实际轨迹/翻滚/开合/复位组件；既有空 Ballburst 方法及兼容替代图未冒称完整捕获效果。
- [天气、雾和转场](p4-evidence/weather-review.json)：243 张解码，10 种天气、3 档强度、粒子再生、两轮平铺及淡入淡出；18 个雾层、14 个粒子类、13 组 HGSS 转场，共 551,640 个状态检查。`RisingSplash` 的 40 帧边界异常保留，实际调用的 50 帧完整结束。SunMoon、备用 VS 和未绑定层仅作兼容加载，未虚构现用播放入口。
- [长动画](p4-evidence/animated-review.json)：8 个 GIF 的 191 帧透明度及可见 RGB 一致，原生各播放两个完整循环；两份蛋裂纹通过实际格位及摇摆检查。[四页阶段审查及 5,074 个有序单元哈希](p4-evidence/animated-phase-review.json)保留长条的独立姿态、变体与文字。`164.267.gif` 的变帧延迟与原生固定 20fps 不一致，保留原文件并明确记录；未绑定长 PNG 不赋予虚构的正式时长或物种绑定。

全部 5,065 张的当前文件、原图和 delivery 副本与冻结哈希一致；尺寸、透明通道、画格、GIF 原始帧序/时长不变。见[最终复核](p4-evidence/checkpoint-verification.json)、[机器进度](p4-progress.json)和[恢复记录](p4-work/resume.json)。全局 18,665 张中：268 张已应用、16,547 张保留、1,850 张待处理。P1～P4 已完成，P5 第 817 批尚未开始。

本轮进程、原始日志、GIF 导出帧和临时验收工具已清理；原图、生成试制及正式证据保留。完整游玩、Android 实机和最终发布包尚未验证。

## P3 处理与验收已完成

**第 152～540 批全部完成：9,181 / 9,181 张，1 张应用、9,180 张保留原图，待验收或待应用候选为 0。** 本次从第 304 批恢复，完成余下 6,175 张。完成包含逐项审查后保留原图；P3 没有获准应用的 AI 重绘，不能将此数量理解为 9,181 张都已高清重绘。

| P3 范围 | 完成数 | 已应用 | 保留原图 |
| --- | ---: | ---: | ---: |
| 第 152～250 批：地图人物、NPC 与行走精灵 | 1,967 | 0 | 1,967 |
| 第 251～312 批：跟随宝可梦 | 1,189 | 0 | 1,189 |
| 第 313～378 批：衣服、头发、帽子及分层素材 | 1,441 | 0 | 1,441 |
| 第 379～472 批：替换画法与静态战斗图 | 2,998 | 0 | 2,998 |
| 第 473～511 批：特殊形态、三重融合、蛋与替身 | 928 | 0 | 928 |
| 第 512～540 批：小游戏、开场与其他界面 | 658 | 1 | 657 |
| 合计 | 9,181 | 1 | 9,180 |

唯一替换是第 524 批的 `Graphics/Pictures/Constellations/295.130a.png`：原文件虽以 PNG 命名，实际为 WebP，原生引擎无法读取；现已无损编码成真正 PNG。尺寸仍为 288×288，解码后的全部 RGBA 像素相同，没有改变画面、透明通道或位置。2026-11-02 已重新通过原生直接路径加载，未使用资源路由覆盖；[修复记录](p3-work/encoding-repair.json)、[原生读取结果](p3-evidence/remaining/encoding-native-review.json)、[原图与交付清单](batch-524/manifest.json)。恢复原编码会恢复其原有的读取问题。

其余素材保留理由见各批 `validation.json` 和 `jobs.json`，视觉审查覆盖 375 页及逐像素相同素材的对应关系。小型精灵与精确叠穿层已有清楚的色块；单独添加纹理没有原尺寸辨识收益。独立替换画法、恶搞图、蛋纹样和融合部件保留各自内容与画风；功能遮罩、文字、图格和渐变保留原用途。第 152 批内置 image_gen 的 Chase 行走试制改变了全部 16 格的边界、帽子及手部细节，已拒绝；[AI 对比](p3-evidence/batch-152/pilot-comparison.png)及[完整提示词](p3-work/batch-152-pilot.json)继续归档。本次未新增 AI 试制。

已复核的原生证据及其边界：

- [人物与跟随精灵](p3-evidence/remaining/characters-review.json)：3,136 张后续素材，48,544 个方向/格位状态、3,034 次资源切换、四速度完整计数周期和 20 条五格投掷序列；第 152 批另有 [224 个状态及 16 次切换](p3-evidence/batch-152/validation-summary.json)。固定兼容场景未覆盖全部地图事件、跟随 AI、屋顶遮挡或水面交互；非标准九格来源未冒称已通过正确的四格行走动画。
- [服装叠穿](p3-evidence/remaining/outfits-review.json)：52,368 个动作/方向/格位状态、535 次肖像合成；真实 Sprite_Player/Sprite_Wearable 路径覆盖匹配现有命名的资源。34 项原有命名或尺寸兼容问题单独保留，未擅自改名，也未穷尽全部衣柜组合。
- [替换战斗图与特殊素材](p3-evidence/remaining/battle-art-review.json)：7,852 组前后面缩放/镜像与锚点检查，392,600 个选择浮动/目标闪烁状态，覆盖完整 24 更新组合周期。特殊图、蛋图的显式图片兼容显示不证明其全部物种绑定或孵化事件。
- [界面与开场](p3-evidence/remaining/ui-review.json)：658 张全部解码，包含中英文老虎机的三个难度与完整转轮循环/停止、挖矿击打与层深、五种拼图旋转、翻牌动画，以及全部 230 帧开场按顺序播放、每帧两次更新和跳过路径。其余装饰及兼容素材保留字节不变，未将解码等同于完整事件流程。

本次最终复核确认全部 9,181 张当前文件、原图备份及 delivery 副本与验收哈希一致，尺寸、透明通道和画格布局不变；原生证据的消费脚本哈希和无损轨迹归档均有效。源码、本地化和 P2 进度未改变。[最终恢复点复核](p3-evidence/remaining/checkpoint-verification.json)、[P3 机器进度](p3-progress.json)、[恢复记录](p3-work/resume.json)、[逐页审查记录](p3-work/visual-review.json)。可用 `python -B output/texture-hd/verify_p3_checkpoint.py` 重跑完整恢复点检查。

本轮原生进程已退出，临时日志及测试配置已清理，原始 stdout/stderr 未落盘；[本轮清理记录](p2-evidence/dex/texture-p2-dex-p3-encoding-final-20261102-cleanup.json)。原图、历史生成结果、交付副本与必要证据保留。P3 完成时的历史快照为：全局 18,665 张中，268 张已应用、11,482 张保留、6,915 张待处理；当前进度以上方 P4 保存点为准。

**完整游玩、全部地图/动作事件、全部叠穿组合、Android 实机及最终发布包尚未验证。**

## P2 处理与验收已完成

**第 58～151 批全部完成：2,223 / 2,223 张，15 张已应用、2,208 张保留原图，待验收候选为 0。** “完成”包含逐项审查后保留原图，不表示所有图片均已重绘。第 104～151 批本轮 1,218 张全部保留；没有新的游戏图片替换，也没有修改其他会话的源码或本地化关联表。

| P2 范围 | 完成数 | 已应用 | 保留原图 |
| --- | ---: | ---: | ---: |
| 第 58～63 批：战斗界面 | 121 | 6 | 115 |
| 第 64～76 批：队伍、背包、摘要与通用菜单 | 288 | 0 | 288 |
| 第 77～93 批：图鉴、仓库与命名界面 | 374 | 4 | 370 |
| 第 94～102 批：地图、导航、帮助与训练师卡 | 202 | 5 | 197 |
| 第 103～105 批：标题、载入与启动界面 | 49 | 0 | 49 |
| 第 106～107 批：全景与场景背景 | 17 | 0 | 17 |
| 第 108～113 批：主角身体与动作 | 82 | 0 | 82 |
| 第 114～115 批：初始服装、发型与帽子 | 43 | 0 | 43 |
| 第 116～145 批：默认宝可梦战斗图 | 917 | 0 | 917 |
| 第 146～151 批：训练师立绘与背面帧表 | 130 | 0 | 130 |
| 合计 | 2,223 | 15 | 2,208 |

P2 完成并启动 P3 第 152 批时的历史快照为：全局 18,665 张中，267 张已应用、2,322 张保留、16,076 张待处理。当前累计及下一批以上方 P3 完成记录为准。没有后台生成或定时任务。

本轮逐张审查了 91 张原尺寸素材总览。小型像素精灵、服装碎片、细窄肢体与功能图层已有清楚色块；严格保留逐像素透明轮廓时，内部纹理不能消除像素边界，容易改变身份、衣物遮挡或物种细节。每张具体理由、原图/交付哈希见各批 `validation.json` 与 `jobs.json`。两个目录中的同编号图可能有不同姿态，已分别检查，没有把它们当作正背面配对。

内置 image_gen 的一份行走试制图改变了全部 16 格的边界与锚点，已拒绝；原图、生成图、完整提示词与验收记录保存在第 108 批及 [试制记录](p2-remaining-work/pilot-jobs.json)。妙蛙种子和小火龙各一次提案被内置工具拒绝，错误及提示词保留在第 116 批和 [第二份试制记录](p2-remaining-work/charmander-job.json)，没有切换外部 API。保留决定依据逐项原尺寸审查，未把生成失败写成生成成功或已应用。

## 本轮原生验证证据

- [验收汇总](p2-evidence/remaining/native-validation.json)：1,218 张来源全部解码并核对原图哈希；中英文标题/载入/全景 92 组显示，全景 204 个偏移检查包含完整宽/高重复位置。
- [人物叠穿](p2-evidence/remaining/player-review.json)：138 组肤色/服装/发型/帽子外观、15,456 个方向/动作/格位状态和 464 个冲浪/潜水底层状态。实际 Sprite_Player、Sprite_Wearable 与 Sprite_SurfBase 的裁切、偏移、叠层及回到 walk 的锚点一致；[原生叠穿预览](p2-evidence/remaining/native-layering-preview.png)。Game_Character 四个速度的循环为 20/10/16/8 次更新，40fps 标称 500/250/400/200ms；这是固定输入部件测试，不是完整地图动作事件流程。
- [战斗图与旧帧表](p2-evidence/remaining/battle-review.json)：470 个物种、940 组实际前后面指标/镜像、47,000 个选择浮动/目标闪烁状态，完整组合周期 24 次更新（40fps 标称 600ms）。另有 12 组代表闪光变色，未穷尽全部色变/形态组合。
- [训练师场景](p2-evidence/remaining/trainers-review.json)：121 张静态图通过实际 pbCreateTrainerFrontSprite 的显式图片覆盖接口显示在对手战斗坐标；9 张五格旧背面条图通过实际 PictureEx 投掷序列，帧序为 1→2→3→4→0。旧条图属于兼容资源；当前主角使用叠穿正面肖像。当前主角构建截图还在初始屏外位置，不能当作完整战斗入场验收。
- [最终恢复点复核](p2-evidence/remaining/checkpoint-verification.json)：全部 2,223 张 P2 的当前文件、原图备份、交付副本一致；111 张中文图片校验通过。补齐第 58～63 批早期只保存在 ready/ 的正式 delivery/ 副本，见 [档案补齐记录](p2-evidence/remaining/archive-repairs.json)。

每轮测试都通过 finally 停止本轮进程并清理临时日志/配置；原始大轨迹无损压缩为 `*-full.json.gz`，JSON 汇总保留解压后哈希及归档位置。必要原图、生成图和截图继续保留；未确认可从远程恢复的图片没有删除。清理详情见 [缓存记录](p2-evidence/remaining/periodic-cache-cleanup.json)。

此前已应用的 15 张及原生证据继续保留：[战斗 UI](p2-evidence/ui-native-validation.json)、[背包拒绝候选](p2-evidence/bag-native-validation.json)、[图鉴/仓库/命名](p2-evidence/dex/checkpoint-verification.json)、[地图与训练师卡](p2-evidence/region/checkpoint-verification.json)、[标题](p2-evidence/titles/native-validation.json)。早期文字说明保存在 [历史快照](p2-evidence/remaining/progress-before-completion.zh-CN.md)。

**完整游玩、全部地图/动作事件与场景切换、全部色变组合、Android 实机及最终发布包验证尚未完成。** 当前恢复点为 [p2-progress.json](p2-progress.json)、[p2-work/resume.json](p2-work/resume.json)及 [最终阶段记录](p2-remaining-work/resume.json)。特性分支为 `codex/texture-hd-p2`，本地提交回执在 `commit-receipt.json`；是否推送以该回执及远程查询为准。

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
