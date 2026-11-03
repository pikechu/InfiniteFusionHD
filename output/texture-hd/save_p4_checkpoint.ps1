$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$utf8 = New-Object Text.UTF8Encoding($false)
function Read-Json($name) { Get-Content -LiteralPath (Join-Path $PSScriptRoot $name) -Raw -Encoding UTF8 | ConvertFrom-Json }
function Write-Json($name, $value) { [IO.File]::WriteAllText((Join-Path $PSScriptRoot $name), ($value | ConvertTo-Json -Depth 30) + "`n", $utf8) }

$progress = Read-Json 'p4-progress.json'
if ($progress.completed_files -ne 1776 -or $progress.next_batch -ne 'batch-578') { throw 'Checkpoint has advanced; review before overwriting.' }
$visual = Read-Json 'p4-work/visual-review.json'
foreach ($number in 605..616) {
    $page = 'review-{0:000}-01.png' -f $number
    if ($visual.reviewed_pages -notcontains $page) { $visual.reviewed_pages += $page }
}
$visual.notes | Add-Member -NotePropertyName '605-616' -NotePropertyValue 'Viewed 2026-11-02 before saving: legacy numeric footprints, five current shadow masks, and the first window skins. Preserve functional silhouettes, alpha and exact window atlas geometry. Visual review does not advance batch receipts; completed batches still end at 577.' -Force
Write-Json 'p4-work/visual-review.json' $visual

$profiles = @(Get-ChildItem -LiteralPath (Join-Path $root 'temp/multiplayer') -Directory | Where-Object Name -Like 'texture-p2-dex-p4-*')
$runtimePaths = @($profiles | ForEach-Object { Join-Path $_.FullName 'Game.exe' })
$active = @(Get-Process -Name Game -ErrorAction SilentlyContinue | Where-Object { $_.Path -in $runtimePaths })
if ($active.Count) { throw 'A task-owned native process is still running.' }
$logs = @($profiles | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Recurse -File -Filter '*.log' })
$configs = @($profiles | ForEach-Object { Join-Path $_.FullName 'mkxp.json' } | Where-Object { Test-Path -LiteralPath $_ })
$frames = Test-Path -LiteralPath (Join-Path $root 'temp/texture-p4-gif-check')
if ($logs.Count -or $configs.Count -or $frames) { throw 'Task-owned temporary test files remain.' }
Write-Json 'p4-evidence/checkpoint-cleanup.json' ([ordered]@{
    checked_at = [DateTimeOffset]::UtcNow.ToString('o'); profiles_checked = @($profiles.Name)
    running_task_processes = 0; remaining_temporary_logs = @(); remaining_test_configs = @(); temporary_gif_frames_remaining = 0
    preserved = 'Immutable prepared runtime files, original backups, generated proposals, delivery copies and formal evidence.'
})

$resume = [ordered]@{
    status = 'saved_awaiting_user'; saved_on = '2026-11-03'; completed_through = 'batch-577'; next_batch = 'batch-578'
    completed_files = 1776; remaining_files = 3289; applied_files = 0; preserved_files = 1776
    visual_review_through = 'batch-616'; candidate_pending_review = @(); ready_pending_application = @()
    native_proofs = [ordered]@{ icons = 'passed'; windows = 'passed with recorded inherited compatibility issues'; effects = 'passed, not yet registered in native-proofs.json'; animated = 'native playback passed; external GIF pixel verification incomplete' }
    outstanding = @(
        'Resume batch receipts at 578; reviewed pages through 616 are saved, but only 541-577 are completed.'
        'Register effects proof after checking its consumer hashes; review effect pages and preserve out-of-sheet pattern findings.'
        'run_p4_animated.py failed on hidden RGB at transparent pixels in 137.94.gif frame 0; no pixel verification was accepted. Exports were deleted in finally. Review visible-RGB comparison before rerunning.'
        '164.267.gif has variable source frame delays; native Bitmap uses constant 20 fps. Native cycling is not proof that original timing is preserved.'
        'Do not treat generic donor-strip decoding as current battler animation binding or complete gameplay coverage.'
        'Weather, remaining visual review and later P4 batches still require work. P4 and P5 remain incomplete.'
    )
    cleanup = 'output/texture-hd/p4-evidence/checkpoint-cleanup.json'
}
Write-Json 'p4-work/resume.json' $resume

$intro = @'
## P4 当前保存点（2026-11-03）

**第 541～577 批已完成：1,776 / 5,065 张，全部保留原图；剩余 3,289 张，下一批为 578。P4 尚未完成。** 本次保存包含 P3 完成成果及当前 P4 档案。P4 没有替换游戏图片；第 541～616 批的视觉审查已记录，未完成的批次没有提前记为验收完成。

图标/足迹、窗口和招式特效的原生检查已保存。GIF 原生播放检查完成，但外部逐像素检查因透明像素的隐藏 RGB 差异中止，尚未通过；`164.267.gif` 另有源文件变帧延迟与原生固定帧率不一致的问题。窗口既有的关闭状态及大写扩展名兼容问题、特效越界图格均保留在证据内，未修改游戏逻辑。

恢复时先读 [准确断点与待办](p4-work/resume.json)、[P4 进度](p4-progress.json) 和 [清理记录](p4-evidence/checkpoint-cleanup.json)。本轮测试进程、临时日志和 GIF 导出帧已清理；保留原图、交付副本、试制图及正式证据。完整游玩、Android 实机和最终发布包仍未验证。

'@
$readmePath = Join-Path $PSScriptRoot 'README.zh-CN.md'
$readme = [IO.File]::ReadAllText($readmePath)
if (-not $readme.Contains('## P4 当前保存点（2026-11-03）')) {
    $firstBreak = $readme.IndexOf("`n") + 1
    $readme = $readme.Insert($firstBreak, "`n" + $intro + "`n")
    $readme = $readme.Replace('全局 18,665 张中，268 张已应用、11,482 张保留、6,915 张待处理；P1～P3 已完成，下一计划批次为 P4 第 541 批，P4/P5 尚未开始。', 'P3 完成时的历史快照为：全局 18,665 张中，268 张已应用、11,482 张保留、6,915 张待处理；当前进度以上方 P4 保存点为准。')
    [IO.File]::WriteAllText($readmePath, $readme, $utf8)
}
$planIntro = '2026-11-03 保存点：P1～P3 已完成；P4 第 541～577 批已完成 1,776 / 5,065 张，全部保留原图，剩余 3,289 张，下一批 578。全局 268 张应用、13,258 张保留、5,139 张待处理。P4、P5 尚未完成；恢复先读 [断点](../p4-work/resume.json)。'
foreach ($name in @('execution-plan/README.zh-CN.md', 'execution-plan/stage-summary.zh-CN.md')) {
    $path = Join-Path $PSScriptRoot $name
    $text = [IO.File]::ReadAllText($path)
    if (-not $text.Contains('2026-11-03 保存点：')) { $text = $text.Insert($text.IndexOf("`n") + 1, "`n$planIntro`n") }
    $text = $text.Replace('下一计划为 P4 第 541 批，P4/P5 未开始', '上述为 P3 完成时的历史状态，当前进度见本页保存点')
    [IO.File]::WriteAllText($path, $text, $utf8)
}
Write-Output 'P4_CHECKPOINT_SAVED: batch-577 complete; batch-578 next; no task-owned processes or raw logs remain.'
