$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src/CodexRepair.psm1') -Force
Import-Module (Join-Path $root 'src/CodexNetworkDoctor.psm1') -Force

function New-TestSnapshot([string]$systemUrl,[bool]$enabled,[string]$http,[string]$https,[int[]]$ports=@(7892)) {
    $vars = [ordered]@{
        Process=[ordered]@{HTTP_PROXY=$null;HTTPS_PROXY=$null;ALL_PROXY=$null;NO_PROXY=$null;CODEX_CLI_PATH=$null}
        User=[ordered]@{HTTP_PROXY=$http;HTTPS_PROXY=$https;ALL_PROXY=$null;NO_PROXY='localhost';CODEX_CLI_PATH=$null}
        Machine=[ordered]@{HTTP_PROXY=$null;HTTPS_PROXY=$null;ALL_PROXY=$null;NO_PROXY=$null;CODEX_CLI_PATH=$null}
    }
    [pscustomobject]@{Variables=$vars;SystemProxy=Get-CndEndpoint $systemUrl;SystemProxyEnabled=$enabled;
        Listeners=@($ports | ForEach-Object {[pscustomobject]@{LocalPort=$_}});CliPath=$null}
}

Describe 'Proxy parsing and classification' {
    It 'accepts IPv6 loopback without leaking credentials' {
        $e=Get-CndEndpoint 'http://user:secret@[::1]:7892'
        $e.IsLocal | Should Be $true
        $e.HasCredentials | Should Be $true
        $e.SafeUrl | Should Be 'http://[::1]:7892'
    }
    It 'recognizes SOCKS and rejects malformed URLs' {
        (Get-CndEndpoint 'socks5://127.0.0.1:1080').Scheme | Should Be 'socks5'
        (Get-CndEndpoint 'http://bad host:7892') | Should BeNullOrEmpty
    }
    It 'detects a missing user proxy when the system proxy is explicit' {
        $s=New-TestSnapshot 'http://127.0.0.1:7892' $true $null $null
        @(Resolve-CndFindings $s | Where-Object Code -eq PROXY_NOT_CONFIGURED).Count | Should Be 1
    }
    It 'does not flag matching proxies' {
        $s=New-TestSnapshot 'http://127.0.0.1:7892' $true 'http://127.0.0.1:7892' 'http://127.0.0.1:7892'
        @(Resolve-CndFindings $s).Count | Should Be 1 # CLI deliberately missing
    }
    It 'detects port mismatch and stopped listener' {
        $s=New-TestSnapshot 'http://127.0.0.1:7892' $true 'http://127.0.0.1:7893' 'http://127.0.0.1:7893' @(7893)
        @(Resolve-CndFindings $s | Where-Object Code -eq PROXY_PORT_MISMATCH).Count | Should Be 1
        @(Resolve-CndFindings $s | Where-Object Code -eq PROXY_CONNECTION_FAILED).Count | Should Be 1
    }
    It 'detects stale CLI override' {
        $s=New-TestSnapshot $null $false $null $null
        $s.Variables.User.CODEX_CLI_PATH='X:\unlikely\missing-codex.exe'
        @(Resolve-CndFindings $s | Where-Object Code -eq STALE_CODEX_CLI_PATH).Count | Should Be 1
    }
}

Describe 'Repair planning' {
    Mock Invoke-CndCurlProbe { [pscustomobject]@{Status='Pass';HttpStatus=200} } -ModuleName CodexRepair
    It 'requires selection when multiple explicit candidates exist' {
        $s=New-TestSnapshot 'http://127.0.0.1:7892' $true 'http://127.0.0.1:7893' 'http://127.0.0.1:7893' @(7892,7893)
        @(Get-CndRepairCandidates $s).Count | Should Be 2
    }
    It 'merges local NO_PROXY entries and only plans user variables' {
        $s=New-TestSnapshot 'http://127.0.0.1:7892' $true $null $null
        $plan=Get-CndRepairPlan $s
        $plan.Target.NO_PROXY | Should Be 'localhost,127.0.0.1,::1'
        $plan.Changes.Count | Should Be 3
    }
    It 'rejects SOCKS as an HTTP repair candidate' {
        $s=New-TestSnapshot 'socks5://127.0.0.1:7892' $true $null $null
        @(Get-CndRepairCandidates $s).Count | Should Be 0
    }
}

Describe 'Backup data and rollback comparison' {
    It 'preserves undefined versus empty values' {
        $a=[ordered]@{HTTP_PROXY=@{Exists=$false;Value=$null;Kind=$null};HTTPS_PROXY=@{Exists=$true;Value='';Kind='String'};NO_PROXY=@{Exists=$true;Value='localhost';Kind='String'}}
        $b=[ordered]@{HTTP_PROXY=@{Exists=$true;Value='';Kind='String'};HTTPS_PROXY=@{Exists=$true;Value='';Kind='String'};NO_PROXY=@{Exists=$true;Value='localhost';Kind='String'}}
        (Test-CndStateEqual $a $b) | Should Be $false
    }
    It 'round trips a DPAPI backup without modifying environment settings' {
        $a=[ordered]@{HTTP_PROXY=@{Exists=$false;Value=$null;Kind=$null};HTTPS_PROXY=@{Exists=$true;Value='';Kind='String'};NO_PROXY=@{Exists=$true;Value='localhost';Kind='String'}}
        $dir=Join-Path $TestDrive 'backups'
        $path=Save-CndBackup $a $a $dir
        $data=Read-CndBackup $path
        $data.Before.HTTP_PROXY.Exists | Should Be $false
        $data.Before.HTTPS_PROXY.Value | Should Be ''
    }
}

Describe 'Bounded probe result classification' {
    It 'keeps HTTP 403 and 432 distinct from transport errors' {
        (Get-CndProbeStatus 0 '403') | Should Be 'HttpError'
        (Get-CndProbeStatus 0 '432') | Should Be 'HttpError'
    }
    It 'classifies timeout, DNS, and TLS curl failures' {
        (Get-CndProbeStatus 28 '000') | Should Be 'Timeout'
        (Get-CndProbeStatus 6 '000') | Should Be 'DnsFailure'
        (Get-CndProbeStatus 60 '000') | Should Be 'TlsFailure'
    }
}
