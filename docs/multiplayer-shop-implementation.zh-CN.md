**在线商城实现与验证记录**

日期：2026-10-22。特性分支：`codex/online-shop`。对应方案：`multiplayer-shop-plan.zh-CN.md`。

**已实现的范围**

实现了方案 B 阶段的官方商城、C 阶段的展示与活动功能，以及 D 阶段的服务器托管交易所。真实支付没有接入。改名、付费容量、背饰和坐骑、主线权威经济等原方案的「独立评估」项目没有作为已经实现的功能交付。

| 部分 | 实际行为 |
| --- | --- |
| 游戏入口 | 在线暂停菜单新增商城；联机菜单提供相同入口，离线不展示商城购买入口 |
| 商品目录 | 23 个 SKU：12 件织纹外观、4 个去重套装、6 件名片／称号／主题装饰、1 个限时活动套装 |
| 素材 | 新增 68 张确定性生成的精灵图，保留所有原有免费资源；目录记录每张素材的 SHA256 |
| 商城交互 | 分类、分页、商品详情、四方向行走预览、组合试穿、确认购买、立即装备、已购装扮和恢复原外观 |
| 账号钱包 | 服务器 RP 钱包；主线金钱不进入商城；余额和流水独立于云存档 |
| 点券获取 | 服务端验证的绑定／限次／过期兑换码，以及有原因和事件编号的运营发放 |
| 购买恢复 | 固定请求编号与客户端日志，订单和权益在一次事务提交；响应丢失查询原回执；清理通用操作日志后仍有永久业务去重 |
| 装备同步 | 服务端核验拥有权，使用原有分层服装系统；地图广播受验证的外观资源，同地图渲染和移动同步 |
| 名片装饰 | 服务器公开投影仅包含当前有效的边框和称号，名片头像上绘制对应装饰 |
| 活动和套装 | 上下架、起止时间、账号名单灰度、库存与永久权益去重；套装按未拥有内容计算优惠价 |
| 查询与管理 | 分页订单、余额明细；暂停购买／装备；运营发放、兑换码、商品控制和退款冲正，保留审计 |
| 托管交易所 | 搜索、价格排序、分页、挂牌、撤单、到期、购买、我的挂牌和交易历史 |
| 交易经济 | 独立的 MARKET 钱包；仅运营可信发行，不接受本地金钱充值；成交在同一事务完成买卖双方记账和资产转移 |
| 资产边界 | 只允许服务器托管收藏资产，复用好友交换和交换池的资产锁；不把购买的收藏精灵注入主线队伍 |
| 打包 | 商城 JSON 和 PNG 同时进入兼容清单与 Android payload；支持独立构建目录和输出目录 |

首发资源是对现有精灵图系统的专属织纹和配色扩展。生成器为 `scripts/multiplayer/build-shop-assets.py`，商品目录为 `Data/shop/catalog.json`。首发都是永久账号权益，不引入物品背包的跨存档发放事务。

**核心实现位置**

| 文件 | 职责 |
| --- | --- |
| `server/multiplayer/shop.py` | 钱包、账本、订单、权益、装备、兑换码、运营操作与托管交易所 |
| `server/multiplayer/shop_admin.py` | 本地管理与对账命令，不向游戏客户端提供增发接口 |
| `Data/Scripts/054_Multiplayer/021_Shop.rb` | 客户端数据验证、购买和装备、异步账号权益恢复 |
| `Data/Scripts/054_Multiplayer/022_ShopScene.rb` | 商城界面、试穿、键盘／点击操作、订单和钱包入口 |
| `Data/Scripts/054_Multiplayer/023_ShopWorld.rb` | 远端分层外观与名片装饰渲染 |
| `Data/Scripts/054_Multiplayer/024_Market.rb` | 服务器托管交易所界面 |
| `scripts/multiplayer/run-shop-world-test.py` | 独立数据库及账号的 Windows／Android 原生流程验证 |
| `tests/multiplayer/shop_world_game.rb` | 在真实 Game／Android Ruby 引擎中驱动生产客户端、界面和渲染 |
| `server/multiplayer/test_shop.py` | 商城专项事务、权限、异常恢复、分页和交易所测试 |

现有 `service.py`、`online.py`、`backend_v3.py`、兼容清单生成器与打包器增加了对应集成。租借目录在最终源码下由真实 Game 重新导出并验证了 12 只候选，避免新增商城源码导致旧租借目录兼容指纹过期。

**使用与运营**

在线登录后打开暂停菜单的「商城」。首版新账号余额为零，可在「我的 → 兑换点券码」领取服务器活动点券，购买后可立即装备。同账号跨设备继续使用现有在线单写入租约，需先退出原设备。

离线运营工具要求停止服务后操作指定数据库，沿用数据库实例锁。通过私密 JSON 文件提供参数，不在命令行或日志里传入完整兑换码。示例：

```powershell
python server/multiplayer/shop_admin.py --database <测试或正式数据库路径> --actor operator --reference activity-001 --action credit --data-file <私密参数文件>
```

发放参数包含 `owner,currency,amount,reason`。`currency` 可为 `RP` 或 `MARKET`，账号使用服务端身份 ID。相同操作者、动作和事件编号重复执行不会再次入账，内容不一致则拒绝。

创建兑换码使用 `--action code`，参数为 `code,currency,amount,expires,maximum,batch`，可选 `target` 绑定账号。`expires` 是 UTC Unix 时间戳。代码只以摘要写入兑换码表和审计。

控制商品使用 `--action control`，参数为 `key,value`。`key` 可为 `paused`、`equipment_paused` 或 `sku:<商品编号>`；商品控制值支持 `enabled,price,starts_at,ends_at,stock,audience`。退款使用 `--action refund` 和 `order_id,reason`，保留原订单与流水并写入冲正，撤销该订单发放的权益。

`--action audit` 校验钱包余额与账本合计。所有经济表、订单、权益与业务去重必须随同一个数据库备份／恢复，不能单独恢复余额表。

**已完成的原生验证**

| 验证 | 证据与结果 |
| --- | --- |
| Windows 原生多进程 | `temp/multiplayer/shop-native-b666969739/result.json`，通过 |
| Windows + Android 原生联合流程 | `docs/multiplayer-evidence/2026-10-22-shop/mixed-result.json`，通过 |
| Android 素材与源码 | 校验安装 APK SHA256、payload ID 和所有商城／联机模块及新素材的实际设备 SHA256 |
| Android 购买端 | 27 条原生 PASS 记录，包括兑换码、响应丢失恢复、重复购买拒绝、套装计价、详情确认购买并装备、移动互见和交易所 |
| Windows 购买端 | 26 条原生 PASS 记录，覆盖相同主要路径及卖家资产、到账验证 |
| Android 恢复 Windows 账号 | 6 条 PASS：余额、权益、整套装备、装饰和唯一订单跨设备恢复 |
| Windows 恢复 Android 账号 | 6 条 PASS，确认反方向恢复 |
| 商城专项服务测试 | 19 项通过：并发、扣款后失败回滚、长期去重、限购、资源及价格版本、兑换码限速、退款、公开投影、挂牌锁、分页和权限 |
| 现有 Ruby 回归 | 26 组通过，覆盖身份、联机战斗、交换、收藏、名片、传输、在线模式和 Android 网络契约 |
| 完整服务回归 | 最终运行 222 项：221 项通过、1 项条件跳过；包含本次商城与当前后台管理集成 |

联合流程使用 Windows Ruby 3.1.3 与 Android Ruby 3.4.10；运行真实生产类和渲染器，UI 确认选择由诊断脚本驱动，并调用生产点击命中逻辑。它不是人工逐菜单点击验收，也不代表物理手机、公网或跨机器局域网已经验收。

数据库只读审计结果：两个账号各完成 6 笔商城购买，共 12 笔订单、14 份有效权益和 2 次兑换；RP 余额各为 2130。托管交易后 MARKET 余额为 3200／2800，原收藏资产只有 2 份，挂牌最终为一笔已成交、一笔已撤回。所有钱包余额均与流水合计一致。具体记录见 `docs/multiplayer-evidence/2026-10-22-shop/validation.json`。

已实际检查商城页面、名片装饰、地图互见和恢复后的截图。Android 页面截图为 `docs/multiplayer-evidence/2026-10-22-shop/android-guest-shop-catalog.png`。

**构建产物**

| 产物 | 位置与验证范围 |
| --- | --- |
| Android ARM64 测试 APK | `temp/artifacts/shop/KIF-0.20.7-android.9-arm64-network-test.apk`；已构建和签名验证，未在物理手机执行 |
| Android 模拟器测试 APK | `temp/artifacts/shop/KIF-0.20.7-android.9-arm64-emulator-network-test.apk`；在本轮独立 API 30 模拟器运行通过，不能作为物理手机包使用 |

两个产物的 Ruby／资源 payload 相同：`e5c8248698bb7c6e00db7919`。普通 ARM64 APK SHA256 为 `57be0f823b8d7c09d924134fbfae475efadc363889304dcb2dd1439af085bd5e`，模拟器 APK SHA256 为 `1d1ada68fca0701d4c7f8bbeea289c9d9fdc5bbf22437a75ffb2e461630c1296`。构建记录和校验文件与 APK 放在同一目录。

**失败记录与后续核对**

开发验证中发现并修复了兼容清单未纳入商城素材、原生 Digest 不提供 `.file` 辅助方法、测试预览未裁切单帧以及地图地名遮盖商城标题的问题。相关旧失败日志保留在 `temp/multiplayer/shop-native-*`。

首次 Android 安装在产物重新签名期间发生校验失败；待签名完成后，以 `--no-incremental` 安装成功。最终联合验证核对的是上述固定 SHA256 对应的完整 APK。

完整服务回归的首次结果为 214 项，其中 1 项名片字段断言失败、1 项备份恢复环境错误、1 项条件跳过。名片断言已按装饰字段更新并单独复测通过。备份错误已定位到沙箱拒绝 Restic 写入测试文件的 Windows 安全描述符，未放宽生产备份规则；该备份恢复测试在限定权限下单独复测通过。最终全量回归共 222 项，221 项通过、1 项条件跳过，日志为 `docs/multiplayer-evidence/2026-10-22-shop/server-regression-final.log`。最后补充验证了运营修改套装总价时，未拥有内容的实际计价同步变化，商城 19 项专项再次通过。

共享工作区同时存在其他功能开发；商城结果另附独立工作区，避免后台任务切换共享分支。工作区源码和测试所用文件按兼容清单核对，原工作区的改动保留。

本记录中 `temp/` 开头的原始验证和 APK 路径位于 `D:/others/kurayshinyrevamp`。独立商城工作区已保存对应源码和 `docs/multiplayer-evidence/2026-10-22-shop/` 下的完整证据副本。

最终补测：云会话租约过期且通用操作日志已清理后，已提交订单和挂牌仍能读取原业务回执，余额不会再次变化；新的消费仍拒绝无效租约。商城专项最终 19 项通过，日志为 `docs/multiplayer-evidence/2026-10-22-shop/shop-focused-final.log`。

独立商城工作区迁入后又运行了四个 Windows 原生进程，购买、换装、同步和新进程恢复全部通过，结果为 `docs/multiplayer-evidence/2026-10-22-shop/relocated-windows-result.json`。
