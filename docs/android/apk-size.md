# APK 体积审计与无损优化

审计日期：2026-10-20。输入为已验证的 Android.1 模拟器网络测试包，SHA-256
`475d2bf3d872915a79c4996369696248d2f57fdb078f25de31f7d74450166279`。
Android.2 已生成首个优化签名包；其最终安装结果与修复后重签 SHA 仍以设备报告、最终产物和 build record 为准。

## 为什么约 800 MiB

该测试包把原游戏素材完整放进 APK，以支持独立安装、离线启动，运行时不依赖播放器。
839,006,445 字节等于 800.14 MiB，手机文件管理器用十进制显示时约 839 MB。

| APK 部分 | ZIP 内实际占用 | 占整个 APK |
| --- | ---: | ---: |
| 游戏 payload.zip | 812,059,311 B / 774.44 MiB | 96.79% |
| 22 个 ARM64 原生库 | 25,782,270 B / 24.59 MiB | 3.07% |
| 内容校验清单 | 1,085,794 B / 1.04 MiB | 0.13% |
| Java/DEX、配置、签名与 ZIP 结构 | 约 77 KiB | 约 0.01% |

内层 ZIP 在 APK 中采用 stored，**没有重复压缩一份完整游戏，也没有打入 Windows EXE、开发工具、SDK、NDK、用户存档或 temp**。
原生库在 APK 中已经从 63.11 MB 压到 25.78 MB。仅修改 Gradle、移除几个 Java 类或精简界面，对总体体积帮助有限。

payload 包含 23,127 个逻辑路径，解包后 979,348,069 B（934.00 MiB）：

| 资源目录 | 原始字节 | 原 payload 压缩后字节 |
| --- | ---: | ---: |
| Audio | 616,391,947 | 587,452,465 |
| Graphics | 194,204,426 | 190,548,495 |
| Data | 168,501,933 | 30,502,433 |
| Fonts 与入口辅助文件 | 249,763 | 约 80 KiB |

音频占原始资源 62.94%；其中 MP3 379.70 MB、WAV 171.49 MB、OGG 63.42 MB。
旧打包策略将 PNG、MP3、OGG、JPG 直接存储，因此仍有不改变素材的压缩空间。

## 已完成的实际全量压缩实验

通过 `scripts/android/analyze_apk_size.py` 对独立快照做实验，未改变源素材。
每个实验都生成真实 ZIP，随后逐项解压，与原清单的长度和 SHA-256 比较；23,127 项全部一致。
耗时来自这台开发机的单次测量，不是手机首次安装的耗时。

| 策略 | 真实 ZIP 字节 | 相对旧 payload 节省 | 构建耗时 | 全项校验耗时 |
| --- | ---: | ---: | ---: | ---: |
| 原策略 | 812,059,311 | — | — | — |
| 全项 DEFLATE 6 | 781,047,085 | 31,012,226 B / 29.58 MiB | 55.80 s | 12.83 s |
| 全项 DEFLATE 9 | 780,600,468 | 31,458,843 B / 30.00 MiB | 70.29 s | 13.80 s |

6 级已获得主要收益；9 级再省约 436 KiB，却多花约 14.5 秒，本轮采用 6 级。
其中 PNG 二次压缩省 24,718,029 B，MP3 省 4,349,548 B，OGG 省 1,559,233 B，JPG 省 385,416 B。
部分很小的 PNG 会增加数个字节，全部 PNG 的总收益仍为 23.57 MiB。

## 内容去重

清单有 1,687 组长度与 SHA-256 均相同的文件，共 2,300 个重复路径，重复原始内容为
76,683,675 B（73.13 MiB）。这些路径可能被地图、脚本或音频事件分别引用，不能直接删除路径。

代表例子是 `Audio/BGM/Pewter_city.mp3` 与其长文件名版本，二者各 9,603,186 B；
`mt_moon.mp3` 也有相同的 4,066,063 B 副本。
全量 6 级 ZIP 中，重复内容及对应 ZIP 记录合计占 65,246,810 B（62.22 MiB）。

实现方式是只在 APK ZIP 内保存一份 canonical，清单为重复路径记录单跳 `source`。
安装器按原名恢复每一个文件，验证每个文件的长度和 SHA-256；恢复后是**独立文件副本**，不采用 hardlink。
因此下载或编辑某个可写精灵图不会改变另一个同内容路径。
旧清单没有 `source` 时继续按原规则安装，断点续装仍复用已验证文件。

该格式已集成到 `package_game.py`、`build_apk.py` 与 Android 安装器。
固定快照已生成**真实**去重 ZIP，结果为 715,800,275 B（682.64 MiB），
比旧 payload 少 96,259,036 B（91.80 MiB）。23,127 个逻辑路径对应
20,827 个归档文件和 2,300 个别名，逻辑内容 ID 与旧快照相同。

该次完整实验构建耗时 201.41 秒，随后读取所有 canonical 与逻辑别名逐项复核，耗时 31.49 秒；
开发机同时有其他编译任务，耗时不能与上表的单次压缩直接比较。
真实 ZIP 的 SHA-256 为
`3ad02a73d51a6765bccad1891c1d57bef21118b6cf8245edb5c6772f929a573b`。
结果、清单和 ZIP 分别保存在 `temp/size-audit/deduplicated-report.json`、
`deduplicated-manifest.json`、`payload-deduplicated-deflate-6.zip`。

已通过生产 Java 恢复代码的 34 项主机文件系统断言及 9 组 Python ZIP/刷新/严格资源白名单测试，覆盖原文件字节、
独立副本、损坏与续装、旧格式、非法别名链/来源/大小/哈希、路径、重复/缺失归档项和可重现输出。
Android 外壳与固定 SDL Java 源码编译通过。优化后的 APK 大小、首次解包、升级与游戏回归仍由
最终签名产物及模拟器实际结果确认，不能用主机通过代替设备验收。

Android.2 的首个实际优化签名 APK 为 **742,762,733 B（708.35 MiB）**，
与同版修复后的未优化 APK 839,010,541 B 相比减少 96,247,808 B（91.79 MiB），约 **11.47%**。
这已是可安装 APK 的实际体积，不是压缩比例推算；设备验收仍独立记录。
随后构建脚本增加严格 assets 白名单，防止中断刷新残留的 `payload.zip.pending` 被 aapt2 收入 APK；
最终重签的 SHA-256 以交付目录对应 `.sha256` 和 `-build-record.json` 为准。

## 进一步缩小的选择

| 方式 | 体积潜力 | 代价与验证要求 |
| --- | --- | --- |
| 无损 ZIP 压缩 + 内容去重 | 本轮合计约 92 MiB | 不改素材、功能、音频质量；需安装恢复与升级回归 |
| 排除 PSD/KRA/ASE/Thumbs.db 等编辑器产物 | 约 0.76 MiB（压缩后、去重前） | 确认运行时引用后再剔除，收益较小 |
| WAV 转 OGG、MP3 重新编码 | 可能显著降低，尚未实测 | 属于有损素材变换；需试听音质、音量、循环、淡入淡出、同步及音频格式优先级，不能承诺固定缩小比例 |
| 精简音乐质量档或语种 | 尚未测量 | 需要产品选择；不能静默删剧情或资源 |
| 小基础包 + 首次下载资源包 | 可明显减少 APK 本身 | 总下载未必减少，首次启动依赖网络；需明确进度、校验、续传、离线失败恢复和资源版本管理 |
| 商店资源分发 | 尚未选发布渠道 | 需配合渠道方案，不能当作当前独立 APK 已完成的优化 |

当前优先无损优化。图像转 WebP、纹理压缩和任意音频改扩展名都不能直接套用：游戏原有
Bitmap/音频加载器和文件名查找必须逐项验证，不能以文件体积变小替代游玩验收。

APK 缩小不等于安装后的资源缩小。为保留可写文件独立性，去重内容在解包后恢复全部原文件；
这轮不会减少约 934 MiB 的资源目录。Android 还保存已安装 APK、提取的原生库及存档缓存，
旧资源世代在升级后仍保留，清理策略另行实现，不能删除用户存档来腾空间。

## 复现

在隔离工作区运行（portable Python 路径可按本机调整）：

```powershell
& 'D:\Users\meikun.zhang\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' `
  scripts/android/analyze_apk_size.py `
  --apk temp/size-audit/source.apk `
  --payload temp/size-audit/source-payload.zip `
  --manifest temp/size-audit/source-manifest.json `
  --output temp/size-audit --levels 6 9
```

原始快照、两个真实实验 ZIP 和机器可读结果保存在 `temp/size-audit/`，不提交仓库。
机器可读结果为 `size-report.json`；两个实验 ZIP 的 SHA-256 分别为：

- DEFLATE 6：`708c0630abeda6b1e5ea1789b4d74d705fd0ce2a70ac1b38be0ab9747328140d`
- DEFLATE 9：`61502d7da45e16477c03598a1cc72a4448d58c0df534465b83fa94c47f82a135`

恢复与格式回归可执行：

```powershell
& scripts/android/run_payload_checks.ps1 -PythonPath `
  'D:\Users\meikun.zhang\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
```

`--refresh-ruby` 接受原格式与去重格式，读取原素材快照后生成格式 2；`--skip-payload`
会重新验证 canonical 的实际 SHA-256，同时验证所有单跳别名元数据及逻辑内容 ID。
`archiveFormat` 未指定时按旧格式 1 处理；格式 2 必须有 `archiveFiles` 与 `archiveBytes`。
各 `files` 项依然包含原始 `size`/`sha256`，可选 `source` 必须指向没有 `source` 的项，且
长度与 SHA-256 相同。逻辑 `bytes` 及安装进度包含所有别名恢复后的文件，不用压缩字节数冒充安装所需空间。

构建 assets 只允许 `payload.zip`、`payload-manifest.json`、`mkxp-base.json`；
`network-enabled` 只在 `--with-network` 模式允许，且内容为单字节 `1`。
检查在重包/昂贵编译前和 aapt2 收集前执行。未知文件、目录、符号链接与 `.pending` 会使构建明确失败，
保留现场供开发者检查；构建不会静默删除。切换网络模式应使用正确的 staging 或显式处理旧 marker。
