param([Parameter(Mandatory=$true)][string]$Manifest, [Parameter(Mandatory=$true)][string]$Output)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Media.Ocr.OcrEngine,Windows.Foundation,ContentType=WindowsRuntime]
$null = [Windows.Storage.StorageFile,Windows.Storage,ContentType=WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder,Windows.Graphics.Imaging,ContentType=WindowsRuntime]
$asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
} | Select-Object -First 1
function Await-WinRT($Operation, [Type]$ResultType) {
    return $asTask.MakeGenericMethod($ResultType).Invoke($null, @($Operation)).GetAwaiter().GetResult()
}
$engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
if ($null -eq $engine) { throw 'No installed OCR language is available' }
$rows = Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
$writer = New-Object System.IO.StreamWriter($Output, $false, (New-Object System.Text.UTF8Encoding($false)))
$count = 0
try {
    foreach ($row in $rows) {
        $stream = $null
        $bitmap = $null
        try {
            $file = Await-WinRT ([Windows.Storage.StorageFile]::GetFileFromPathAsync($row.prepared)) ([Windows.Storage.StorageFile])
            $stream = Await-WinRT ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
            $decoder = Await-WinRT ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
            $bitmap = Await-WinRT ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
            $result = Await-WinRT ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
            $lines = @($result.Lines | ForEach-Object {
                @{ text = $_.Text; words = @($_.Words | ForEach-Object {
                    @{ text = $_.Text; x = $_.BoundingRect.X; y = $_.BoundingRect.Y; width = $_.BoundingRect.Width; height = $_.BoundingRect.Height }
                }) }
            })
            $writer.WriteLine((@{ source=$row.source; prepared=$row.prepared; scale=$row.scale; x=$row.x; y=$row.y; lines=$lines } | ConvertTo-Json -Depth 9 -Compress))
            $writer.Flush()
        } catch {
            $writer.WriteLine((@{ source=$row.source; error=$_.Exception.Message } | ConvertTo-Json -Compress))
            $writer.Flush()
        } finally {
            if ($null -ne $bitmap) { $bitmap.Dispose() }
            if ($null -ne $stream) { $stream.Dispose() }
        }
        $count += 1
        if ($count % 50 -eq 0) { Write-Output "OCR_PROGRESS $count/$($rows.Count)" }
    }
} finally { $writer.Dispose() }
Write-Output "OCR_COMPLETE $count"
