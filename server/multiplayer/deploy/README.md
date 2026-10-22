# 公网生产运行手册

默认域名：`if.pikastairs.cc`。本目录是待未来 Linux 主机使用的部署材料；本地验证不执行安装服务、DNS 修改或公网站点签发证书。

## 已实现的边界

- 生产 WSGI 入口复用现有 Store，Gunicorn 单 worker、4 线程、限连接，SQLite WAL/FULL。全局实例锁贯穿 worker 生命周期，禁止 preload、热重载及多 worker。
- 公网只有 Caddy 的 HTTPS 入口；应用绑定 `127.0.0.1:8765`，Caddy 覆写 `X-KIF-Client-IP`，后端只接受本机代理传来的单一合法 IP。认证计算有界且不持有游戏业务数据库锁。
- 数据库固定在 `/var/lib/kif-mmo`；独立 `/etc/kif-mmo/data-id` 与库内身份匹配，常规启动不自动新建生产库。配置独立数据盘时填写 `required_mount`，systemd 和应用同时检查。
- 代码、依赖、工具、数据库、证书和备份分开存放。服务以受限账号运行；Caddy 使用独立配置/状态目录，不修改其他站点。已有服务占用 80/443/2020 时，激活明确失败，需届时整合现有入口。
- Windows 和 Android 都在游戏菜单填写 `https://if.pikastairs.cc`，地址不包含 `/v1`。客户端目前的本机默认地址没有在本阶段强制覆盖；本次没有重新打 APK。

## 本地验证

Python 3.12+。官方工具缓存为 `temp/tools/multiplayer-production/`，本地测试使用已核验来源和校验和的 Caddy 2.11.7、Restic 0.19.1。工具缓存不进入 Git 或游戏包。

```powershell
python -m unittest discover -s server/multiplayer -p 'test_*.py'
python scripts/multiplayer/verify-production-local.py
python scripts/multiplayer/build-production-release.py
```

Windows 受限沙箱恢复原 NTFS ACL 时可能需要对这次本地测试授予作用域权限；不要修改全局沙箱或根证书信任。验证脚本只绑定回环地址，通过独立本地 CA 测试 TLS，关闭时停止自己创建的进程。`temp/multiplayer/production-local-*/result.json` 是脱敏结果；同目录的测试私钥、数据库、仓库密钥和密码文件不要发布。

Windows 上使用标准库 WSGI 测试宿主承载同一个生产适配器。Caddy/TLS、SQLite、Restic 和恢复都是真实运行；Linux Gunicorn、systemd 与 root 主机管理流程仍需在未来目标 Linux 主机上实际验收，不能将 shell 语法/配置检查表述为完成过 Linux 上线。

## 构建与部署包

`build-production-release.py` 只打包明确列出的服务模块、可信目录、部署模板和已锁定哈希的 wheel，不包含账号库、游戏存档、云备份凭据、用户文件或测试服务路由。产物为：

```text
temp/artifacts/kif-mmo-<git提交前12位>-<源码指纹前12位>.tar.gz
temp/artifacts/kif-mmo-<版本>.tar.gz.sha256
```

Gunicorn 26.2.0 与辅助依赖的 wheel 缓存须先按锁文件准备，缺失或哈希不匹配时构建失败。服务器 venv 用 `--no-index --require-hashes` 离线安装，发布目录保存 `release.json` 文件清单与内容哈希。

## 未来服务器准备（现在不执行）

目标为支持 systemd 的 Linux，Python 3.12+、venv、curl、coreutils、iproute2 和账户管理工具已就绪。把经过可信渠道核对 SHA256 的部署包及 sidecar 上传后，可从包中提取以下引导文件：

```bash
sha256sum --check kif-mmo-VERSION.tar.gz.sha256
mkdir -p bootstrap
tar -xzf kif-mmo-VERSION.tar.gz -C bootstrap \
  server/multiplayer/production_data.py \
  server/multiplayer/release_manager.py \
  server/multiplayer/deploy/manage.sh \
  server/multiplayer/deploy/install-tools.py \
  server/multiplayer/deploy/tools.lock.json
sudo python3 bootstrap/server/multiplayer/deploy/install-tools.py
sudo bash bootstrap/server/multiplayer/deploy/manage.sh setup "$PWD/kif-mmo-VERSION.tar.gz"
```

`install-tools.py` 从官方 HTTPS 发布位置下载固定校验和的 Linux amd64/arm64 工具，只写 `/opt/kif-mmo/tools`，不覆盖系统 Caddy/Restic，不启动服务。Caddy 官方此版本校验表使用 SHA512，Restic 使用 SHA256。

`setup` 验证并分阶段解包发布、建立离线 venv、创建受限账户和默认配置、安装 systemd 单元；不会启动服务、初始化数据库、创建远程仓库或改变 DNS。再次运行保留已有配置和备份密码。

然后按实际供应商配置：

- `/etc/kif-mmo/production.json`：默认域名、路径、必要的持久挂载。
- `/etc/kif-mmo/restic-repository`：例如 `s3:https://对象存储端点/专用bucket/kif-mmo`，或独立主机的 SFTP 仓库。默认 `UNCONFIGURED` 会阻止备份和激活。
- `/etc/kif-mmo/backup-credentials.json`：JSON 对象，可包含 `AWS_ACCESS_KEY_ID`、`AWS_SECRET_ACCESS_KEY`、`AWS_SESSION_TOKEN`、`AWS_REGION`、`AWS_DEFAULT_REGION`、`RESTIC_REST_USERNAME`、`RESTIC_REST_PASSWORD`。不执行 shell 内容；仅备份子进程读取，避免主游戏服务继承云凭据。
- `/etc/kif-mmo/restic-password`：setup 自动生成，root:kif-mmo 0640；在独立位置安全保管解密密钥及配置/data-id，否则主机全损后无法恢复。文件内容不会打印到日志。

生产配置默认拒绝本机文件仓库；只有隔离本地验证配置启用 `allow_local_repository`。不要把生产数据库或备份目录放在代码发布目录。

```bash
MANAGE=bootstrap/server/multiplayer/deploy/manage.sh
sudo bash "$MANAGE" init-db VERSION       # 显式创建新生产库与外部 data-id
# 若明确迁移旧本地测试库，改用 init-db VERSION /绝对路径/来源.sqlite3
sudo bash "$MANAGE" repo-init VERSION      # 显式初始化已选好的加密仓库
sudo bash "$MANAGE" activate VERSION
```

生产库、data-id 已存在时 `init-db` 拒绝覆盖。生产备份迁移到新主机时保留原 data-id，走恢复流程，不另行创建新身份。首次激活也要求已完成加密备份；准备失败不会绕过备份继续开放服务。

## 更新和代码回滚

```bash
sudo bash "$MANAGE" prepare /绝对路径/新部署包.tar.gz
sudo bash "$MANAGE" activate 新VERSION
sudo bash "$MANAGE" rollback 旧VERSION
```

激活先做加密备份，暂停旧应用，原子切换 `current` 代码链接，再检查后端并加载专用代理配置。健康检查失败时尽可能恢复先前兼容代码，数据库不随代码回滚。只管理 `kif-mmo-*` 单元，不停止其他网站。

当前支持的部署 schema 为 1。未来有数据库结构变更时，必须先增加明确迁移和兼容性检查，再使用本流程；不能盲目回滚到不兼容代码。重启会重新建立地图在线状态并结束无法继续的旧引擎会话，账号和云存档保留。

## 定时备份与恢复

`kif-mmo-backup.timer` 每 15 分钟运行：在线 SQLite Backup API → 关闭/转为单文件快照 → 完整性校验 → 版本/哈希清单 → Restic 加密上传 → 保存成功回执。本机只保留 current 和最近两份轮转快照，远端失败也不无限增长；成功时间不会因失败前移。

`kif-mmo-maintenance.timer` 每日保留近 24 小时全部点、30 个每日点、6 个月点并校验仓库。Restic 忘记快照后需 prune 才真正回收旧数据块，按维护窗口执行 `manage.sh repo-prune`；脚本暂停定时备份，完成后立即备份并恢复原计时器。维护窗口备份间隔可能延长。

`kif-mmo-monitor.timer` 每五分钟检查后端和最近成功的加密备份；失败或超过 30 分钟返回非零并体现在 systemd/journal。外部通知渠道待服务器运维环境确定后接入，本阶段没有发送消息或创建外部监控。

```bash
sudo bash "$MANAGE" backup
sudo bash "$MANAGE" status
# 以服务账号执行 production_ops.py snapshots 查询完整的 64 位快照 ID
sudo bash "$MANAGE" restore 完整快照ID
```

恢复先停备份调度、等现有任务完成并停止应用，再持有同一实例锁检查恢复包身份、schema、完整性与哈希。保留当前库的 `pre-restore-*` 副本，安全处理旧 WAL，原子替换恢复库。撤销旧会话与租约，设置大于旧库/恢复点的修订号栅栏，使客户端旧待上传数据明确冲突而非覆盖恢复点。玩家重新登录后恢复；冲突的本机进度保留供人工核对。

`pre-restore-*` 为人工恢复保险，不受常规三份快照轮转删除；确认恢复正确并完成异地备份后由运维另行归档/清理。恢复单个玩家不能用整库回档替代。脚本不会自动强制解锁仍在使用的 Restic 仓库或删除正在使用的 SQLite WAL。

## 交易与在线角色

交易版本要求 schema 4；旧数据库先停服并使用 `trading_admin.py migrate --backup` 完成整库备份和添加式迁移。市场、托管收藏与钱包可以独立运行。在线主线另需 Windows 完整游戏运行时，并为服务进程设置 `KIF_MAINLINE_GAME_ROOT`；本 Linux 发布包不包含原生游戏引擎。工作脚本取自当前服务器发布目录，游戏运行时数据和客户端构建清单必须匹配。详细步骤、隔离测试及未适配事件见 [交易中心与托管角色](../../../docs/multiplayer-trading-center.zh-CN.md)。

## 公网验收待办

收到服务器信息后再配置 DNS/防火墙、签发公信任证书、验证 Linux 服务生命周期及服务器重启持久化，并用 Windows 与 Android 的不同真实网络完成同服及跨端恢复。现有本地结果不能替代这些公网/实机检查。
