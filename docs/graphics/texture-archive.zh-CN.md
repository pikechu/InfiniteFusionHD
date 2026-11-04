# 高清制作档案的保存与恢复

2026-11-05 将 `output/texture-hd/` 从主仓库的跟踪文件中移出。游戏使用的 `Graphics/`、`Data/` 和其他客户端资源保持原样；Windows 与 Android 打包的资源白名单均不包含此工作目录。此次操作不改写、裁剪或清理 Git 历史，也不改变已有高清素材的验收结论。

## 档案位置与内容

本机独立档案目录：`F:\claude projects\InfiniteFusionHD-archives\`。

归档文件：`texture-hd-20261105-c7aeb09c.zip`。完整 SHA-256、源提交、文件数、验证结果及体积记录在同目录的 `.zip.sha256` 和本仓库的 [迁移记录](texture-archive-20261105.json)。

归档包含原 `output/texture-hd/` 的全部文件和空目录，包括原图、generated/ready/delivery 副本、逐批清单、P1～P5 验收证据、截图、历史说明及处理/验证脚本。ZIP 内的 `manifest.json` 将每个原始相对路径映射到 SHA-256 和字节数；`objects/<SHA-256>` 仅保存一份相同内容。即使文件重复，原有路径和恢复后的文件仍各自独立。原始换行符、文件名大小写、图片编码及全部文件字节保留，不承诺恢复原文件时间戳或 ACL。

这不是普通的原目录 ZIP，不能将 `objects/` 直接当游戏资源使用。用下面的工具恢复完整路径。无需安装第三方依赖，使用 Python 3.11 或更新版本。

## 校验与恢复

在仓库根目录执行；将 `<SHA256>` 替换为迁移记录或 `.zip.sha256` 中的完整值：

```powershell
python -B scripts/graphics/texture_archive.py verify 'F:\claude projects\InfiniteFusionHD-archives\texture-hd-20261105-c7aeb09c.zip' --sha256 <SHA256>
python -B scripts/graphics/texture_archive.py restore 'F:\claude projects\InfiniteFusionHD-archives\texture-hd-20261105-c7aeb09c.zip' output/texture-hd --sha256 <SHA256>
```

`verify` 检查 ZIP 成员、全部唯一内容的 SHA-256、尺寸及清单总数。`restore` 先校验归档，再恢复全部路径并逐文件核对落盘 SHA-256；目标目录必须不存在，工具不会覆盖现有文件。恢复后原有 README 的相对链接、逐批验证脚本和 `scripts/graphics/texture_batch.py` 的原路径继续适用。历史脚本可能依赖当时的工具链及验收版本，恢复档案不等于重新通过当前版本验收。

只查看证据时可以恢复到独立目录；需要运行依赖原路径的历史脚本时，恢复到 `output/texture-hd/`。该路径继续由 `.gitignore` 忽略，后续批次也在此生成，但不应再用强制添加将大型制作档案放回主仓库。外部 ZIP、校验文件和恢复工具需一同备份；Git 旧历史仍保留此次迁移前的快照。

## 新档案

```powershell
python -B scripts/graphics/texture_archive.py create output/texture-hd 'F:\claude projects\InfiniteFusionHD-archives\texture-hd-YYYYMMDD.zip' --source-commit <COMMIT>
```

创建过程检查源目录未发生变化，完整验证归档后才生成最终文件；不会覆盖已有归档。外置并取消跟踪前，应独立核对恢复结果与客户端输入，保留小型迁移记录。本次迁移的验证边界以迁移记录为准。
