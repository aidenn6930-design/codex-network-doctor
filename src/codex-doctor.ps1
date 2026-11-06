param(
    [Parameter(Position=0)][ValidateSet('diagnose','repair','rollback','version','help')][string]$Command='diagnose',
    [switch]$Detailed,[switch]$Json,[switch]$SkipNetwork,[int]$Candidate=0,[string]$Backup
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'CodexRepair.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CodexNetworkDoctor.psm1') -Force
try {
    switch ($Command) {
        'version' { 'Codex Network Doctor 0.1.0'; exit 0 }
        'help' {
            @'
Codex Network Doctor 0.1.0
  diagnose [-Detailed] [-Json] [-SkipNetwork]
  repair [-Candidate <1-based index>]
  rollback -Backup <path>
  version | help
No diagnostic command modifies settings. Repair and rollback require typed confirmation.
'@; exit 0
        }
        'diagnose' {
            $report=Invoke-CndDiagnosis -SkipNetwork:$SkipNetwork
            if ($Json) { $report | ConvertTo-Json -Depth 10; if($report.Summary.Errors){exit 2}; if($report.Summary.Warnings){exit 1}; exit 0 }
            'Codex Network Doctor 0.1.0'; '==========================='
            "OS: $($report.Platform.OS); PowerShell: $($report.Platform.PowerShell)"
            "Codex CLI: $(if($report.Platform.CodexCliVersion){$report.Platform.CodexCliVersion}else{'not found'})"
            "System proxy: $($report.Proxy.SystemEndpoint) (enabled=$($report.Proxy.SystemEnabled)); WinHTTP: $($report.Proxy.WinHttp)"
            "Candidate: $(if($report.Proxy.Candidate){$report.Proxy.Candidate}else{'none'})"
            if ($report.Probe) { "HTTPS probe: $($report.Probe.Status) $(if($report.Probe.HttpStatus){'HTTP '+$report.Probe.HttpStatus})" }
            if ($report.CodexDoctor) { "Codex Doctor: $($report.CodexDoctor.Status); WebSocket: $($report.CodexDoctor.WebSocket)" }
            foreach ($finding in $report.Findings) {
                "[$($finding.Severity.ToUpperInvariant())] $($finding.Code): $($finding.Evidence)"
                "  Next: $($finding.NextAction)"
                if($Detailed){"  Possible cause: $($finding.PossibleCause); confidence: $($finding.Confidence); automated repair: $($finding.RepairSupported)"}
            }
            "Summary: $($report.Summary.Errors) errors, $($report.Summary.Warnings) warnings. No changes made."
            if($report.Summary.Errors){exit 2}; if($report.Summary.Warnings){exit 1}; exit 0
        }
        'repair' { Invoke-CndRepair -CandidateIndex $Candidate -BackupDirectory (Join-Path (Split-Path -Parent $PSScriptRoot) 'backups'); exit 0 }
        'rollback' { if(-not $Backup){throw 'rollback requires -Backup'}; Invoke-CndRollback -BackupPath $Backup; exit 0 }
    }
} catch { Write-Error "Codex Network Doctor: $($_.Exception.Message)"; exit 3 }
