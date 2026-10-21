# Android HTTPS 实机运行栈验证（模拟器）

2026-10-16，Asia/Shanghai。本次在独立 `kif_network` / `emulator-5556`
完成 **11 / 11 项真实联网检查**。没有操作正在进行游戏验收的 `emulator-5554`。
测试走实际 Ruby 3.4.10 → 自建 ARM64 JNI 桥 → Android Java HTTPS → 网络连接，
没有用 mock 代替 TLS、HTTP 响应或超时。

这是不含完整游戏素材的小型网络验证 APK，不能替代完整游戏 APK 或剧情验收。

## 精确产物和环境

- APK：`temp/artifacts/KIF-network-probe-arm64-test.apk`，25,868,525 bytes。
- APK SHA-256：`e752858a511988bd4ebfb0e68e0bdabfb18e787d6bf725f02850d78b775e03f0`。
- `org.kuray.kif`，`0.20.7-android.1`，min API 30 / target 35；测试签名，本地交付。
- Android 11/API 30 Google APIs x86_64 r16；`libndk_translation.so` 运行 ARM64 原生库。
- Fingerprint：`google/sdk_gphone_x86_64/generic_x86_64_arm64:11/RSR1.240422.006/12134477:userdebug/dev-keys`。
- 页大小 4096 bytes，AVD 2 核 / 2048 MiB RAM，720×1280 显示旋转为横屏，WHPX + SwiftShader。
- Ruby `3.4.10`；运行时自报 `2.4.2/59cd2ca7`。上游原生运行时仍是固定发布产物，
  **未完成整套 Ruby/OpenSSL/SDL/mkxp 源码重建**；新增 JNI 小桥已独立从源码构建。
- 新 AVD 首次 boot 完成：340,332 ms；安装前确认 `sys.boot_completed=1` 和 CE storage 可用。

## 真实检查结果

用例运行于中国时间 18:29:03–18:29:33。下表时间由游戏进程的单调时钟测得。

| 检查 | 实际结果 | 耗时 |
| --- | --- | --- |
| 桥 JSON / UTF-8 / 请求边界 | Ruby 返回字符串为有效 UTF-8；Java 正确返回不支持方法的 ProtocolException；65,537-byte 请求被原生 64 KiB 边界拒绝 | 0.111 s |
| 可信 HTTPS PNG / 二进制 | 从真实 GitHub Raw 获取 1679 bytes，PNG 288×288，实际 `Bitmap.new` 解码尺寸一致 | 1.499 s |
| UTF-8 POST echo | 将 `KIF-UTF8-测试-🌈` 发到真实 HTTPS echo 服务，返回字节完全一致 | 1.410 s |
| HTTP 404 | 真实缺失 GitHub 路径返回 404，未误报 200 | 0.432 s |
| HTTP 拒绝 | 直接调用 JNI/Java，HTTP URL 返回 ProtocolException；本地 HTTP fixture 收到该路径请求数为 0 | 0.012 s |
| 自签证书拒绝 | Android 返回 SSLHandshakeException；本地 TLS 服务记录 `certificate unknown` alert，未收到 HTTP 请求 | 3.400 s |
| GET 重定向 | 真实 `/redirect/1` 到达 `/get`，最终 200 | 0.955 s |
| POST 307 不重放 | 真实 POST redirect endpoint 返回原始 307，未跟随成 `/post` 的 200 | 0.317 s |
| 无效域名 | `.invalid` 域名返回 UnknownHostException，空失败 body | 0.375 s |
| 真实阻塞 TLS 总期限 | 本地 TCP 服务接收真实 TLS ClientHello 后不回 ServerHello；请求在 20.005 s 返回 TimeoutException | 20.005 s |
| 超时后恢复 | 下一次可信 HTTPS PNG 成功 | 0.175 s |

公开测试资源：

- [GitHub Raw PNG](https://raw.githubusercontent.com/pikechu/kurayshinyrevamp/main/Graphics/BaseSprites/1.png)
- [POST echo](https://httpbingo.org/post)、[GET redirect](https://httpbingo.org/redirect/1)、[POST 307 fixture](https://httpbingo.org/redirect-to?url=%2Fpost&status_code=307)

没有发送玩家存档、帐号、认证 header 或交易内容。POST 仅包含上述测试字符串。
服务端 PNG 位于可变 `main`，本次记录其实际哈希用于逐字节比对，不把 URL 名称当完整性证据。

## TLS、取消和二进制证据

下载 PNG 的 Android 文件和宿主独立 HTTPS 下载文件的 SHA-256 完全一致：

`3244808d106425bc62ebb6363b624fc95a32464fe4d62184e6c755434067feb5`

本地 fixture 只绑定 `127.0.0.1`，通过模拟器 `10.0.2.2` 访问：

- 8443：新生成、自签、SAN 含 `10.0.2.2` 的证书；未向模拟器安装证书或 CA。
- 8444：真正的 TCP 连接，接收 ClientHello 后不回复 TLS 数据。
- 8445：用于证明 HTTP URL 在发送前被拒绝。

服务器记录一次证书握手拒绝。阻塞 TLS 用例发生两次 GET 尝试，客户端分别在
10.015 s 和 9.735 s 关闭 socket；总调用仍受同一 20 s Future 期限约束。
随后新的 HTTPS 请求成功，未将两个 worker 长期占住。宿主服务和客户端均保留真实日志。
私钥仅在 `temp/network-fixture`，没有进入源码、APK、报告或分享的证据文件。

## 证据位置和观察

- `temp/evidence/20261016-183037-network-first/`：完整 logcat、设备信息、内存、activity、首次截图。
- `temp/evidence/network-verified/android-network-smoke.json`：游戏进程写出的 11 项结果。
- `temp/evidence/network-verified/validation.json`：APK 哈希、结果计数、fixture 连接计数。
- `temp/evidence/network-verified/downloaded.png`、`png-integrity.json`：真实下载和完整性比对。
- `temp/evidence/network-verified/fixture-events.jsonl`、`fixture-ready.json`：真实服务器记录及证书指纹。
- `temp/evidence/network-verified/screen-after-wait.png`：完成界面，11 PASS / 0 FAIL。

采集时游戏进程 PSS 117,410 KiB，RSS 230,496 KiB；这是小型 probe 的一个采样，
不是游戏峰值或手机性能结论。完成界面显示 40 FPS，网络等待期间不作为帧率验收。

首次截图中可见一次 **System UI isn't responding** 弹窗。已在 5556 选择 Wait，
随后得到完整、无遮挡的结果截图；保留原始截图。随后 `dumpsys activity lastanr`
显示 `<no ANR has occurred since boot>`，本次保存的日志中没有 KIF 的 Java fatal、
native fatal signal 或 KIF ANR 记录。弹窗原因尚未确认，不能把该模拟器的系统稳定性视为已完整验收。

## 复跑

在选定开发 checkout 根目录，使用已配置的便携工具；所有命令必须明确指定自己的模拟器 serial。
本地 fixture 需要带 cryptography 的 Python，本次使用 Codex 已有的 bundled Python。

```powershell
# 新建/启动独立 kif_network AVD，或复用其测试数据；不要重置玩家设备。
$py = 'D:/Users/meikun.zhang/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe'
$fixture = Start-Process -FilePath $py -ArgumentList @('-u', "$PWD/scripts/android/network_test_fixture.py") -WindowStyle Hidden -PassThru
& $py scripts/android/build_apk.py --runtime-only --with-network
& $py scripts/android/device_check.py install --serial emulator-5556 --apk temp/artifacts/KIF-network-probe-arm64-test.apk
& $py scripts/android/device_check.py network-smoke --serial emulator-5556
& $py scripts/android/device_check.py capture --serial emulator-5556 --label network
# 完成后结束自己启动的 fixture 进程；不输出或提交临时私钥。
```

诊断脚本位于 `android/ruby/android-network-smoke.rb`，通过专用 intent 选择；
正常游戏启动仍使用正常配置。小 APK 使用独立构建目录和产物名，没有覆盖已测试的完整 APK。
本轮完成证据采集后已关闭独立 5556 模拟器和本地 fixture，保留 AVD 数据与全部产物，
没有关闭或操作 5554 游戏会话。

未覆盖：真机、不同 Android 版本、16 KiB 页系统、超过 8 MiB 的响应压力、
弱网/网络切换、应用后台中取消下载、全部游戏内下载调用路径。这些仍需后续验收。
