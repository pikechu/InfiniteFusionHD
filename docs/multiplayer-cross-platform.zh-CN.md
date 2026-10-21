# 跨平台、多端同服核实（2026-10-20）

结论：**当前实际交付不能标为支持Windows与Android/macOS/Linux混合同服。** 协议与服务不按OS名称限制玩家，但现有Android产物尚不可联机；macOS/Linux没有实际游戏运行证据。跨平台模拟测试不等于不同平台实机验收。

| 组合 | 当前实现与证据 | 状态 |
| --- | --- | --- |
| Windows同机独立身份、多Game.exe | 协议2最终feef构建三Game综合117项通过、三个exit0；独立身份/数据库/存档 | 支持开发验证，完整人工菜单仍未验收 |
| 两台Windows电脑 | 地址/协议支持远端服务，但尚无两台设备LAN实测 | 未验收 |
| Windows与Android | 当前APK没有联机模块；生产adapter未注册、应用未申请网络权限 | 当前不可用 |
| Windows与macOS/Linux | Ruby协议/Socket实现有可复用部分，未找到本项目可运行发行包与设备验收 | 未确认支持 |
| Android彼此同服 | 同样受当前APK与网络能力阻断 | 当前不可用 |

## Android的已核实阻断

1. `android/app/src/main/AndroidManifest.xml` 明确暂不申请 `android.permission.INTERNET`，并设置 `usesCleartextTraffic=false`。这些是现有Android工作的配置，不能仅修改一个开关就称已实现安全联网。
2. `Data/Scripts/000_Platform.rb` 提供 `install_http_adapter`，生产源码没有调用注册；仅平台契约测试安装mock。`015_Transport.rb`在Android走平台适配器，缺失时在写业务pending之前拒绝，未退回不安全的HTTPLite。
3. 实际检查 `temp/artifacts/KIF-0.20.7-android.1-arm64-test.apk`（838985813字节）：payload `1d8ff4bcc03686ae10886d64`，其中 `Data/Scripts/054_Multiplayer` 文件数为0，也没有 `Data/multiplayer-build.json`。APK中的manifest SHA256为 `5268dec11d13488189b897b9eaa10654fb16fb6b6abb953ac1bc28bb872e918e`。当前Windows源码已新增联机，不代表之前打出的APK自动包含它。
4. `scripts/android/package_game.py` 的重打包入口会收集Data等目录，但当前已签产物没有更新；Mods目录也不在该源集合。将来要核对实际运行的双方源码/编译数据/规则/受支持Mods，而非手改摘要使不同构建混入同一场。

只读ADB检查：emulator-5554虽列为在线，但未完成启动、package服务不可用；5556离线。因此本轮没有安装、重启或操作Android应用，也没有把历史Android单机runtime smoke记为联网通过。历史Ruby3.4.10/OpenSSL smoke与WindowsRuby3.1.3的运行证据是两类结果。

## 协议可以复用的部分

协议2的兼容信息绑定 `protocol/game_version/data_hash/mods_hash/rules_version`，没有OS名称白名单。网络传输为有界UTF-8 JSON，精灵由明确字段构建，跨端不传Marshal对象；房主单一引擎计算，访客应用权威结果，不要求两端不同Ruby的随机数生成器同种子运行一致。

相同内容摘要只是必要条件。平台preload、引擎版本、资源查找、Ruby能力、输入和原子存档必须分别验证；不能删除检查或直接把Android视为Windows。默认Windows原生运行时缺OpenSSL，HTTPS明确拒绝；Android具有某项TLS库也不等于已经注册可用的联机adapter。

各终端须配置同一可达服务器；各自的localhost不是同一机器。好友同服按每端独立身份使用。同一身份的恢复码登录会轮换token；本轮权威绑定还禁止两个内存引擎同时结算同一场，不提供多设备并行账号会话或引擎迁移。

## 已执行验证与后续门槛

`tests/multiplayer/cross_platform_test.rb` **25/25通过、退出码0**，明确输出 `MOCKS_ONLY/NOT_DEVICE_ACCEPTANCE`：验证缺adapter发送前拒绝且不污染交易journal、显式mock的JSON/Auth/request_id传递、相同内容在模拟平台标志下兼容信息相同，以及修改代码被拒绝。它没有启动Android/macOS/Linux游戏。

APK及源码核实汇总为 `temp/multiplayer/cr-20261020/cross-platform-audit.json`。Windows本轮真实游戏验收见主测试报告。

跨平台启用仍需：重新打包完整联机代码与真实构建清单；实现并注册验证证书/主机名的Android联网能力和明确的开发HTTP策略；在可运行设备上，用不同身份完成房间、展示、选队、战斗/再战、断线恢复和交易保存后重启领取。保持Android保存目录与Windows原存档隔离，分别记录原文件SHA和唯一结果。当前未将这些工作标为通过。
