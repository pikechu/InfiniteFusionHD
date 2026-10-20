# KIF 统计：Matomo + 下载入口

统计后台复用 Matomo，自建代码只负责游戏埋点适配和下载跳转，不再实现统计数据库、用户系统或报表界面。默认游戏配置为关闭，仓库没有配置真实收集地址，也没有启动或公开部署服务。


本次独立提交可直接接入当前 Windows 主分支。Android Java 适配代码和协议测试一并提供；主分支尚无 Android 外壳及构建链，完整移动端接线以 [独立补丁与说明](../../android/ANALYTICS.md) 交付，待移植代码合入后应用。下面 Android 生命周期、机型和菜单说明均以完成该接线为前提。

## 选型（2026-10-20 核实）

| 模块 | 适用情况 | 本项目决定 |
| --- | --- | --- |
| [Matomo](https://github.com/matomo-org/matomo) | 自托管；有 HTTP Tracking API、下载统计、地区、设备、自定义维度和成熟报表；PHP + MariaDB/MySQL | 采用，已有后台可直接使用；[许可证为 GPL v3 或更新](https://matomo.org/licences/) |
| [Umami](https://docs.umami.is/docs/faq) | 可自托管，支持事件、地区、设备和产品分析；PostgreSQL | 可选，当前 v3 也支持 distinct ID 和留存等功能；本次不接入第二套协议 |
| [Countly](https://github.com/Countly/countly-server) | 面向移动端、桌面端，SDK、会话、设备和崩溃分析丰富 | 当前官方 README 将 Lite 描述为非商业许可，LICENSE 又列出 AGPL 及品牌附加条款；版本和用途需另行核实，本次不引入 |

Matomo 采用[官方 Docker Apache 示例](https://github.com/matomo-org/docker/blob/master/.examples/apache/compose.yml)的 MariaDB + Apache 方案；应用接入遵循[官方 HTTP Tracking API](https://developer.matomo.org/api-reference/tracking-api)。Umami 和 Countly 的比较依据上表官方文档，不以旧版功能或许可印象判断。

## 指标口径

| 指标 | 本实现含义 | 边界 |
| --- | --- | --- |
| 下载入口请求数 | 对 `/downloads/<key>` 的有效 GET，异步向独立 Downloads 站点记录 Matomo download action | 302 前只记录入口请求，无法确认下载完成；HEAD 不计；同人重试、机器人可能重复计；绕过入口的外链下载不计 |
| DAU | 独立 Game 站点在 Asia/Shanghai 自然日内的 Unique Visitors，标识为本机随机安装 ID；当天收到 `app_start` 或 `active` 即活跃 | 心跳不是新增用户；同机多存档共用 ID；跨设备、重装、删除状态或退出后重新启用会产生新 ID，不能代表去重自然人 |
| 新访客 | Matomo 按安装 ID 识别的新访客报表；客户端只发送 `app_start` / `active`，没有独立的 `first_open` 事件 | 与 APK/ZIP 下载量不同；删除状态会重新成为新访客，离线、退出统计、上报失败会漏计 |
| 手机型号/厂商 | Android `Build.MODEL` / `Build.MANUFACTURER`，通过自定义维度送出 | Windows 固定为 `desktop` / `unknown`，不查询电脑硬件型号；不是 IMEI、序列号或广告 ID |
| 玩家地区 | Matomo 通过请求 IP 和配置的 GeoIP 数据库推断国家/地区 | 无 GPS/定位权限；VPN、运营商出口、代理和 IP 掩码会影响准确度 |

Game 和 Downloads 必须创建为不同的 Matomo site_id，避免只点下载链接的人进入游戏 DAU。Matomo 的 [Unique Visitors 口径](https://matomo.org/faq/general/faq_43/)是所选周期内的访客去重；月活不能把每天 DAU 简单相加。没有可靠持久 ID 的历史版本和既有 GitHub archive/git fetch 不能追溯成准确 DAU/下载完成数。

## 本地启动后台

在已安装 Docker Engine / Docker Desktop 和 Compose 的环境操作；本任务未安装或启动 Docker。下面命令从仓库根目录执行，首次安装向导只绑定本机：

```powershell
Copy-Item server/analytics/.env.example server/analytics/.env
Copy-Item server/analytics/downloads.example.json server/analytics/downloads.json
# 编辑 .env，把两个数据库密码分别换成不同的长随机值。
docker compose --project-directory server/analytics -f server/analytics/compose.yml up -d db matomo
```

访问 `http://127.0.0.1:8081` 完成向导，数据库主机 `db`、数据库和用户 `matomo`，密码取 `.env`。创建管理员账号后添加两个站点：`KIF Game` 和 `KIF Downloads`，**两个站点时区均设为 `Asia/Shanghai`**。记录实际生成的 ID，不假设一定为 1、2。数据库和 Matomo 配置分别保存在命名卷 `db` / `matomo`；数据库没有公开端口。

要在公网使用，先完成安装并配置 HTTPS 反向代理和访问控制。Game 客户端 `endpoint` 必须是证书有效的公网 HTTPS `matomo.php` 地址；不能把容器内 `http://matomo/matomo.php` 发给客户端。Compose 默认端口只监听 `127.0.0.1`，不自动修改防火墙或发布安装向导。

在 Matomo 的 `config/config.ini.php` 中合并（不要覆盖已有配置）：

```ini
[Tracker]
trust_visitors_cookies = 1
```

游戏传入 `_id`，上述设置要求按该 ID 匹配，而不回退到相同 IP/设备特征，从而减少同一网络下两份安装被合并。参见[官方访客匹配说明](https://matomo.org/faq/general/faq_21418/)。客户端不携带 `token_auth`，不要为方便配置而把管理员或下载网关 token 写入游戏资源。

若后台启用了强制无 Cookie 跟踪（`forceCookielessTracking`），Matomo 会忽略 `_id`，安装级去重口径随之失效；此时应按实际后台设置重新解释 DAU，不能继续声称按安装去重。游戏本身不写浏览器 Cookie，`cookie=0` 与后台强制忽略访客标识是两个不同设置。实现依据见 [Matomo Request::getVisitorId 源码](https://github.com/matomo-org/matomo/blob/5.x-dev/core/Tracker/Request.php)。

## 游戏接入配置

编辑打包前的 `Data/analytics.json`：

```json
{
  "enabled": true,
  "endpoint": "https://stats.example.com/matomo.php",
  "site_id": 1,
  "app_url": "https://kif.invalid/game",
  "channel": "direct",
  "heartbeat_seconds": 300,
  "dimensions": {
    "platform": 1,
    "app_version": 2,
    "device_model": 3,
    "manufacturer": 4,
    "channel": 5
  }
}
```

把 `site_id` 替换为 Game 站点 ID；`app_url` 是统计中的固定游戏页面标识，无需实际提供网页。`endpoint` 必须可被玩家设备访问。`enabled` 是发行配置开关，关闭时不生成安装标识或发送事件。Windows 玩家通过 `Options > KIF Settings > Others > Usage Statistics` 退出，状态保存于本机独立 `analytics-state.json`；Android 玩家通过侧边 `Saves / Exit` 关闭游戏后，在存档管理页关闭 `Anonymous usage statistics`，设置及安装 ID 保存于应用私有 SharedPreferences。两个平台均不复用训练师名、好友码、存档 ID 或账号凭据，退出会清除本机随机 ID。Android 打包脚本会复制同一份配置，修改后须重新打包。

Windows 通过系统 PowerShell 的隐藏子进程和 WinHTTP 发送已验证证书的 HTTPS，请求正文走 stdin，不调用不安全的原生 HTTP。仅在该子进程传入 `-ExecutionPolicy Bypass` 运行随包提供的脚本，不改机器/用户执行策略或全局沙箱配置；若组织策略仍阻止执行，上报失败不会阻止游戏。Android 通过 Java HttpsURLConnection 发送，仅在游戏 Activity 位于前台时生成活跃事件；安装器、运行时探针和游戏 smoke 探针不计活跃。

在 Game 站点管理的 Custom Dimensions 中创建以下五个 **Visit scope** 维度，并启用。将实际获得的数字 ID 写入配置，不能只创建名字而不匹配 ID：

| 配置键 | 建议显示名 | 来源 |
| --- | --- | --- |
| `platform` | 平台 | windows / android |
| `app_version` | 游戏版本 | Windows `Settings::GAME_VERSION_NUMBER`；Android 包 `versionName` |
| `device_model` | 设备型号 | Android Build.MODEL；Windows 固定 `desktop` |
| `manufacturer` | 设备厂商 | Android Build.MANUFACTURER；Windows 固定 `unknown` |
| `channel` | 发行渠道 | 配置 channel，例如 direct / github / community |

Visit scope 适合设备和版本信息；创建方法与各 scope 含义见[官方自定义维度说明](https://matomo.org/faq/reporting-tools/create-track-and-manage-custom-dimensions/)。在 Game 的 Visitors > Overview 查看日 Unique Visitors，在自定义维度报表查看机型/渠道分布，Events 查看启动和活跃事件。测试发行包应使用独立测试站点，防止开发运行影响生产指标。

## 下载入口配置与启动

编辑 `server/analytics/downloads.json`，键只允许小写字母、数字、下划线和连字符，值为运维预设的 HTTPS 地址。仓库示例的 `windows` 指向当前 README 中的 release 源码 ZIP；Android 等其他包须由发布者填写实际可用地址，示例不虚构发行 APK。

```json
{
  "windows": "https://github.com/kurayamiblackheart/kurayshinyrevamp/archive/refs/heads/release.zip"
}
```

在 Matomo 创建仅对 Downloads 站点有写入权限的专用用户，生成该用户的认证 token，填入 `.env` 的 `MATOMO_DOWNLOAD_SITE_ID` 和 `MATOMO_DOWNLOAD_TOKEN_AUTH`。下载网关在服务端提交 `cip` 恢复访问者 IP，Matomo 要求此项有服务端 token 权限。token 仅留在服务端环境变量；不要放进下载链接、浏览器脚本、游戏配置或提交到 Git。

```powershell
docker compose --project-directory server/analytics -f server/analytics/compose.yml --profile downloads up -d --build downloads
```

本地入口为 `http://127.0.0.1:8082/downloads/windows`，健康检查为 `/health`。公网发布 HTTPS 下载域名后，把官网/公告实际下载按钮改为该入口；只部署网关但保留原按钮地址不会自动统计下载。修改 `downloads.json` 后重启 downloads 容器，启动时会检查全部配置，拒绝无效/重复键、非 HTTPS 下载地址、凭据 URL 和头注入字符。未知键、额外路径、查询字符串返回 404，不能用 URL 参数构成开放跳转。

跟踪在独立单线程中进行，最多排队 256 条，网络 timeout 为 2 秒，验证 TLS 并拒绝跟随跟踪端重定向。网关同步返回 302；Matomo 不可达、队列满、进程重启时允许丢统计，不延迟下载、重试重复计数或写本地统计数据库。公网高流量需在反向代理配置并发/请求速率限制。

默认忽略 `X-Forwarded-For`，只使用真实 socket 对端地址。反向代理部署时，仅把**可信代理实际连接网关的 IP**（例如 Docker 网络网关地址）逐一填入 `TRUSTED_PROXY_IPS`；不支持网段、不默认信任 localhost 之外的来源。必须在最外层代理清理或追加其已验证的访问链；网关从右向左跳过明确可信代理，取最后一个不可信地址作为访问者。错配会把代理算成玩家或允许伪造地区，先用测试站点核实后再接生产。

容器间跟踪默认显式设置 `MATOMO_ALLOW_INTERNAL_HTTP=1`，仅接受 `matomo` 服务名或回环 HTTP 地址；其他主机即使设置此项也要求 HTTPS。部署到另一台 Matomo 主机时使用 HTTPS 并设为 `0`。下载目标始终要求 HTTPS。

## 地区、隐私与运维

在 Matomo Administration > System > Geolocation 配置本地 DB-IP/GeoIP2 数据库和更新，依照[官方地区数据库配置](https://matomo.org/faq/how-to/faq_163/)。只靠语言不等于真实地区，本实现不传 GPS、经纬度或玩家自填家庭地址。

Matomo 自身位于反向代理后时，还须按[官方代理配置说明](https://matomo.org/faq/how-to-install/faq_98/)正确恢复客户端 IP 与 HTTPS 协议；这与下载网关的 `TRUSTED_PROXY_IPS` 是两处独立配置。只允许可信代理访问上游，并由代理覆盖客户端可伪造的转发头，按实际链路配置 `proxy_client_headers` / `proxy_ips`。先在测试站点确认不同网络的游戏请求没有全部显示成代理地址。若后台强制 HTTPS 导致内部 HTTP 收集地址重定向，网关应改用最终 HTTPS 地址；各采集器均拒绝跟随重定向。

上线前在 Privacy > Anonymize data 核实 IP 掩码，建议至少遮蔽最后两字节，开启使用掩码后 IP 做 GeoIP，并设置原始访客日志保留期限。掩码越强，城市和地区准确度越低；选择完整 IP 做定位意味着仍处理完整 IP。查看[官方隐私设置说明](https://matomo.org/faq/general/configure-privacy-settings-in-matomo/)。发行说明应告知安装级匿名 ID、平台/版本/型号/厂商/渠道、语言及近似地区用途，并给出游戏内退出入口。退出不等于删除已汇总的历史数据；历史原始记录的删除按后台保留/删除流程处理。

生产配置定时归档，例如使用宿主机计划任务定期执行以下命令；确认正常后再关闭 Matomo 的浏览器触发归档，见[官方 Docker 运维说明](https://matomo.org/faq/how-to-install/install-matomo-with-docker/)：

```powershell
docker compose --project-directory server/analytics -f server/analytics/compose.yml exec -T --user www-data matomo php /var/www/html/console core:archive --url=https://stats.example.com/
```

镜像标签跟随上游稳定渠道，实际生产发布应记录测试过的镜像 digest，按维护窗口升级。备份 MariaDB 的一致性备份以及 Matomo 卷中的配置、插件和 GeoIP 数据，恢复演练后再升级；不要用 `down -v` 清除持久卷。`.env` 和真实下载配置已在本目录 `.gitignore` 排除。

## 验证与尚未完成的验收

不访问任何真实统计服务器的本地网关测试（仓库根目录，Python 3.11+）：

```powershell
python -m unittest discover -s server/analytics -p 'test_*.py' -v
```

测试覆盖有效 GET 的 302 与事件、HEAD/健康检查/无效入口不跟踪、可信代理处理、队列容量、跟踪故障不影响跳转、配置校验和跟踪端禁止重定向。HTTPS 使用系统默认信任链，测试用注入传输和本地 mock，不关闭证书校验。

交付前还需要由实际部署环境完成：Compose 配置与镜像启动、Matomo 安装向导、TLS 证书、测试机启动与跨日活跃、同机多存档去重、机型维度、地区精度和退出后无新事件，以及真实官网按钮使用新入口。仓库级单元测试不能证明公网网络或 Matomo 报表已验收。
