# Isolated Windows HTTPS transport for the embedded Ruby runtime (which has no
# OpenSSL). No interpolated commands, external modules, or credentials are used.
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Endpoint)
$ErrorActionPreference = 'Stop'
try {
    $target = [Uri]$Endpoint
    if (!$target.IsAbsoluteUri -or $target.Scheme -cne 'https' -or !$target.Host -or
        $target.UserInfo -or $target.Fragment -or $target.Query) { exit 2 }
    $payload = [Console]::In.ReadToEnd()
    if (!$payload -or $payload.Length -gt 4096 -or $payload -match '[^\x20-\x7e]') { exit 2 }
    $request = New-Object -ComObject WinHttp.WinHttpRequest.5.1
    $request.SetTimeouts(2000, 2000, 2000, 2000)
    $request.Open('POST', $target.AbsoluteUri, $false)
    $request.Option(6) = $false # Never redirect the visitor identifier.
    $request.Option(9) = 2048 # TLS 1.2; keep system certificate/hostname checks.
    $request.SetAutoLogonPolicy(2) # Never send Windows credentials.
    $request.SetRequestHeader('Content-Type', 'application/x-www-form-urlencoded')
    $request.SetRequestHeader('User-Agent', 'KIF-Analytics/1 (Windows)')
    $request.Send($payload)
    if ($request.Status -ge 200 -and $request.Status -lt 300) { exit 0 }
    exit 1
} catch {
    # Analytics failures must never display UI, payloads, or local user paths.
    exit 1
}
