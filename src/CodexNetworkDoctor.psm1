Set-StrictMode -Version Latest

function Get-CndEndpoint {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $text = $Value.Trim()
    if ($text -match '(?i)(?:^|;)\s*https?=([^;]+)') { $text = $Matches[1].Trim() }
    if ($text -notmatch '^[a-z][a-z0-9+.-]*://') { $text = 'http://' + $text }
    try {
        $uri = [uri]$text
        if ($uri.Scheme -notin @('http','https','socks4','socks4a','socks5','socks5h') -or
            -not $uri.Host -or $uri.Port -lt 1 -or $uri.Port -gt 65535 -or
            $uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment) { return $null }
        $isLocal = $uri.IsLoopback
        $hostPart = if ($uri.Host.StartsWith('[')) { '[' + ([Net.IPAddress]::Parse($uri.DnsSafeHost)).ToString() + ']' } else { $uri.Host.ToLowerInvariant() }
        [pscustomobject]@{ Scheme=$uri.Scheme; Host=$uri.Host; Port=$uri.Port; IsLocal=$isLocal;
            HasCredentials=($uri.UserInfo.Length -gt 0); SafeUrl=('{0}://{1}:{2}' -f $uri.Scheme,$hostPart,$uri.Port) }
    } catch { return $null }
}

function Resolve-CndLauncherProxy {
    param([AllowNull()][string]$ProxyUrl,[AllowNull()][string]$HttpProxy,[AllowNull()][string]$HttpsProxy,
        [switch]$Explicit)
    if ($Explicit) {
        $endpoint = Get-CndEndpoint $ProxyUrl
    } else {
        $http = Get-CndEndpoint $HttpProxy
        $https = Get-CndEndpoint $HttpsProxy
        if (($HttpProxy -and -not $http) -or ($HttpsProxy -and -not $https) -or
            ($http -and $https -and $http.SafeUrl -ne $https.SafeUrl)) {
            throw 'User HTTP_PROXY and HTTPS_PROXY differ or cannot be parsed. Pass -ProxyUrl explicitly.'
        }
        $endpoint = if ($https) { $https } else { $http }
    }
    if (-not $endpoint -or $endpoint.Scheme -ne 'http' -or -not $endpoint.IsLocal -or $endpoint.HasCredentials) {
        throw 'Specify a valid, credential-free local HTTP proxy with -ProxyUrl, or configure matching user HTTP_PROXY and HTTPS_PROXY.'
    }
    return $endpoint
}

function Get-CndVariables {
    $result = [ordered]@{}
    foreach ($scope in 'Process','User','Machine') {
        $row = [ordered]@{}
        foreach ($name in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY','CODEX_CLI_PATH') {
            $row[$name] = [Environment]::GetEnvironmentVariable($name,$scope)
        }
        $result[$scope] = $row
    }
    return $result
}

function Resolve-CndCliPath {
    param([AllowNull()][string]$PathCommand,[bool]$DesktopInstalled,
        [AllowNull()][string]$BundleRoot,[string[]]$RunningPaths=@())
    if ($PathCommand -and (Test-Path -LiteralPath $PathCommand -PathType Leaf)) { return $PathCommand }
    if (-not $DesktopInstalled -or -not $BundleRoot -or -not (Test-Path -LiteralPath $BundleRoot -PathType Container)) { return $null }
    $root = [IO.Path]::GetFullPath($BundleRoot).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    foreach ($path in $RunningPaths) {
        if ($path -and $path.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath $path -PathType Leaf) -and
            [IO.Path]::GetFileName($path) -ieq 'codex.exe') { return $path }
    }
    $bundled = @(Get-ChildItem -LiteralPath $BundleRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Get-Item -LiteralPath (Join-Path $_.FullName 'codex.exe') -ErrorAction SilentlyContinue } |
        Sort-Object LastWriteTimeUtc -Descending)
    if ($bundled.Count) { return $bundled[0].FullName }
    return $null
}

function Get-CndSnapshot {
    $vars = Get-CndVariables
    $internet = try { Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop } catch { $null }
    $system = if ($internet) { Get-CndEndpoint $internet.ProxyServer } else { $null }
    $winHttp = try { (& netsh winhttp show proxy 2>$null | Out-String).Trim() } catch { 'Unavailable' }
    $desktop = @(Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue | Select-Object Name,Version)
    $processes = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^codex($|-)' } | Select-Object ProcessName,Id,Path)
    $cliCommand = Get-Command codex.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    $bundleRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'OpenAI\Codex\bin'
    $cliPath = Resolve-CndCliPath -PathCommand $(if($cliCommand){$cliCommand.Source}else{$null}) -DesktopInstalled ($desktop.Count -gt 0) -BundleRoot $bundleRoot -RunningPaths @($processes | Where-Object ProcessName -eq 'codex' | ForEach-Object Path)
    $cliVersion = $null; $doctorSupported = $false
    if ($cliPath) {
        try {
            $cliVersion = (& $cliPath --version 2>$null | Select-Object -First 1)
            $doctorSupported = ((& $cliPath doctor --help 2>$null | Out-String) -match '--network-only')
        } catch {}
    }
    $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object {
        $_.LocalAddress -in @('127.0.0.1','::1','0.0.0.0','::')
    } | Select-Object LocalAddress,LocalPort,OwningProcess)
    [pscustomobject]@{ OS=[Environment]::OSVersion.VersionString; PowerShell=$PSVersionTable.PSVersion.ToString();
        Variables=$vars; SystemProxyEnabled=if($internet){[bool]$internet.ProxyEnable}else{$null};
        SystemProxy=$system; WinHttp=$winHttp; CliPath=$cliPath;
        CliVersion=$cliVersion; DoctorSupported=$doctorSupported; Desktop=$desktop;
        Processes=$processes; Listeners=$listeners }
}

function New-CndFinding {
    param([string]$Code,[string]$Severity,[string]$Evidence,[string]$Cause,[string]$Confidence,[string]$Action,[bool]$Repairable=$false)
    [pscustomobject]@{ Code=$Code; Severity=$Severity; Evidence=$Evidence; PossibleCause=$Cause;
        Confidence=$Confidence; NextAction=$Action; RepairSupported=$Repairable }
}

function Resolve-CndFindings {
    param([Parameter(Mandatory)]$Snapshot)
    $findings = [Collections.Generic.List[object]]::new()
    $user = $Snapshot.Variables.User
    $http = Get-CndEndpoint $user.HTTP_PROXY
    $https = Get-CndEndpoint $user.HTTPS_PROXY
    $system = $Snapshot.SystemProxy
    $candidate = if ($Snapshot.SystemProxyEnabled -and $system -and $system.IsLocal) { $system } elseif ($http -and $http.IsLocal) { $http } elseif ($https -and $https.IsLocal) { $https } else { $null }
    if (-not $http -and -not $https -and $candidate) {
        $findings.Add((New-CndFinding PROXY_NOT_CONFIGURED Warning 'User HTTP_PROXY and HTTPS_PROXY absent' 'A local system proxy may not be inherited by Codex' Medium 'Validate the local proxy, then review the repair plan' $true))
    }
    if (($http -and $https -and $http.SafeUrl -ne $https.SafeUrl) -or
        (($user.HTTP_PROXY -and -not $http) -or ($user.HTTPS_PROXY -and -not $https))) {
        $findings.Add((New-CndFinding PROXY_ENV_CONFLICT Warning 'User proxy URLs differ or cannot be parsed' 'Stale or malformed user environment variable' High 'Review explicit endpoints before repair' $true))
    }
    if ($system -and $system.IsLocal -and $http -and $http.IsLocal -and $system.Port -ne $http.Port) {
        $findings.Add((New-CndFinding PROXY_PORT_MISMATCH Warning "Configured system port $($system.Port), user port $($http.Port)" 'One configuration may be stale' Medium 'Validate both candidates and choose the intended proxy' $true))
    }
    foreach ($scope in 'Process','User','Machine') {
        $path = $Snapshot.Variables[$scope].CODEX_CLI_PATH
        if ($path -and -not (Test-Path -LiteralPath $path)) {
            $findings.Add((New-CndFinding STALE_CODEX_CLI_PATH Warning "$scope CODEX_CLI_PATH does not exist" 'Outdated runtime override' High 'Remove or correct this override separately' $false))
        }
    }
    if (-not $Snapshot.CliPath) { $findings.Add((New-CndFinding CODEX_NOT_INSTALLED Info 'codex.exe not found on PATH or in the Codex Desktop bundle' 'CLI may not be installed' Medium 'Check the Codex CLI installation if terminal use is needed' $false)) }
    if ($candidate) {
        $listening = @($Snapshot.Listeners | Where-Object LocalPort -eq $candidate.Port).Count -gt 0
        if (-not $listening) { $findings.Add((New-CndFinding PROXY_CONNECTION_FAILED Error "Configured local port $($candidate.Port) is not listening" 'Proxy software stopped or port changed' High 'Start proxy software or update its documented port' $false)) }
    }
    return @($findings.ToArray())
}

function Invoke-CndCurlProbe {
    param([Parameter(Mandatory)]$Endpoint,[string]$Url='https://chatgpt.com/',[int]$TimeoutSeconds=12)
    if ($Endpoint.HasCredentials) { return [pscustomobject]@{ Status='Unsupported'; HttpStatus=$null; Detail='Credential-bearing proxy URL is not probed' } }
    if ($Endpoint.Scheme -notin @('http','https','socks4','socks4a','socks5','socks5h')) { return [pscustomobject]@{ Status='Unsupported'; HttpStatus=$null; Detail='Unsupported proxy scheme' } }
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { return [pscustomobject]@{ Status='Unsupported'; HttpStatus=$null; Detail='curl.exe unavailable' } }
    try {
        $code = & curl.exe --silent --output NUL --write-out '%{http_code}' --connect-timeout 5 --max-time $TimeoutSeconds --proxy $Endpoint.SafeUrl $Url 2>$null
        $exit = $LASTEXITCODE
        $status = Get-CndProbeStatus -ExitCode $exit -HttpCode $code
        [pscustomobject]@{ Status=$status; HttpStatus=if($code -match '^\d{3}$'){[int]$code}else{$null}; Detail="curl exit $exit" }
    } catch { [pscustomobject]@{ Status='Unknown'; HttpStatus=$null; Detail='Probe invocation failed' } }
}

function Invoke-CndDirectCurlProbe {
    param([string]$Url='https://chatgpt.com/',[int]$TimeoutSeconds=8)
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { return [pscustomobject]@{ Status='Unsupported'; HttpStatus=$null; Detail='curl.exe unavailable' } }
    try {
        $code = & curl.exe --silent --output NUL --write-out '%{http_code}' --connect-timeout 5 --max-time $TimeoutSeconds --noproxy '*' $Url 2>$null
        $exit = $LASTEXITCODE
        [pscustomobject]@{ Status=(Get-CndProbeStatus -ExitCode $exit -HttpCode $code); HttpStatus=if($code -match '^\d{3}$'){[int]$code}else{$null}; Detail="curl exit $exit" }
    } catch { [pscustomobject]@{ Status='Unknown'; HttpStatus=$null; Detail='Probe invocation failed' } }
}

function Resolve-CndDesktopRouteFinding {
    param($Snapshot,$ProxyProbe,$DirectProbe)
    if ($Snapshot.Desktop.Count -eq 0 -or $Snapshot.SystemProxyEnabled -ne $false -or
        -not $ProxyProbe -or $ProxyProbe.Status -ne 'Pass' -or -not $DirectProbe -or
        $DirectProbe.Status -notin @('Timeout','DnsFailure','TlsFailure','ConnectionFailure')) { return $null }
    New-CndFinding -Code DESKTOP_PROXY_ROUTE_GAP -Severity Warning -Evidence "Direct HTTPS: $($DirectProbe.Status); local proxy HTTPS: Pass; Windows system proxy: off" -Cause 'Desktop window requests may use a different route from CLI checks' -Confidence Medium -Action 'Inspect desktop network logs; if requests time out, try the app-only proxy launcher after exiting Codex' -Repairable $false
}

function Get-CndProbeStatus {
    param([int]$ExitCode,[string]$HttpCode)
    if ($ExitCode -eq 0 -and $HttpCode -eq '200') { return 'Pass' }
    if ($ExitCode -eq 28) { return 'Timeout' }
    if ($ExitCode -in @(5,6)) { return 'DnsFailure' }
    if ($ExitCode -in @(35,60)) { return 'TlsFailure' }
    if ($ExitCode -ne 0) { return 'ConnectionFailure' }
    return 'HttpError'
}

function Invoke-CndDoctor {
    param($Snapshot)
    if (-not $Snapshot.CliPath -or -not $Snapshot.DoctorSupported) { return [pscustomobject]@{ Status='Unsupported'; WebSocket='Unsupported'; Summary='Codex doctor --network-only unavailable' } }
    try {
        $output = & $Snapshot.CliPath doctor --network-only --summary --ascii --no-color 2>$null | Out-String
        if ($output -match '(\d+) ok \| (\d+) warn \| (\d+) fail') {
            $okCount=$Matches[1]; $warnCount=$Matches[2]; $failCount=$Matches[3]
            $status = if ([int]$failCount -gt 0) {'Fail'} elseif([int]$warnCount -gt 0){'Warn'}else{'Pass'}
            $ws = if ($output -match 'websocket\s+connected \(HTTP 101') {'Pass'} elseif ($output -match 'websocket\s+\[fail\]') {'Fail'} else {'Unknown'}
            return [pscustomobject]@{ Status=$status; WebSocket=$ws; Summary="$okCount ok; $warnCount warn; $failCount fail" }
        }
    } catch {}
    [pscustomobject]@{ Status='Unknown'; WebSocket='Unknown'; Summary='Unable to parse Codex doctor summary' }
}

function Invoke-CndDiagnosis {
    param([switch]$SkipNetwork,[switch]$CheckDesktopPath)
    if ($SkipNetwork -and $CheckDesktopPath) { throw '-CheckDesktopPath requires network checks; omit -SkipNetwork.' }
    $snapshot = Get-CndSnapshot
    $findings = [Collections.Generic.List[object]]::new()
    foreach ($item in @(Resolve-CndFindings $snapshot)) { $findings.Add($item) }
    $userHttp = Get-CndEndpoint $snapshot.Variables.User.HTTP_PROXY
    $userHttps = Get-CndEndpoint $snapshot.Variables.User.HTTPS_PROXY
    $candidate = if ($snapshot.SystemProxyEnabled -and $snapshot.SystemProxy -and $snapshot.SystemProxy.IsLocal) {$snapshot.SystemProxy} elseif ($userHttp -and $userHttp.IsLocal) {$userHttp} elseif ($userHttps -and $userHttps.IsLocal) {$userHttps} else {$null}
    $probe = $null; $doctor = $null; $directProbe = $null
    if (-not $SkipNetwork) {
        if ($candidate -and $candidate.IsLocal -and @($snapshot.Listeners | Where-Object LocalPort -eq $candidate.Port).Count -gt 0) {
            $probe = Invoke-CndCurlProbe $candidate
            switch ($probe.Status) {
                'Timeout' { $findings.Add((New-CndFinding PROXY_CONNECTION_FAILED Error 'HTTPS probe timed out' 'Proxy or network path unresponsive' Medium 'Check proxy software and route' $false)) }
                'DnsFailure' { $findings.Add((New-CndFinding DNS_FAILURE Error 'curl DNS failure' 'Proxy or local resolver failed' Medium 'Check DNS and proxy software' $false)) }
                'TlsFailure' { $findings.Add((New-CndFinding TLS_FAILURE Error 'curl TLS failure' 'Certificate or handshake issue' Medium 'Inspect trusted certificates and proxy TLS mode' $false)) }
                'ConnectionFailure' { $findings.Add((New-CndFinding PROXY_CONNECTION_FAILED Error 'curl connection failed' 'Proxy or upstream connection issue' Medium 'Check listener and proxy logs' $false)) }
                'HttpError' { $findings.Add((New-CndFinding UPSTREAM_SERVICE_FAILURE Warning "Homepage returned HTTP $($probe.HttpStatus)" 'Upstream response or challenge; root cause unclear' Low 'Use Codex Doctor and inspect service status' $false)) }
            }
        }
        $doctor = Invoke-CndDoctor $snapshot
        if ($doctor.WebSocket -eq 'Fail') { $findings.Add((New-CndFinding WEBSOCKET_FAILURE Error 'Codex Doctor WebSocket check failed' 'Proxy upgrade or upstream path issue' Medium 'Review full Codex Doctor output locally' $false)) }
        if ($CheckDesktopPath) {
            $directProbe = Invoke-CndDirectCurlProbe
            $routeFinding = Resolve-CndDesktopRouteFinding -Snapshot $snapshot -ProxyProbe $probe -DirectProbe $directProbe
            if ($routeFinding) { $findings.Add($routeFinding) }
        }
    }
    $safeVars = [ordered]@{}
    foreach ($scope in 'Process','User','Machine') {
        $row = [ordered]@{}
        foreach ($name in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY') { $endpoint=Get-CndEndpoint $snapshot.Variables[$scope][$name]; $row[$name]=if($endpoint){$endpoint.SafeUrl}else{$null} }
        $row.NO_PROXY = if($snapshot.Variables[$scope].NO_PROXY){'configured'}else{'absent'}
        $row.CODEX_CLI_PATH = if($snapshot.Variables[$scope].CODEX_CLI_PATH){'configured'}else{'absent'}
        $safeVars[$scope] = $row
    }
    [pscustomobject]@{ SchemaVersion='1.0'; ToolVersion='0.1.0'; GeneratedAt=(Get-Date).ToUniversalTime().ToString('o');
        Platform=[pscustomobject]@{ OS=$snapshot.OS; PowerShell=$snapshot.PowerShell; CodexCliVersion=$snapshot.CliVersion;
            CodexDesktopVersion=if($snapshot.Desktop.Count){[string]$snapshot.Desktop[0].Version}else{$null}; DoctorSupported=$snapshot.DoctorSupported };
        Proxy=[pscustomobject]@{ SystemEnabled=$snapshot.SystemProxyEnabled; SystemEndpoint=if($snapshot.SystemProxy){$snapshot.SystemProxy.SafeUrl}else{$null};
            WinHttp=if($snapshot.WinHttp -match '(?i)direct access|直接访问'){'direct'}else{'configured-or-unknown'};
            Variables=$safeVars; Candidate=if($candidate){$candidate.SafeUrl}else{$null} };
        Probe=$probe; DesktopDirectProbe=$directProbe; CodexDoctor=$doctor; Findings=@($findings.ToArray());
        Summary=[pscustomobject]@{ Errors=@($findings | Where-Object Severity -eq Error).Count; Warnings=@($findings | Where-Object Severity -eq Warning).Count } }
}

Export-ModuleMember -Function Get-CndEndpoint,Resolve-CndLauncherProxy,Get-CndSnapshot,Resolve-CndCliPath,Resolve-CndFindings,Get-CndProbeStatus,Invoke-CndCurlProbe,Invoke-CndDirectCurlProbe,Resolve-CndDesktopRouteFinding,Invoke-CndDoctor,Invoke-CndDiagnosis
