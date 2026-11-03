# Android.13 主分支集成

2026-10-26，将 origin/main `6b25342b` 的 36 个提交快进合入 `codex/admin-operations`，保留本地后台、受控角色、商店、交易及地图表现修复。主分支包含简体中文、图鉴文本、U02–U09 道具/战斗/存档/素材缓存修复，以及已有 Android 和联机改进。

合并前备份位于 `temp/pre-main-20261026-141514`，534 个文件；对应 Git stash 保留。重叠的历史文档采用主分支更新版本，原件留在备份中。没有推送远端或部署服务器。

合并时同时保留两套 Android 主机测试入口，重新生成联机兼容清单和原生租借目录。回归发现受控服务端的精灵名称依赖 `GameLanguage`，已将 `001_Technical/004_Language.rb` 加入原生规则加载清单，修复领取初始精灵和后续交易流程中的缺失常量异常。

完整重建资源而非仅替换 Ruby：23,239 个逻辑文件，20,940 个归档实体，恢复大小 995,698,585 字节。主分支变化涉及的 55 个游戏文件逐项验证内容摘要。

- 手机包：`temp/main13-apk/KIF-0.20.7-android.13-arm64-network-test.apk`，752,646,448 字节。
- 手机 SHA256：`e60a402b59da0cc222f5db716571e03c953ce5cdb1ffb77d690bdecd1adef788`。
- 模拟器包：`temp/main13-apk/KIF-0.20.7-android.13-arm64-emulator-network-test.apk`。
- 模拟器 SHA256：`8cded08d2b92629c3f3f9426e95b91dcd945496100fbddbcd7e19149a80e6f4d`。
- 共用 payload：`e690bd11b25f6379be391511`。签名、原生运行库固定摘要、源码一致性和资源库存校验通过。

Windows 原生 U02–U09、中文菜单切换、屋顶遮挡、换装缓存、两座城镇移动与门事件、租借目录导出通过。Android 主机检查、11 项资源打包测试、中文/图鉴/统计测试及联机客户端测试通过。

详细日志在 `temp/main13-*.log`，构建记录与资源核验清单在 `temp/main13-apk/`。缺失语言模块引起的 11 项受控角色/交易失败均已单独复测通过（`main13-fixed-tests.log` 和 `main13-trade-fixed.log`）。

专用模拟器 `kif_original_20261023` 成功更新安装 Android.13；启动发生系统进程 attach 超时，随后 System UI 无响应。已保留 `temp/main13-device-final.log` 和 `temp/main13-install-screen.png`，并停止本次专用模拟器。尝试预置同包资源后仍未取得正式安装完成标记，因此本次新包的设备内资源恢复和地图验收未完成，不能将 Windows 或 Android.12 的结果算作 Android.13 设备验收。现有用户模拟器 5558 未被停止或修改。

手机真机验收仍未完成。新 APK 尚未上传 Google Drive，旧下载链接仍指向旧版。

额外的后台全量发现式回归未完成：发布包测试在 `atomic_bytes` 文件持久化阶段耗时较长，已停止本次扩展测试并保留诊断。此前发现的 11 项语言依赖失败均已修复复测；本记录不声称整套后台测试全绿。Windows 符号链接激活检查因令牌权限跳过。APK 签名、资源、客户端、中文及 U02–U09 与地图 Windows 回归均已独立完成。
