param([string]$ProxyUrl,[switch]$Preview)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CodexNetworkDoctor.psm1') -Force

if ($PSBoundParameters.ContainsKey('ProxyUrl')) {
    $endpoint = Resolve-CndLauncherProxy -ProxyUrl $ProxyUrl -Explicit
} else {
    $endpoint = Resolve-CndLauncherProxy -HttpProxy ([Environment]::GetEnvironmentVariable('HTTP_PROXY','User')) -HttpsProxy ([Environment]::GetEnvironmentVariable('HTTPS_PROXY','User'))
}
$proxy = $endpoint.SafeUrl.Substring('http://'.Length)
$package = Get-AppxPackage -Name OpenAI.Codex | Select-Object -First 1
if (-not $package) { throw 'Codex Desktop is not installed for the current Windows user.' }

$executable = Join-Path $package.InstallLocation 'app\ChatGPT.exe'
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw "Codex Desktop executable was not found: $executable" }
$arguments = @(
    "--proxy-server=$proxy"
    '--proxy-bypass-list=localhost;127.0.0.1;[::1]'
)
if ($Preview) {
    [pscustomobject]@{ Executable=$executable; Proxy=$endpoint.SafeUrl; Arguments=$arguments; WindowsSystemProxyChanged=$false }
    return
}

if (-not @(Get-NetTCPConnection -State Listen -LocalPort $endpoint.Port -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalAddress -in @('127.0.0.1','::1','0.0.0.0','::') }).Count) {
    throw "The local proxy is not listening on port $($endpoint.Port). Start it before opening Codex."
}

$running = @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -ieq $executable -or $_.Path -match '(?i)\\WindowsApps\\OpenAI\.Codex_[^\\]+\\app\\ChatGPT\.exe$'
})
if ($running.Count) {
    throw 'Codex Desktop is already running. Close it normally, then run this script from a separate PowerShell window so the launch arguments take effect.'
}

Start-Process -FilePath $executable -ArgumentList $arguments
Write-Output 'Started Codex Desktop with a proxy for this app only. Windows system proxy settings were not changed.'
