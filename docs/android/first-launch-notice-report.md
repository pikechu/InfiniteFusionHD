# Android.6 空 Ruby 存档首次说明验证

2026-10-20，在独占的 `emulator-5554` 上实际完成。包为 `org.kuray.kif`，版本 `0.20.7-android.6` / code 6，API 30 x86_64 AVD，活动 payload 为 `be6a7f326cb7e1e0ea4ce30e`。本轮按 `temp/evidence/empty-saves-preparation/PROCEDURE.md` 执行并采用当前 .6 payload；证据位于 `temp/evidence/first-notice6/`。

## 前置与原件保护

- 停止整个包，核实 Launcher 与 `:game` 两个 PID 均为空；UID 10167 与安装包一致，canonical 根为 `/data/user/0/org.kuray.kif/files`。
- 001/003 的完整 TAR、逐文件字节数和 SHA-256 与上一轮 `root-android6/154-final-saves.json` 的最新 **30 文件**完全一致。H/G/F 哨兵及 E `452152fd…`、D `43d55309…` 均一致，未采用旧 26 文件基线。
- 检查 saves/backups 是真实目录且递归无链接或特殊文件；无 SAF 事务，可加载 Mods 为空，活动 CWD 无 `kif-gui-*` 标记。
- 使用唯一 token `27997adf6df7433aaa641b96c282f260`，exclusive mkdir 取得私有互斥 marker，保存 owner、manifest SHA、payload、fingerprint 与 phase。
- 仅在同一个 canonical 私有 files 根内，把整个原 saves 目录 rename 到 marker/original-saves，再 exclusive mkdir 空 saves。005 对 held 原件重新 TAR/哈希，完整 30 文件和 backups 仍一致。

## 实际 GUI 结果

正常 MAIN/LAUNCHER 入口启动，无 smoke extra、Ruby 注入或 972 修改。011 菜单只有 New Game 等选项，没有 Continue。

选择 New Game 后，实际虚拟 C 阅读以下两个说明消息：

1. `KIF Android Test is an independent test port. This APK is not an official upstream release.`（013 和滚动后的 015）
2. `Obtain builds from a source you trust. Your adventure will now continue.`（016）

继续后，018 实际进入 **TRAINER APPLICATION FORM** 人物创建界面，显示姓名、性别、年龄、外观和 Confirm，证明说明事件正常返回父流程。未输入姓名、未选择 Confirm、未创建或保存新档，未扩展新手剧情。

## 恢复与结束状态

到达人物创建后停止整个包，记录双 PID 为空；020 完整采集本次临时 saves/backups，文件数为 0。022 再次核验 held 原始 30 文件完全一致后，将当前测试 saves 整目录 rename 为 marker/first-run-saves，再将原件目录 rename 回 files/saves，未删除、复制覆盖或合并原存档。

**024-restored-original30.tar/json** 与测试前 001 及上一轮最新 154 的全部 30 文件逐路径、数量、字节数和 SHA-256 完全一致，backups 同样一致。验证成功后写 phase=restored，并将整个 marker 保留为：

`files/.kif-empty-saves-qa-v1.completed-27997adf6df7433aaa641b96c282f260`

其中保留 owner、阶段记录和完整 first-run-saves 目录。026 确认 Launcher / `:game` 两个 PID 均为空；**027-final-result.json** 记录原 30 完整恢复、TAR 校验和 backups 一致结果。最终停在整个包已关闭的安全状态，ADB 已交还。

本轮仅验证“已安装 Android.6、保留素材/缓存及 SDL 原生偏好、临时移走全部 Ruby saves”的首次存档事件路径，**不等价于全新安装或清除全部数据测试**。未卸载、清数据、改游戏脚本或存档字节，未运行更新器，未读取 Windows 玩家存档。
