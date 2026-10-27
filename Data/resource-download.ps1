param([string]$Url, [string]$Destination, [string]$Status, [int]$Limit = 8388608)
$ErrorActionPreference = 'Stop'
function Report($value) {
    $value | ConvertTo-Json -Compress | Set-Content -LiteralPath ($Status + '.pending') -Encoding UTF8
    Move-Item -LiteralPath ($Status + '.pending') -Destination $Status -Force
}
try {
    $target = [Uri]$Url
    if ($target.Scheme -ne 'https' -or $target.Host -notin @('raw.githubusercontent.com', 'infinitefusion.net') -or
        $target.UserInfo -or $Limit -lt 1 -or $Limit -gt 8388608) { throw 'Invalid resource request' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $request = [Net.HttpWebRequest]::Create($target)
    $request.AllowAutoRedirect = $false
    $request.Timeout = 8000
    $request.ReadWriteTimeout = 5000
    $request.UserAgent = 'Mozilla/5.0 InfiniteFusionHD-Resources/1'
    if ($target.Host -eq 'infinitefusion.net') { $request.AddRange(0, $Limit - 1) }
    $response = $request.GetResponse()
    if ([int]$response.StatusCode -notin @(200, 206) -or $response.ContentLength -gt $Limit) { throw 'Invalid resource response' }
    $source = $response.GetResponseStream()
    $output = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    $buffer = New-Object byte[] 65536
    $received = 0
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $last = 0
    while (($count = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $received += $count
        if ($received -gt $Limit -or $timer.Elapsed.TotalSeconds -gt 25) { throw 'Resource limit or timeout exceeded' }
        $output.Write($buffer, 0, $count)
        if ($timer.ElapsedMilliseconds - $last -ge 200) {
            Report @{received=$received; done=$false}
            $last = $timer.ElapsedMilliseconds
        }
    }
    $output.Flush($true)
    $output.Dispose(); $output = $null
    Report @{received=$received; done=$true; ok=$true}
} catch {
    Report @{done=$true; ok=$false; error=$_.Exception.Message}
    exit 1
} finally {
    if ($output) { $output.Dispose() }
    if ($source) { $source.Dispose() }
    if ($response) { $response.Dispose() }
}
