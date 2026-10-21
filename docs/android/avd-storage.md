# 测试 AVD 存储扩容与恢复

本页只涉及本机人工 QA 模拟器，不涉及 Windows 玩家存档或真机。2026-10-21 的 Android.7 升级安装曾返回 `INSTALL_FAILED_INSUFFICIENT_STORAGE`；当时 `/data` 为约 5.8 GiB，剩余约 1.5 GiB。用户批准完整备份后尝试扩容。

**当前未完成文件系统扩容。** 副本 raw 容器已达到 12 GiB，但 ext4 在线扩大失败并只增加了约 128 MiB。没有将失败副本设为默认 AVD；原 6 GiB 目录、入口 INI 和完整备份均保留。不要将下列过程理解为已验证成功的整套扩容方案，也不要重复强行运行在线 grow。

12 GiB 是这台开发模拟器的调试余量；APK 体积和真机安装峰值空间仍分别测量。

## 数据保护与实施方式

原 AVD 为 `D:\others\kurayshinyrevamp\temp\android-avd\kif-api30.avd`，入口为同目录下 `kif_api30.ini`。先 `adb shell sync`，再 `adb emu kill` 正常退出，并确认模拟器进程结束、ADB 中设备消失。此后复制整个 AVD 目录，包含快照、raw、qcow2、密钥、缓存和配置；另复制入口 INI。每个文件分别计算源/副本 SHA-256，并验证复制期间源的长度和修改时间未变化。

完整备份目录为工作树下 `temp/avd-resize7/backup-6g/`。只有 `manifest.json` 中 `verified:true` 才表示全量备份完成；`backup-progress.json` 只是进行中记录。备份保留原来的相对 backing 路径，不能只保留 qcow2 或只保留 raw。

本 AVD 使用 Android 元数据加密：旧 raw 首部仍有 ext4 标记，当前 qcow2 合成视图已是密文。原数据和 `/metadata` 对应的密钥镜像必须配套保留；不能对密文使用宿主 `resize2fs`，也不能关闭加密。[AOSP 元数据加密说明](https://source.android.com/docs/security/features/encryption/metadata)

官方模拟器某些版本的自动扩容流程会在扩大旧 raw 后删除其 qcow2，因此没有直接修改旧配置并启动。本轮从已核验备份创建候选：用 `qemu-img convert` 将完整 qcow2 视图展平为独立 raw，比较虚拟内容相同，再把容器扩为 12 GiB。密钥所在 metadata 和缓存也必须从完整虚拟视图展平，保留内容而不依赖旧 overlay 被启动器继续使用。全程保留原 AVD，不删除旧 overlay。[模拟器扩容相关源码](https://android.googlesource.com/platform/external/qemu/+/refs/heads/emu-master-dev/android-qemu2-glue/main.cpp)

第一次候选仅复制 metadata 的旧 base/overlay，启动时模拟器重建了这个薄 overlay，导致 `No key found in /metadata/vold/metadata_encryption/key`、`/data` 未挂载。这是副本启动方式错误，原盘和完整备份未变。随后把备份的 metadata 完整视图展平并逐字节比较；密钥值和加密策略没有改变。不能把复制旧 metadata base 当作保留了密钥。

## 可复现操作

工具均来自既有 portable Android Emulator **37.2.12 / build 16428233**；其 `qemu-img` 报告 **2.12.0 / g85fa07f04ef**。本机已实测到这个工具的 raw 创建长度错误：请求 6442450944 B 却只创建 2147483648 B，直接转换会在 sector 4194304 写入失败。不能用它创建或 resize 大 raw；使用 64 位文件长度 API 预建，再用 `convert -n` 跳过创建。隔离探针已确认预建 6 GiB 后，工具可以在 2 GiB 偏移以上写入。以下是本轮核心步骤；必须使用新候选目录，不能把输出指向原盘或备份。

```powershell
$sdk = 'D:\others\kurayshinyrevamp\temp\tools\android-sdk'
$backup = 'D:\others\kurayshinyrevamp\temp\android-verify\temp\avd-resize7\backup-6g'
$candidate = 'D:\others\kurayshinyrevamp\temp\android-verify\temp\avd-resize7\candidate64-home\kif-api30-12g.avd'
$qemuImage = Join-Path $sdk 'emulator\qemu-img.exe'
$raw = Join-Path $candidate 'userdata-qemu.img'

function Expand-CandidateRaw([string]$path, [long]$bytes) {
    # 只能用于新候选。先解析、确认绝对路径和容量，只允许扩大。
    if ((Get-Item -LiteralPath $path).Length -gt $bytes) { throw 'Refusing shrink' }
    $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite)
    try { $stream.SetLength($bytes); $stream.Flush($true) }
    finally { $stream.Dispose() }
    if ((Get-Item -LiteralPath $path).Length -ne $bytes) { throw 'Length mismatch' }
}

# 先完成离线全备和逐文件哈希核验，确认 verified:true。
# 候选目录必须新建；先展平完整 metadata/cache 视图，不能只复制旧 base。
foreach ($small in @('encryptionkey.img', 'cache.img')) {
    $output = Join-Path $candidate $small
    if (Test-Path -LiteralPath $output) { throw 'Refusing overwrite' }
    & $qemuImage convert -f qcow2 -O raw "$backup\avd\$small.qcow2" $output
    & $qemuImage compare -f qcow2 -F raw "$backup\avd\$small.qcow2" $output
}
& $qemuImage check -f qcow2 "$backup\avd\userdata-qemu.img.qcow2"
if (Test-Path -LiteralPath $raw) { throw 'Refusing to overwrite an existing candidate' }
& $qemuImage create -f raw $raw 16777216
Expand-CandidateRaw $raw 6442450944
# qemu-img info 必须显示 virtual-size=6442450944 后才继续。
& $qemuImage info --output=json $raw
& $qemuImage convert -n -f qcow2 -O raw -t writeback `
    "$backup\avd\userdata-qemu.img.qcow2" $raw
& $qemuImage compare -f qcow2 -F raw `
    "$backup\avd\userdata-qemu.img.qcow2" $raw
Expand-CandidateRaw $raw 12884901888
& $qemuImage compare -f qcow2 -F raw `
    "$backup\avd\userdata-qemu.img.qcow2" $raw
& $qemuImage info --output=json $raw
```

每条命令都必须检查退出码。容器扩大后的比较允许多出的区域全为零，原 6 GiB 的虚拟内容必须一致。候选的 `config.ini` 设 `disk.dataPartition.size = 12884901888`，入口 INI 的 `path` 指向候选。禁用快照冷启动，不复制 RAM 快照去启动候选。

使用进程内环境设置 `ANDROID_HOME`、`ANDROID_SDK_ROOT` 为上述 SDK，`ANDROID_USER_HOME` 与 `ANDROID_EMULATOR_HOME` 为原项目 `temp/android-user`，`ANDROID_AVD_HOME` 指向候选入口目录。以隐藏后台 helper 启动：

```powershell
Start-Process -FilePath "$sdk\emulator\emulator.exe" -WindowStyle Hidden `
  -ArgumentList @('-avd','kif_api30','-port','5554','-no-window','-no-audio',
                  '-no-snapshot','-no-boot-anim','-no-metrics','-gpu','swiftshader_indirect')
```

等待 `sys.boot_completed=1` 且用户解锁后，首先检查 `/data` 是否自动扩为接近 12 GiB。如果没有，则只在这个 userdebug 测试副本临时 `adb root`，从 `/proc/mounts` 确定真实 `/data` 的 ext4 映射设备，并用 `blockdev --getsize64` 确认其容量为 12884901888，再使用 Android 自带 `resize2fs` 在线扩大该解密映射。不得照抄假定的 `dm-5` 编号，也不得修改密钥、SELinux 或加密策略。

验证容量和全部 30 个人工 QA 文件 SHA-256 一致后执行 `adb unroot`，再以普通 `run-as org.kuray.kif` 重验存档。只有这些检查全部通过，才可将原 `kif_api30.ini` 指向候选；原 6 GiB 目录和完整备份均保留。

## 执行证据与状态

实际命令、退出码、比较输出、设备容量及存档核验保留在 `temp/avd-resize7/`，完整备份及操作脚本同目录留档。

| 检查 | 实际结果 |
| --- | --- |
| 离线完整备份 | 30 个文件（29 个 AVD 文件和入口 INI），16164528197 B，逐份源/副本 SHA 一致，`backup-6g/manifest.json` 的 `verified:true` |
| manifest SHA-256 | `86db36d69362996ac7dbf02dae7918de2de954f0965e526963b37052eca98491` |
| userdata 展平与容器扩大 | `convert -n` 成功；6 GiB、12 GiB 两次 `qemu-img compare` 均 `Images are identical` / exit 0；12 GiB 尾部为零 |
| metadata/cache 修正 | 完整虚拟视图展平并分别比较通过；第二次启动完成；原密钥值和加密策略不变 |
| grow 前 QA | 普通 adbd / run-as，30 份存档、备份和键位等文件全部 SHA 与 `touch-controls7/000-before-upgrade.json` 相同 |
| 在线 ext4 grow | Android 自带 resize2fs 1.45.4 返回 1；kernel 报 `reserve_backup_gdb: reserved block 384 not at offset 383` 和 EINVAL；只从 1572864 增到 1605632 个 4 KiB 块 |
| grow 失败后的 QA | 再次普通 run-as，30 份全部原 SHA；`after-grow-failed-result.json`，gameInactive=true |
| 最后容量与权限 | `/data` 总 6211160 KiB，可用约 1719136 KiB；已经 `adb unroot` 并确认 uid=2000(shell)；未 promote |

失败副本路径为 `temp/avd-resize7/candidate64-home/kif-api30-12g.avd`，只能用于诊断和占用测量。若另建 AVD 并迁移完整应用用户数据，应从原安全 6 GiB 环境导出，不能将这个 grow 失败副本当作可信全数据源。用户随后选择保留原 6 GiB 环境，只清理明确的历史只读素材；没有批准或创建新 AVD。

## 用户批准的原环境维护与升级

正常同步并关闭失败副本后，从未改变的原入口重启原 6 GiB AVD。启动前核验入口 INI 的 SHA、原盘及 overlay 的尺寸/mtime、metadata 密钥链 SHA 与离线备份一致；启动后普通 adbd / run-as 核验全部 30 份 QA 文件仍为原 SHA。默认 AVD 路径仍为 `D:\others\kurayshinyrevamp\temp\android-avd\kif-api30.avd`。

只读清单锁定非 active 的 `files/content/16590ec82d1107a4bf628808/Audio`、`Data`、`Fonts`。活跃版本为 `be6a7f326cb7e1e0ea4ce30e`。三个目标均为真实目录，没有内部 symlink；旧目录的 4610 个常规文件没有多重硬链接，也没有与 active 的 Audio/Data/Fonts 共用 inode。active 的 symlink 只指向自己的 Graphics 代及共享 Cache/Mods/Exported，不引用旧三目录。

对旧三目录逐文件比对其 `.base-files.json` 后，4606 份完全匹配。以下四份修改过或不在 manifest 中，原地保留，清理后 SHA 不变：

- `Data/pokedex/dex.json`
- `Data/sprites/CUSTOM_SPRITES`
- `Data/sprites/sprites_rate_limit.log`
- `Data/REMOTE_VERSION`

用户批准后，先将旧 `.complete` 改名为 `.complete.retired-android7-readonly-assets`，再仅 unlink 4606 份已核验的常规文件，没有递归删除目录。旧 `.base-files.json` 保留；四份差异及其父目录保留。全部 Graphics 代、Cache/Shiny、ExportedPokemons、Mods、saves 和 backups 未纳入删除范围，清理前后这些目录的轻量 stat 完全一致。

| 结果 | 实测 |
| --- | --- |
| 原 6 GiB `/data` 总容量 | 6082144 KiB，未扩大 |
| 清理前可用 | 1592156 KiB |
| 清理后可用 | 2364012 KiB |
| 实际增加 | **771856 KiB / 753.77 MiB** |
| 清理后 QA | 普通 run-as，30 份全为原 SHA |
| Android.7 安装 | `adb install --no-incremental -r` 返回 Success；versionCode=7 / 0.20.7-android.7 |
| 安装后 QA | 普通 uid=2000(shell) / run-as，30 份全为原 SHA；GameActivity 未启动 |
| 移交时可用 | 2364076 KiB（系统活动会造成小幅变化） |

本轮 APK SHA-256 为 `56acc7bb2d337e5259e4b6d5df6425d2e66db80594a3afaab004611bc1fccbe1`。完整证据为 `readonly-cleanup-dryrun.json`、`cleanup-deleted-files.json`、`cleanup-result.json`、`after-approved-cleanup-result.json`、`install-android7-result.json`、`after-install7-result.json` 和 `handoff-result.json`。`commands.jsonl` 保留命令与退出码。

这是用户批准的一次本地 QA 维护，没有实现或启用自动历史素材清理。`du` 的文件块统计与 `df` 的全卷统计在原盘也存在差异，不能把目录父子项或 APK/私有目录数值机械相加；本次回收量以原盘清理前后 `df` 为准。历史 Graphics 可能含下载和自定义内容，不能仅凭旧版本标识删除。

设备已交给控件的 20 项实际检查，随后由父任务进行真实游戏界面回归。本页不把安装成功表述为游玩验收通过，也不宣称 12 GiB 扩容成功。

## 恢复

当前入口始终没有改变，已回到原 6 GiB 目录，无需再切换入口。全量离线备份保留的是维护前状态；恢复整个备份会回退该时点之后的 QA 进度，因此应先另存当前数据并确认恢复目标。

需要恢复时，先正常同步并关闭模拟器，确认 QEMU 结束。检查最终绝对目标路径，确保 raw、qcow2、密钥、快照元数据和配置来自同一份完整备份；不要混用不同时间的密钥、只还原旧 base 或修改 qcow2 的 backing 文件。不能覆盖运行中的镜像。仅恢复入口 INI 不会撤销本次已批准的只读素材清理。
