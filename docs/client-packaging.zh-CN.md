# Windows 与 Android 客户端打包

以干净的 main 提交构建。先通过 `scripts/multiplayer/build.py --check`，并保证服务端租借目录的兼容信息匹配。不要把其他工作区未提交的脚本或存档拷入产物。

Windows：运行 `python scripts/windows/build_release.py`。脚本直接导出指定 Git 提交中的游戏资源、Ruby 源码、现有 Game.exe、运行库与配置，生成完整 ZIP、SHA256 和构建摘要。它校验所有联机构建输入、ZIP 完整性，排除开发目录、存档、数据库、日志和系统缩略图缓存。Windows 原生引擎沿用项目附带版本。解压到可写目录后启动 Game.exe，存档沿用游戏的独立保存目录。

Android：使用同一提交的资源根目录运行 `python scripts/android/build_apk.py --with-network --asset-root <资源目录>`，先通过 `scripts/android/build_bridge.ps1` 重建 JNI 桥。Android.10 沿用现有本地测试签名及包名，可覆盖同签名旧包；不要卸载或清理应用数据。模拟器专用包追加 `--emulator-compatible`，不能作为实体手机包使用。打包后检查签名、版本号、网络权限及内嵌 payload 源码摘要。

两端通过游戏内服务器设置连接同一个服务。公网 `if.pikastairs.cc` 尚未部署，打包不改变默认服务器地址。新产物的构建校验不能替代实体设备或公网双端验收。

清理构建缓存前先核对完整路径，避开 Git 工作区、存档、签名密钥、工具链、素材原件和测试证据。保留新产物、构建摘要和当前所需输入，只清理可重新生成的中间包、编译输出、Python 字节码及下载的临时解压目录。
