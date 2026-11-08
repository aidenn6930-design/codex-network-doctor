Set-StrictMode -Version Latest
if ($PSVersionTable.PSVersion.Major -le 5) { Add-Type -AssemblyName System.Security }
Import-Module (Join-Path $PSScriptRoot 'CodexNetworkDoctor.psm1') -Force

function Get-CndRepairCandidates {
    param($Snapshot)
    $raw = @()
    if ($Snapshot.SystemProxy) { $raw += $Snapshot.SystemProxy }
    foreach ($name in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY') {
        $endpoint = Get-CndEndpoint $Snapshot.Variables.User[$name]
        if ($endpoint) { $raw += $endpoint }
    }
    $unique = @($raw | Where-Object { $_.IsLocal -and -not $_.HasCredentials -and $_.Scheme -eq 'http' } |
        Sort-Object SafeUrl -Unique)
    return @($unique)
}

function Get-CndRepairPlan {
    param($Snapshot,[int]$CandidateIndex=0)
    $candidates = @(Get-CndRepairCandidates $Snapshot)
    if (-not $candidates.Count) { throw 'No explicit, credential-free local HTTP proxy candidate was found.' }
    if ($candidates.Count -gt 1 -and $CandidateIndex -eq 0) { throw ('Multiple candidates: ' + (($candidates | ForEach-Object SafeUrl) -join ', ')) }
    if ($CandidateIndex -gt 0) {
        if ($CandidateIndex -gt $candidates.Count) { throw 'Candidate selection is out of range.' }
        $candidate = $candidates[$CandidateIndex-1]
    } else { $candidate = $candidates[0] }
    if (@($Snapshot.Listeners | Where-Object LocalPort -eq $candidate.Port).Count -eq 0) { throw 'Selected proxy port is not listening.' }
    $probe = Invoke-CndCurlProbe -Endpoint $candidate
    if ($probe.Status -ne 'Pass') { throw "Selected HTTP proxy failed bounded HTTPS check: $($probe.Status)." }
    $originalNoProxy = [string]$Snapshot.Variables.User.NO_PROXY
    $items = @('localhost','127.0.0.1','::1') + @($originalNoProxy -split ',' | ForEach-Object { $_.Trim() } | Where-Object {$_ -and $_ -notmatch '[\r\n]'})
    $seen = @{}; $merged = @()
    foreach ($item in $items) { if (-not $seen.ContainsKey($item.ToLowerInvariant())) { $seen[$item.ToLowerInvariant()]=$true; $merged += $item } }
    $target = [ordered]@{ HTTP_PROXY=$candidate.SafeUrl; HTTPS_PROXY=$candidate.SafeUrl; NO_PROXY=($merged -join ',') }
    $changes = @()
    foreach ($name in $target.Keys) {
        if ([string]$Snapshot.Variables.User[$name] -cne [string]$target[$name]) { $changes += $name }
    }
    [pscustomobject]@{ Candidate=$candidate.SafeUrl; Target=$target; Changes=$changes;
        Effect='New processes for this Windows user, including other applications, may inherit these proxy variables.' }
}

function Get-CndRegistryState {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment',$false)
    if (-not $key) { throw 'Current-user Environment registry key unavailable.' }
    try {
        $entries = [ordered]@{}
        foreach ($name in 'HTTP_PROXY','HTTPS_PROXY','NO_PROXY') {
            $exists = @($key.GetValueNames() | Where-Object {$_ -ieq $name}).Count -gt 0
            $entries[$name] = [ordered]@{ Exists=$exists; Value=if($exists){$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}else{$null};
                Kind=if($exists){$key.GetValueKind($name).ToString()}else{$null} }
        }
        return $entries
    } finally { $key.Close() }
}

function Test-CndStateEqual {
    param($Left,$Right)
    foreach ($name in 'HTTP_PROXY','HTTPS_PROXY','NO_PROXY') {
        if ([bool]$Left[$name].Exists -ne [bool]$Right[$name].Exists) { return $false }
        if ($Left[$name].Exists -and ([string]$Left[$name].Value -cne [string]$Right[$name].Value -or [string]$Left[$name].Kind -cne [string]$Right[$name].Kind)) { return $false }
    }
    return $true
}

function Set-CndRegistryState {
    param($State)
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment',$true)
    if (-not $key) { throw 'Current-user Environment registry key unavailable.' }
    try {
        foreach ($name in 'HTTP_PROXY','HTTPS_PROXY','NO_PROXY') {
            $entry = $State[$name]
            if ($entry.Exists) {
                $kind = [Enum]::Parse([Microsoft.Win32.RegistryValueKind],[string]$entry.Kind)
                $key.SetValue($name,[string]$entry.Value,$kind)
            } else { $key.DeleteValue($name,$false) }
        }
    } finally { $key.Close() }
}

function Save-CndBackup {
    param($Before,$After,[string]$BackupDirectory)
    [IO.Directory]::CreateDirectory($BackupDirectory) | Out-Null
    $payload = [ordered]@{ SchemaVersion=1; CreatedUtc=(Get-Date).ToUniversalTime().ToString('o'); Before=$Before; After=$After }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 8 -Compress))
    try {
        $cipher = [Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        $path = Join-Path $BackupDirectory ('backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N') + '.cndb')
        [IO.File]::WriteAllText($path,[Convert]::ToBase64String($cipher))
        return $path
    } finally { [Array]::Clear($bytes,0,$bytes.Length) }
}

function Read-CndBackup {
    param([string]$Path)
    $cipher = [Convert]::FromBase64String([IO.File]::ReadAllText($Path))
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect($cipher,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    try {
        $data = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
        if ($data.SchemaVersion -ne 1 -or -not $data.Before -or -not $data.After) { throw 'Invalid backup schema.' }
        return $data
    } finally { [Array]::Clear($bytes,0,$bytes.Length) }
}

function Convert-CndStateToMap {
    param($State)
    $map = [ordered]@{}
    foreach ($name in 'HTTP_PROXY','HTTPS_PROXY','NO_PROXY') { $map[$name]=$State.$name }
    return $map
}

function Invoke-CndRepair {
    param([int]$CandidateIndex=0,[string]$BackupDirectory)
    $snapshot = Get-CndSnapshot
    $findings = @(Resolve-CndFindings $snapshot | Where-Object RepairSupported)
    if (-not $findings.Count) { Write-Output 'No confirmed repairable user proxy mismatch; no changes made.'; return }
    $plan = Get-CndRepairPlan $snapshot $CandidateIndex
    if (-not $plan.Changes.Count) { Write-Output 'Proxy variables already match the validated candidate; no changes made.'; return }
    Write-Host "Validated candidate: $($plan.Candidate)"
    foreach ($name in $plan.Changes) { Write-Host "Will set user $name" }
    Write-Host $plan.Effect
    if ((Read-Host 'Type YES to approve these changes') -cne 'YES') { Write-Output 'Declined; no changes made.'; return }
    $before = Get-CndRegistryState
    $after = [ordered]@{}
    foreach ($name in 'HTTP_PROXY','HTTPS_PROXY','NO_PROXY') {
        $after[$name] = [ordered]@{ Exists=$true; Value=[string]$plan.Target[$name]; Kind='String' }
    }
    $backup = Save-CndBackup $before $after $BackupDirectory
    try {
        Set-CndRegistryState $after
        if (-not (Test-CndStateEqual (Get-CndRegistryState) $after)) { throw 'Post-write verification failed.' }
    } catch {
        $reason = $_.Exception.Message
        try { Set-CndRegistryState $before; if (-not (Test-CndStateEqual (Get-CndRegistryState) $before)) { throw 'Automatic restoration verification failed.' } }
        catch { throw "Repair failed ($reason); automatic restoration also failed. Backup: $backup. Restore manually." }
        throw "Repair failed ($reason); previous values restored. Backup: $backup"
    }
    Write-Output "Repair complete. Backup: $backup"
    try {
        $post = Invoke-CndDiagnosis
        Write-Output "Post-check: $($post.Summary.Errors) errors; $($post.Summary.Warnings) warnings. Restart Codex in a controlled way to refresh inherited environment."
    } catch {
        Write-Warning 'Repair is verified, but the follow-up diagnostic failed. Restart Codex in a controlled way and rerun diagnose.'
    }
}

function Invoke-CndRollback {
    param([string]$BackupPath)
    $backup = Read-CndBackup $BackupPath
    $before = Convert-CndStateToMap $backup.Before
    $after = Convert-CndStateToMap $backup.After
    $current = Get-CndRegistryState
    $conflict = -not (Test-CndStateEqual $current $after)
    if ($conflict) { Write-Warning 'Current settings differ from the values written by this backup. Newer changes may be overwritten.' }
    $deletions = @('HTTP_PROXY','HTTPS_PROXY','NO_PROXY' | Where-Object { $current[$_].Exists -and -not $before[$_].Exists })
    if ($deletions.Count) { Write-Warning "Rollback will remove these user variables because they were absent in the backup: $($deletions -join ', ')." }
    Write-Host 'Rollback restores the exact previous user proxy values and their defined/undefined state.'
    if ((Read-Host 'Type YES to approve rollback') -cne 'YES') { Write-Output 'Declined; no changes made.'; return }
    if ($conflict -and (Read-Host 'Type OVERWRITE to replace newer changes') -cne 'OVERWRITE') { Write-Output 'Conflict retained; no changes made.'; return }
    $safetyBackup = Save-CndBackup $current $before (Split-Path -Parent $BackupPath)
    try {
        Set-CndRegistryState $before
        if (-not (Test-CndStateEqual (Get-CndRegistryState) $before)) { throw 'Rollback verification failed.' }
        Write-Output "Rollback complete. Safety backup of pre-rollback state: $safetyBackup"
    } catch {
        $reason=$_.Exception.Message
        try { Set-CndRegistryState $current; if(-not (Test-CndStateEqual (Get-CndRegistryState) $current)){throw 'Pre-rollback state verification failed.'} }
        catch { throw "Rollback failed ($reason); automatic recovery failed. Safety backup: $safetyBackup" }
        throw "Rollback failed ($reason); pre-rollback state restored. Safety backup: $safetyBackup"
    }
}

Export-ModuleMember -Function Get-CndRepairCandidates,Get-CndRepairPlan,Get-CndRegistryState,Test-CndStateEqual,Save-CndBackup,Read-CndBackup,Invoke-CndRepair,Invoke-CndRollback
