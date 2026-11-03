# 完成前的历史快照（截至第 103 批）

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

