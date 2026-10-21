# 联机安装与启动

当前为Windows开发验证版，网络协议2，HTTP路径与精灵schema仍为v1。服务只需Python 3，无pip依赖。根目录保留项目已有Game.exe、DLL和资源。

## 构建与服务

在项目根目录的PowerShell执行：

```powershell
$python = (Get-Command python).Source
& $python scripts/multiplayer/build.py --check
& server/multiplayer/init-db.ps1 -PythonExecutable $python -Database temp/multiplayer/local-test.sqlite3
& server/multiplayer/start-local.ps1 -PythonExecutable $python -Database temp/multiplayer/local-test.sqlite3 -Port 8765
```

修改Data/Scripts、受校验数据或Mods后必须重新运行build.py；同时更新原生可信租借目录，不能手改摘要假装兼容。原生导出命令：

```powershell
& $python scripts/multiplayer/build.py
& scripts/multiplayer/start-client.ps1 -Profile catalog-export -CustomScript tests/multiplayer/rental_catalog_game.rb
```

等待该独立Game实际退出并核对RENTAL_CATALOG_PASS后再启动联机服务。数据库初始化及重复服务启动会取得同库进程锁；服务运行时不要用初始化脚本改库。旧协议未完成房间/副本会安全结束，已提交交易收据保留。

## 两个客户端

另开终端，分别启动独立身份与测试存档：

```powershell
& scripts/multiplayer/start-client.ps1 -Profile player-a -Server http://127.0.0.1:8765
& scripts/multiplayer/start-client.ps1 -Profile player-b -Server http://127.0.0.1:8765
```

游戏暂停菜单有“联机”入口。先连接身份，再创建/加入房间、展示、选队、准备和开始。其余入口包含Boss/副本、道馆/回放、交换/托管、租借/大厅。保存恢复码，勿公开凭据。正式交换前先选定并保存测试存档槽；原个体锁定期间用原身份、服务器及存档恢复，不删除journal或复制网络报价补原精灵。

默认只监听本机；不同设备须填写同一个可达服务器地址，localhost不指同一台机器。未部署公网。默认Game缺OpenSSL，HTTPS在发送前明确拒绝，不用原生HTTPLite绕过。Android/macOS/Linux及跨机器验收状态见cross-platform文档。

## 自动与真实游戏测试

```powershell
& $python -m unittest discover -s server/multiplayer -p 'test_*.py' -q
& scripts/multiplayer/test-all.ps1 -SkipService -RubyExecutable $env:KIF_RUBY
& scripts/multiplayer/run-dungeon-replay-test.ps1 -Port 19882 -TimeoutSeconds 900
& scripts/multiplayer/run-pool-restart-test.ps1 -Port 19885 -TimeoutSeconds 600
```

KIF_RUBY应指向自行安装的独立Ruby可执行程序。原生runner使用项目Game.exe，自建身份/数据库/存档并在结束时停止自身进程。池恢复测试首次客机在持久领取后故意退出1，最终两端必须退出0。普通启动期设置和角色存档必须先加载，再打开联机UI。

公开仓库只提供代码、测试和汇总结果；完整原始截图、日志、JSON运行记录保留本地，不随main发布。
