# Android HTTPS 适配器设计与依赖边界

调查日期：2026-10-16。仅在隔离 worktree `temp/android-verify` 研究和写本文档；没有修改 Manifest、安装适配器或向游戏开放网络。

实施更新：后续已选择 **Android Java TLS 桥**，没有采用下文的 Ruby stdlib vendoring 路线。`android/ruby/kif_android_http.rb` 的 `KIF::AndroidHTTPAdapter` 经 native `KIFAndroidBridge.request` 调用 Java；JSON 使用 mkxp 的本地 JSON，二进制经 pack/unpack Base64，不依赖缺失 stdlib。默认仍离线，仅 `KIF_ANDROID_NETWORK=1` 且 preload 成功加载指定 native 桥、游戏根有适配器时安装；不改原 HTTPLite 网络函数。POST 明确禁止重定向跟随，避免重复提交。52 项 mock 传输契约、38 项真实本地文件/故障注入、11 项 Bitmap 构造器入口和38项平台回归通过。这些测试不是 TLS/设备验收，真实证书、超时和下载结果由主测试报告记录。下文保留为运行时依赖研究与设计依据。

下载实现使用集中 `KIF::Platform.write_download`：仅 app 私有路径，保护 saves/backups，完整写入唯一 EXCL 临时文件后 flush/fsync/close/rename，失败保留旧缓存并清理本次 staging；PNG/GIF 先检查 magic。Android 明确不向 `Data/Scripts` 下载或留下临时文件，以免不筛扩展名的 loader 执行下载残留。Windows 维持原直接写入行为。

## 结论与当前运行证据

可以采用 **固定版本 Ruby 标准库 + native Socket/OpenSSL** 实现验证型适配器，通过 `KIF::Platform` 接入；现有 APK 并不具备开箱即用的 Net::HTTP。发布级联网还需要替换下述旧 C TLS 依赖。父任务真实运行探针确认：

| 项目 | Android Ruby 3.4.10 实际结果 |
| --- | --- |
| `require 'socket'` | 成功，但不能据此认为 Ruby socket wrapper 已加载 |
| `require 'openssl'` | 成功，C 库为 OpenSSL 3.0.12；不能据此认为 SSLContext 的 Ruby 安全配置方法已存在 |
| `require 'net/http'`、`uri`、`json`、`fileutils`、`timeout` | 均为 LoadError |
| OpenSSL 默认 CA 路径 | 指向构建者 `/home/graham/Projects/.../cert.pem` 和 `certs`，不适用于 Android |

本次另外只读检查 API 30 AVD：以 `run-as org.kuray.kif` 可列出 `/system/etc/security/cacerts` 的 **138 个文件**，并读取 PEM；`/apex/com.android.conscrypt/cacerts` 不存在。证据在本 worktree 的 `temp/network-research/avd-*-cacerts.txt`。没有进行 TLS 连接或证书负向测试，因此“可安全联网”仍待验收。

**现有 C TLS 库不是可直接沿用的发布基线。** 截至本次调查，OpenSSL 3.0 系列已于 **2026-09-07** 结束公开安全支持，3.0.12 又早于该分支后续多次安全修补；vendor Ruby 文件不会升级这个 C 库。内部验证可以核实接口和证书失败行为，正式启用网络应重编受支持的 OpenSSL 并回归（例如选定并锁住 3.5 LTS 的具体补丁版本，官方支持到 2030-04-08），或改用 Android Java TLS 桥。不能只把 VERIFY_PEER 打开后就宣称完成安全发布。[OpenSSL 官方 EOL 公告](https://openssl-library.org/post/2026-09-16-eol30/)、[官方生命周期](https://openssl-library.org/roadmap/)

若缺失的能力只是纯 Ruby 文件，vendor 后不需修改 RGSS native ABI。若 `io/wait`、`io/nonblock` 所需能力实际缺失，则需要补编相应 native extension，或采用 Android Java 网络桥；不能创建空模块来掩盖缺失，也不能回退到关闭证书验证的 HTTPLite。

## 应固定并打包的源码

首轮匹配快照是 [Ruby 3.4.10 commit `2b0b7728dc7f0561c35c3d8c4489945c94b783ad`](https://github.com/ruby/ruby/tree/2b0b7728dc7f0561c35c3d8c4489945c94b783ad)，与所选运行时的二进制 revision 相符。不要从开发机 Ruby 3.2 拷贝整套 stdlib，也不要在设备启动时执行 gem install。

已下载检查该提交的小文件，版本/依赖为：

| 源码范围 | 固定快照版本或依赖 |
| --- | --- |
| `lib/net/http.rb`、`lib/net/http/**` | Net::HTTP **0.6.0**；直接依赖 net/protocol、uri、resolv；HTTPS 使用 OpenSSL |
| `lib/net/protocol.rb` | **0.2.2**；依赖 socket、timeout、io/wait |
| `lib/uri.rb`、`lib/uri/**` | URI **1.0.4**；应保留全部 require_relative 文件 |
| `lib/timeout.rb` | **0.4.3**；需要核心 Thread/Queue/Mutex/ConditionVariable |
| `lib/resolv.rb` | **0.7.1**；还依赖 securerandom、rbconfig、socket、timeout、io/wait |
| `lib/securerandom.rb`、`lib/random/formatter.rb` | SecureRandom **0.4.1**；依赖核心安全随机数能力 |
| `lib/ipaddr.rb` | **1.2.7**；OpenSSL Ruby wrapper 使用它 |
| `ext/socket/lib/socket.rb` | Ruby wrapper，调用 `socket.so` 并补齐 Addrinfo/Socket 方法 |
| `ext/openssl/lib/openssl.rb`、`ext/openssl/lib/openssl/**` | Ruby/OpenSSL wrapper **3.3.3**；与 C OpenSSL 3.0.12 是不同版本号；依赖 openssl.so、io/nonblock、ipaddr、socket 等 |
| `io/wait`、`io/nonblock` | 必须逐项检查 require 和真实方法；不能仅检查 native 模块名 |

将这些来源、每个文件 SHA-256、上游许可证和任何局部补丁纳入单独 `android/ruby/vendor.lock.json`；构建时复制到游戏根目录下的专用 vendor 目录，加入 Android `rubyLoadpath`。不把 vendor 文件放入 `Data/Scripts`，避免游戏 loader 当作普通脚本乱序执行。

还必须递归扫描真正使用路径的 require，而不是把上表当成完整闭包。例如 Net::HTTP multipart 路径会延迟加载 tempfile；首版适配器仅提供 GET 和原始 body POST，不开放 multipart、Basic-auth helper 或自动 cookie jar，可避免无关依赖。`resolv.rb` 仅为 Windows hosts 位置判断就 require `rbconfig`；如果目标构建的 rbconfig 未提供，应使用匹配 Android native build 的生成文件，或维护一处经过测试的 Android vendor 补丁，不能用 Windows rbconfig 冒充目标配置。

native `socket`/`openssl` 已被 require 时，再 require 同名入口可能直接命中已加载 native feature。Bootstrap 应显式加载固定绝对路径的 Ruby wrapper，记录一次性 guard，并断言实际方法存在。最低能力断言包括：`SSLContext#set_params`、`verify_mode=`、`verify_hostname=`、`min_version=`、`cert_store=`，`SSLSocket#hostname=`、`post_connection_check`、非阻塞读写，以及底层 IO 的可读/可写等待能力。

Ruby 3.4.10 的 socket wrapper 说明部分等待能力在 Ruby 3.2 后已经进入 core。若 require `io/wait` 失败但全部所需核心方法确实可用，可以提供只检查这些能力的兼容入口；不能凭版本号假定方法存在。OpenSSL wrapper 仍显式 require `io/nonblock`，也要单独验证。

## 信任根和 TLS 配置

不要使用构建机 CA 默认路径，也不要只设置 `verify_mode`。Ruby/OpenSSL 的 SSLContext 默认不验证；主机名校验还需要 VERIFY_PEER 和正确的连接主机名。[Ruby/OpenSSL SSLContext API](https://ruby.github.io/openssl/OpenSSL/SSL/SSLContext.html)

推荐第一种可验证实现：创建显式 `OpenSSL::X509::Store`，从当前设备的只读系统信任根逐份读取、解析和 `add_cert`。Android 14 起信任根可通过 Conscrypt APEX 更新，不能盲目合并新旧目录，导致把新系统已经移除的旧根重新加入。优先选择可读且包含有效证书的 Conscrypt APEX 根目录；旧版 Android 使用系统目录。目录不是公开 SDK 的稳定接口，必须在支持的系统上做实际读取测试；失败时保持离线。[AOSP Conscrypt 说明](https://source.android.com/docs/core/ota/modular-system/conscrypt)

不能直接假定 `ca_path = '/system/etc/security/cacerts'` 可用：Android CA 文件名使用 `subject_hash_old`；现代 OpenSSL 的目录查找使用另一套 hash。逐份 `Certificate.new` + `add_cert` 可以避开文件名 hash 不匹配。[Android CA 格式源码](https://android.googlesource.com/platform/system/ca-certificates/+/52f5fbad24e028e643320cbcb7a0ab24f67fe51b/README.cacerts)、[OpenSSL hash-directory 文档](https://docs.openssl.org/3.0/man3/X509_LOOKUP_hash_dir/)

CA 导入设置明确上限，例如 512 个普通文件、单文件 256 KiB、总量 8 MiB，只访问选定系统目录；文件不可读/无法解析要记录并计数，若无有效根或异常比例超阈值，则拒绝安装适配器。证书以 DER SHA-256 去重。只读系统根，不自动纳入用户安装 CA 或任意下载的“修复证书”。不要把系统根复制到用户可随意编辑的下载/闪光缓存目录。

备选是随 APK 打包一个有明确来源、日期、SHA-256 和更新机制的 CA bundle。它不会自动跟随 Android 移除/新增根，必须承担后续维护。Java 标准网络栈则可以直接使用平台信任机制，但需要新增到 Ruby 的桥；证书验证不能交给“始终返回 true”的自定义 TrustManager 或 hostname verifier。

Ruby OpenSSL 不等于 Android 的 Java TLS 栈。不能声称它自动执行 Network Security Config 的每域策略、用户 CA 策略、CT 或平台撤销机制。当前无 INTERNET 权限是 OS 层门禁；未来加入该权限后，`usesCleartextTraffic=false` 不能替代 native socket 客户端自己的 HTTPS-only 校验。[Android 网络安全配置](https://developer.android.com/privacy-and-security/security-config)

每个连接的核心配置应明确设置，而不是依赖默认值：

```ruby
http = Net::HTTP.new(uri.hostname, uri.port)
http.use_ssl = true
http.verify_mode = OpenSSL::SSL::VERIFY_PEER
http.verify_hostname = true
http.min_version = OpenSSL::SSL::TLS1_2_VERSION
http.cert_store = validated_system_store
http.max_retries = 0
http.open_timeout = [5.0, remaining_seconds].min
http.read_timeout = [8.0, remaining_seconds].min
http.write_timeout = [8.0, remaining_seconds].min
http.ignore_eof = false
```

这只是配置示意，尚未成为源代码或已运行网络测试。保留 Net::HTTP 的 SNI 与连接后的主机名检查，不手写 HTTP/TLS 协议解析器。

## KIF 接口、限额和失败语义

适配现有集中接口，不全局重写 HTTPLite；本地 `HTTPLite::JSON` 继续可用：

```ruby
adapter.get(url, headers = {})
adapter.post_body(url, body, content_type, headers = {})
# 兼容现有调用者的返回结构：
{ :status => 200, :body => binary_string, :headers => string_keyed_headers }
# 传输/策略失败；不得返回已收到的半截内容：
{ :status => 0, :body => "", :headers => {}, :error => safe_message }
```

有效 HTTP 404/429/5xx 是 HTTP 响应，保留其真实状态；仅传输、验证和策略错误使用 status 0。不能把错误包装为 200。只在依赖、系统根和配置检查通过后调用 `KIF::Platform.install_http_adapter`，失败则延续现有 offline_response。安装动作必须发生在 `000_Platform.rb` 定义集中接口后；当前 preload 比它更早，且 customScript 探针会绕过 preload，不能依赖错误的加载顺序。

建议首版限制值如下；实际素材若超过限额，应测量后为特定资源显式调整，不能在错误时退回无限下载。

| 控制项 | 首版默认 |
| --- | --- |
| URL | 仅 HTTPS；禁止 userinfo、控制字符；最长 8 KiB；首轮目标为已核实的素材/配置主机 |
| 请求 body | 1 MiB；raw POST 原样发送，不重新解释为 form/multipart |
| body 接收 | 16 MiB；逐块累计 bytesize，声明 Content-Length 超限提前失败；忽略 Content-Length 不能绕过计数 |
| 压缩 | 显式 `Accept-Encoding: identity`，拒绝意外 Content-Encoding；避免隐式解压耗尽内存 |
| 连接/单次读写 | 连接 5 秒、单次读写 8 秒，均不超过总剩余预算 |
| 全请求 | 20 秒单调时钟预算，包括 DNS、握手、重定向和重试 |
| 重定向 | GET 最多 5 次；每跳重新验证 HTTPS 和目标策略；禁止降级 HTTP |
| 重试 | GET 最多额外 2 次，总请求数不超过 8；短退避和抖动计入同一 deadline；POST 不自动重试 |
| 响应头 | 目标为状态/单行 8 KiB、总 64 KiB、100 项、最多 8 个 interim 响应；见下述 parser 边界 |

流式使用 `http.request(request) { |response| response.read_body { |chunk| ... } }`，body 以二进制编码累积，超限立即关闭连接并丢弃缓冲。不要用会先读完整 body 的便捷 GET。[Ruby Net::HTTP 官方用法](https://github.com/ruby/net-http)、[Ruby 3.4 Net 接口](https://docs.ruby-lang.org/en/3.4/Net.html)

需明确两处不应夸大的边界：

1. read_timeout/write_timeout 限制一次阻塞操作，不是整个下载时限；只在 chunk 到达时检查时钟也无法阻止慢速持续响应。外层总 deadline 必须能关闭该次连接，并验证 native DNS/ARM translation 下的取消行为。Net::HTTP 0.6.0 内部用 Timeout 包住 TCP 连接，但不能把“设置 20 秒”直接写成严格已验证保证。[Ruby Net::HTTP 超时定义](https://docs.ruby-lang.org/ja/3.4/class/Net%3D3a%3D3aHTTP.html)
2. 已检查的 0.6.0 `Net::BufferedIO#readuntil` 和 `HTTPResponse.each_response_header` 没有上表的累计响应头上限。仅 body 限额不能防巨大响应头。若保留此快照，应在 Android vendor 副本中做小范围、有哈希和测试的行长/累计头大小/数量补丁，或选用并验证已提供所需限制的官方版本；不能在收到完整 headers 后才把它当成内存上限。

请求 header 必须拒绝 CR/LF，限制数量和总长度；Host、Content-Length、Connection、Transfer-Encoding、Accept-Encoding 由适配器根据实际 URI/body 管理，不透传旧工具中的 Proxy-Connection 等逐跳字段。重定向换 origin 时移除 Authorization、Cookie 和 Proxy-Authorization，不把访问令牌转发给 CDN。POST 默认不跟随重定向，避免静默改变方法或重复交换/提交。证书、主机名、过期、URL、大小和协议错误不重试；瞬态连接/读取中断、有限的 429/502/503/504 可按预算重试 GET。不要打印完整认证 header、query token 或 POST body。

保留调用者/应用显式代理配置，不清空环境变量、不加 no-proxy 绕过管理策略。Ruby Net::HTTP 不会自动等同于 Android Java 系统代理，需单独记录其支持边界。

## 与游戏下载/写入的集成缺口

`pbDownloadData` 当前期待同步 Hash 返回，先完整收到 body，再写文件。适配器可以保留这个契约，但超时时会阻塞当前 RGSS 调用；应记录实际帧停顿，并在下载管理层显示进度/允许取消，后续把素材队列移到 worker。不要从网络线程调用 Bitmap/Graphics，也不要重入游戏状态更新来维持假进度。

成功下载也必须通过同目录临时文件、验证和原子 rename 激活，失败保留原缓存；不把半截 PNG 或 HTTP 200 的 HTML 错误页写入正式精灵路径。PNG 等资源由下载层按期望类型/签名验证，generic HTTP 传输层不猜测全部内容格式。

`pbPostData` 目前仅匹配 `http://` URL，Android HTTPS-only 适配器不会使它自动可用；需要集中改造其 URL 处理。Wonder Trade 默认 URL 为 `http://localhost:8080`，也不能未经说明启用。首轮恢复精灵/文本资源下载与线上交易是独立验收项。BAT/git 更新器和远程可执行 Ruby 配置仍需独立的平台策略，不能因为 TLS 成功就顺带恢复所有桌面网络入口。

## 开放网络前的实际验收

先做不联网的冷启动依赖/能力探针，记录 `$LOADED_FEATURES`、各 wrapper 版本、CA 数量及失败来源；确认缺库时游戏仍可离线启动。随后在专用可控 TLS 端点和模拟器/真机验证：

- 正确证书成功；未知 CA、错误主机名、过期证书必须失败，且没有任何原生 HTTPLite 回退。
- HTTPS 相对/跨主机重定向、循环、HTTP 降级、跨 origin 认证信息移除；POST 不重发。
- DNS 无响应、连接拒绝、TLS 握手卡住、慢速持续 body、读取中断、超长头、未知长度/分块超大 body、异常 gzip；测真实结束时间和内存峰值。
- GET 重试次数、总 deadline、退避、429 Retry-After 上限；交易类 POST 不重复。
- UTF-8 JSON、二进制 PNG、缓存已有/缺失、失败恢复、离线启动、切后台/取消；保存和已有缓存不被破坏。
- Android 14+ APEX 信任根、至少一台 ARM64 真机；代理支持另测。

这些是后续验收门槛，不是本次已完成测试。当前继续保留无 INTERNET 权限和 KIF 离线门禁，优先完成核心游戏闭环。
