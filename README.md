# InfiniteFusionHD

[简体中文](README.md) | [English](README.en.md)

**继承 KIF FORK，聚焦高清画面与跨平台联网的 Pokémon Infinite Fusion 社区分支。**

InfiniteFusionHD is a fork of Kuray Infinite Fusion (KIF), focused on enhanced visuals and online play across Windows and Android.

本项目从 **KIF FORK（Kuray Infinite Fusion）** 继承而来，在其融合玩法、闪光配色、Mod 支持及便利功能的基础上，继续补充**素材高清化、联网玩法、Windows / Android 适配和简体中文支持**。KIF 原有功能属于上游贡献，本分支新增内容与实际完成范围见下文。

项目地址：[pikechu/InfiniteFusionHD](https://github.com/pikechu/InfiniteFusionHD) · [发布下载](https://github.com/pikechu/InfiniteFusionHD/releases) · [问题反馈](https://github.com/pikechu/InfiniteFusionHD/issues)

**开发状态（2026-10-27）**：账号、云存档、在线世界及下列休闲联机玩法已在 main 中；高清重绘、进一步的地图与加载修复、交易中心和运营后台仍在开发工作区，尚未合并到 main。发布包包含的实际内容以对应版本说明为准。

## 高清化：让融合世界更细腻

- **战斗背景细节重绘（开发中）**：开发工作区已应用四批共 **86 张素材**，包含全部 **70 张独立战斗背景**和 **16 张敌我地台**，覆盖昼夜户外、城市、洞穴、道馆与特殊场景。
- **保留原有构图与兼容性**：AI 辅助补绘纹理与细节，保留原文件名、宽高和透明通道，沿用原有场景布局与地台位置。
- **画面与移动修复（开发中）**：修正服饰、头发和帽子的遮挡及跟随问题，改善草丛显示、动作切换缓存和资源释放。
- **持续分批推进**：HD 表示本分支的视觉增强方向；当前仍使用原始素材尺寸与游戏基础分辨率，尚未完成全素材重绘。地图图块、界面、角色和动画等仍需逐批处理。

当前高清替换与渲染修复首先应用于开发工作区，尚未随 main 或客户端发布。它们不是全素材重绘完成或显示分辨率提升的声明。

## 联网：从单人融合冒险走向共同游玩

| 功能 | 本分支新增内容 |
| --- | --- |
| 账号与云存档 | 注册、登录、云端保存与跨端恢复；启动时选择在线或离线游玩 |
| 在线世界 | 主线地图玩家互见、地图聊天和世界聊天 |
| 好友对战 | 双人房间、选队、准备、好友单打与再战 |
| 合作与挑战 | 合作 Boss、异步玩家 AI 道馆、随机租借杯和固定路线合作副本 |
| 精灵交换 | 好友休闲交换、在线奇迹交换池与服务器托管收藏 |
| 社交与回放 | 训练师名片、六槽展柜、精灵展示与双方同意后的战斗回放分享 |
| 可部署服务端 | 协调服务、生产部署材料、备份与恢复工具 |

**开发中的扩展**：交易中心支持受控在线角色的精灵、道具及 GOLD 交易，包括挂牌、购买、待领取和交易记录；运营后台补充审计、统计与受控角色整档回滚。这些实现尚未合并到 main。

在线休闲玩法与开发中的服务器受控角色有各自的规则和资产边界；历史本地存档不会直接导入受控在线经济。云存档同步也不等于对本地资产来源的认证。

当前已有 Windows 与 Android 模拟器联测及分项验收记录；公网部署、实体手机体验、全地图自然通关和生产容量仍须独立验收。参与联网需要可用的同版本服务端，源码中的默认域名不代表公共服务已经开放。

使用及进度：[联机设置](docs/multiplayer-setup.zh-CN.md) · [账号、云存档与在线世界](docs/multiplayer-online-world.zh-CN.md) · [休闲交换与恢复](docs/multiplayer-trade-fields.zh-CN.md) · [服务端说明](server/multiplayer/README.zh-CN.md) · [部署说明](server/multiplayer/deploy/README.md)

## 其他补充

- **Windows / Android 双端**：Windows 客户端打包与 Android 独立应用，包含触控按键、键盘输入、画面比例设置、存档导入导出和可选 HTTPS 网络支持。
- **简体中文适配**：可切换语言、中文字体、剧情与常用界面翻译、中文融合名称和图鉴文本；保留社区翻译来源说明。覆盖范围与剩余内容见[汉化记录](docs/localization.zh-CN.md)。
- **图鉴与素材链路**：补充上游图鉴条目、图集支持及下载失败处理，改善可选网络资源不可用时的启动体验。见[图鉴更新](docs/pokedex-merge.zh-CN.md)与[图集支持](docs/spritesheets.zh-CN.md)。
- **加载与稳定性（开发中）**：继续改善 Android 首次资源安装、地图加载和角色动作缓存，修复本地地图与渲染问题；这些后续修复尚未合并到 main。

## 从 KIF FORK 继承的功能

以下能力来自 KIF 及其社区，本分支继续继承与维护：

- 融合宝可梦、自定义精灵立绘与融合图标。
- 多模式闪光配色、自定义闪光颜色与闪光缓存。
- `Mods` 文件夹加载与社区扩展支持。
- DemICE 的强化 AI、终局挑战与自我对战。
- 加速、自动战斗、多存档与备份、快捷存档和可配置经验 / 等级限制。
- 宝可梦导入导出、电脑箱排序与多选、个体立绘等便利功能。

完整上游功能清单与原作者署名保存在[KIF 上游 README](docs/upstream-KIF-README.md)。

## 下载与运行

1. 从 [InfiniteFusionHD Releases](https://github.com/pikechu/InfiniteFusionHD/releases) 获取对应平台的完整客户端；没有适用发布包时请按[客户端打包说明](docs/client-packaging.zh-CN.md)自行构建。
2. Windows 将完整客户端解压到可写目录，运行 `Game.exe`。源码 ZIP 不保证包含本地新增素材或完整可运行发布包。
3. Android 安装手机版本 APK；模拟器专用包仅用于模拟器测试。首次启动等待资源校验与安装完成。
4. 单人游玩可选择离线；联网时在游戏内设置与客户端兼容的服务端地址。

请独立安装本项目，不要覆盖安装到其他 PIF / KIF 游戏目录。改名后继续沿用既有存档位置、Android 包名 `org.kuray.kif`、原生接口和服务配置标识，便于兼容已有存档与同签名应用升级。Android 卸载会删除私有存档，迁移前请先导出。

开发入口：[Windows / Android 打包](docs/client-packaging.zh-CN.md) · [Android 工程](docs/android/README.md) · [联机进度](docs/multiplayer-progress.zh-CN.md)

## 项目来源与致谢

项目继承关系：**Pokémon Essentials → Pokémon Infinite Fusion（PIF）→ Kuray Infinite Fusion（KIF FORK）→ InfiniteFusionHD**。

- **KIF FORK / Kuray Infinite Fusion**：由 Kurayami Blackheart（Reïzod）及 KurayHub 社区开发。感谢 DemICE、Sylvi、Hungry Pickle、bluewuppo、Trapstarr 及其他代码、素材与测试贡献者。[上游仓库](https://github.com/kurayamiblackheart/kurayshinyrevamp) · [上游网站](https://www.kurayinfinitefusion.com/)
- **Pokémon Infinite Fusion**：由 Chardub / Frogman 及社区开发。[PIF 仓库](https://github.com/infinitefusion/infinitefusion-e18)
- **Pokémon Essentials**：感谢 Maruno 及所有引擎贡献者。[Essentials 仓库](https://github.com/Maruno17/pokemon-essentials)
- **社区美术与汉化**：精灵、音乐、图块及翻译的原作者署名继续保留于 `PIF_Credits.txt`、游戏内制作人员名单与 `Data/localization/source-notice.zh-CN.txt`。

InfiniteFusionHD 是在上述项目基础上继续开发的社区衍生分支。项目改名不改变上游作品、素材和社区贡献的归属；KIF 的网站及社区链接仅作为来源引用。
