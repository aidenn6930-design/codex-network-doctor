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

Describe 'Codex CLI discovery' {
    It 'finds the desktop bundled CLI when it is absent from PATH' {
        $root=Join-Path $TestDrive 'bin'
        $version=Join-Path $root 'version1'
        New-Item -ItemType Directory -Path $version -Force | Out-Null
        $cli=Join-Path $version 'codex.exe'
        New-Item -ItemType File -Path $cli | Out-Null
        (Resolve-CndCliPath -PathCommand $null -DesktopInstalled $true -BundleRoot $root) | Should Be $cli
    }
    It 'prefers the running desktop CLI over another bundled version' {
        $root=Join-Path $TestDrive 'bin'
        $old=Join-Path $root 'old'
        $new=Join-Path $root 'new'
        New-Item -ItemType Directory -Path $old,$new -Force | Out-Null
        $running=Join-Path $old 'codex.exe'
        New-Item -ItemType File -Path $running | Out-Null
        New-Item -ItemType File -Path (Join-Path $new 'codex.exe') | Out-Null
        (Resolve-CndCliPath -PathCommand $null -DesktopInstalled $true -BundleRoot $root -RunningPaths @($running)) | Should Be $running
    }
    It 'does not treat a leftover bundle as an installed desktop app' {
        $root=Join-Path $TestDrive 'bin'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        (Resolve-CndCliPath -PathCommand $null -DesktopInstalled $false -BundleRoot $root) | Should BeNullOrEmpty
    }
}

Describe 'App-only desktop proxy launcher' {
    It 'uses matching user proxy settings without a fixed port' {
        $e=Resolve-CndLauncherProxy -HttpProxy 'http://127.0.0.1:8111' -HttpsProxy '127.0.0.1:8111'
        $e.SafeUrl | Should Be 'http://127.0.0.1:8111'
    }
    It 'rejects a malformed user proxy even when the other variable is valid' {
        $threw=$false; try { Resolve-CndLauncherProxy -HttpProxy 'http://bad host:7892' -HttpsProxy 'http://127.0.0.1:7892' | Out-Null } catch { $threw=$true }; $threw | Should Be $true
    }
    It 'rejects mismatched user proxy settings' {
        $threw=$false; try { Resolve-CndLauncherProxy -HttpProxy 'http://127.0.0.1:7892' -HttpsProxy 'http://127.0.0.1:7893' | Out-Null } catch { $threw=$true }; $threw | Should Be $true
    }
    It 'rejects remote and credential-bearing launch proxies' {
        $threw=$false; try { Resolve-CndLauncherProxy -ProxyUrl 'http://proxy.example.com:8080' -Explicit | Out-Null } catch { $threw=$true }; $threw | Should Be $true
        $threw=$false; try { Resolve-CndLauncherProxy -ProxyUrl 'http://user:secret@127.0.0.1:7892' -Explicit | Out-Null } catch { $threw=$true }; $threw | Should Be $true
    }
    It 'allows an explicit local proxy to override user settings' {
        (Resolve-CndLauncherProxy -ProxyUrl 'http://127.0.0.1:8111' -Explicit -HttpProxy 'broken value').Port | Should Be 8111
    }
}

Describe 'Desktop route comparison' {
    It 'warns when direct access fails but the configured local proxy succeeds' {
        $s=[pscustomobject]@{Desktop=@([pscustomobject]@{Name='OpenAI.Codex'});SystemProxyEnabled=$false}
        $finding=Resolve-CndDesktopRouteFinding -Snapshot $s -ProxyProbe ([pscustomobject]@{Status='Pass'}) -DirectProbe ([pscustomobject]@{Status='Timeout'})
        $finding.Code | Should Be 'DESKTOP_PROXY_ROUTE_GAP'
        $finding.Severity | Should Be 'Warning'
    }
    It 'does not infer a route gap when direct access succeeds or the system proxy is enabled' {
        $s=[pscustomobject]@{Desktop=@([pscustomobject]@{Name='OpenAI.Codex'});SystemProxyEnabled=$false}
        (Resolve-CndDesktopRouteFinding -Snapshot $s -ProxyProbe ([pscustomobject]@{Status='Pass'}) -DirectProbe ([pscustomobject]@{Status='Pass'})) | Should BeNullOrEmpty
        $s.SystemProxyEnabled=$true
        (Resolve-CndDesktopRouteFinding -Snapshot $s -ProxyProbe ([pscustomobject]@{Status='Pass'}) -DirectProbe ([pscustomobject]@{Status='Timeout'})) | Should BeNullOrEmpty
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

Describe 'Interactive safety gates' {
    It 'does not write when repair approval is refused' {
        Mock Get-CndSnapshot { [pscustomobject]@{} } -ModuleName CodexRepair
        Mock Resolve-CndFindings { [pscustomobject]@{RepairSupported=$true} } -ModuleName CodexRepair
        Mock Get-CndRepairPlan { [pscustomobject]@{Candidate='http://127.0.0.1:7892';Changes=@('HTTP_PROXY');Effect='Other apps may be affected';Target=@{}} } -ModuleName CodexRepair
        Mock Read-Host { 'NO' } -ModuleName CodexRepair
        Mock Set-CndRegistryState {} -ModuleName CodexRepair
        Invoke-CndRepair -BackupDirectory $TestDrive | Out-Null
        Assert-MockCalled Set-CndRegistryState -Times 0 -ModuleName CodexRepair
    }
    It 'restores backed-up state and checks it during rollback' {
        $global:CndTestRestored=$false
        $global:CndTestBefore=[ordered]@{HTTP_PROXY=@{Exists=$false;Value=$null;Kind=$null};HTTPS_PROXY=@{Exists=$true;Value='';Kind='String'};NO_PROXY=@{Exists=$true;Value='localhost';Kind='String'}}
        $global:CndTestAfter=[ordered]@{HTTP_PROXY=@{Exists=$true;Value='http://127.0.0.1:7892';Kind='String'};HTTPS_PROXY=@{Exists=$true;Value='http://127.0.0.1:7892';Kind='String'};NO_PROXY=@{Exists=$true;Value='localhost,127.0.0.1,::1';Kind='String'}}
        Mock Read-CndBackup { [pscustomobject]@{Before=[pscustomobject]$global:CndTestBefore;After=[pscustomobject]$global:CndTestAfter} } -ModuleName CodexRepair
        Mock Get-CndRegistryState { if($global:CndTestRestored){$global:CndTestBefore}else{$global:CndTestAfter} } -ModuleName CodexRepair
        Mock Set-CndRegistryState { $global:CndTestRestored=$true } -ModuleName CodexRepair
        Mock Save-CndBackup { 'safety.cndb' } -ModuleName CodexRepair
        Mock Read-Host { 'YES' } -ModuleName CodexRepair
        Invoke-CndRollback -BackupPath (Join-Path $TestDrive 'dummy.cndb') | Out-Null
        $global:CndTestRestored | Should Be $true
        Assert-MockCalled Set-CndRegistryState -Times 1 -ModuleName CodexRepair
        Remove-Variable CndTestRestored -Scope Global
        Remove-Variable CndTestBefore -Scope Global
        Remove-Variable CndTestAfter -Scope Global
    }
    It 'keeps verified repaired variables if the follow-up diagnostic fails' {
        $global:CndRepairWritten=$false
        $global:CndRepairBefore=[ordered]@{HTTP_PROXY=@{Exists=$false;Value=$null;Kind=$null};HTTPS_PROXY=@{Exists=$false;Value=$null;Kind=$null};NO_PROXY=@{Exists=$true;Value='localhost';Kind='String'}}
        $global:CndRepairAfter=[ordered]@{HTTP_PROXY=@{Exists=$true;Value='http://127.0.0.1:7892';Kind='String'};HTTPS_PROXY=@{Exists=$true;Value='http://127.0.0.1:7892';Kind='String'};NO_PROXY=@{Exists=$true;Value='localhost,127.0.0.1,::1';Kind='String'}}
        Mock Get-CndSnapshot { [pscustomobject]@{} } -ModuleName CodexRepair
        Mock Resolve-CndFindings { [pscustomobject]@{RepairSupported=$true} } -ModuleName CodexRepair
        Mock Get-CndRepairPlan { [pscustomobject]@{Candidate='http://127.0.0.1:7892';Changes=@('HTTP_PROXY','HTTPS_PROXY','NO_PROXY');Effect='User environment changes';Target=@{HTTP_PROXY='http://127.0.0.1:7892';HTTPS_PROXY='http://127.0.0.1:7892';NO_PROXY='localhost,127.0.0.1,::1'}} } -ModuleName CodexRepair
        Mock Read-Host { 'YES' } -ModuleName CodexRepair
        Mock Get-CndRegistryState { if($global:CndRepairWritten){$global:CndRepairAfter}else{$global:CndRepairBefore} } -ModuleName CodexRepair
        Mock Set-CndRegistryState { $global:CndRepairWritten=$true } -ModuleName CodexRepair
        Mock Save-CndBackup { 'backup.cndb' } -ModuleName CodexRepair
        Mock Invoke-CndDiagnosis { throw 'Probe unavailable' } -ModuleName CodexRepair
        $output=Invoke-CndRepair -BackupDirectory $TestDrive 3>&1 | Out-String
        $global:CndRepairWritten | Should Be $true
        $output | Should Match 'Repair complete'
        $output | Should Match 'follow-up diagnostic failed'
        Assert-MockCalled Set-CndRegistryState -Times 1 -ModuleName CodexRepair
        Remove-Variable CndRepairWritten,CndRepairBefore,CndRepairAfter -Scope Global
    }
    It 'warns before rollback would remove variables and respects refusal' {
        $global:CndRollbackWritten=$false
        $global:CndRollbackBefore=[ordered]@{HTTP_PROXY=@{Exists=$false;Value=$null;Kind=$null};HTTPS_PROXY=@{Exists=$false;Value=$null;Kind=$null};NO_PROXY=@{Exists=$true;Value='localhost';Kind='String'}}
        $global:CndRollbackAfter=[ordered]@{HTTP_PROXY=@{Exists=$true;Value='http://127.0.0.1:7892';Kind='String'};HTTPS_PROXY=@{Exists=$true;Value='http://127.0.0.1:7892';Kind='String'};NO_PROXY=@{Exists=$true;Value='localhost';Kind='String'}}
        Mock Read-CndBackup { [pscustomobject]@{Before=[pscustomobject]$global:CndRollbackBefore;After=[pscustomobject]$global:CndRollbackAfter} } -ModuleName CodexRepair
        Mock Get-CndRegistryState { $global:CndRollbackAfter } -ModuleName CodexRepair
        Mock Read-Host { 'NO' } -ModuleName CodexRepair
        Mock Set-CndRegistryState { $global:CndRollbackWritten=$true } -ModuleName CodexRepair
        $output=Invoke-CndRollback -BackupPath (Join-Path $TestDrive 'dummy.cndb') 3>&1 | Out-String
        $output | Should Match 'Rollback will remove these user variables.*HTTP_PROXY, HTTPS_PROXY'
        $global:CndRollbackWritten | Should Be $false
        Remove-Variable CndRollbackWritten,CndRollbackBefore,CndRollbackAfter -Scope Global
    }
}
