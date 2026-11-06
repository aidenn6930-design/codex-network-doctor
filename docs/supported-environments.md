# Supported environments

Target: Windows 10/11, Windows PowerShell 5.1, PowerShell 7. Requires Windows registry, `Get-NetTCPConnection`, and Windows DPAPI for repair. `curl.exe` is needed for the HTTPS probe. Codex CLI and Desktop are optional for discovery; Codex-specific checks are unavailable if the CLI is absent or too old.

Actually tested locally: Windows 11 build 26200, PowerShell 7.6.5, Codex CLI 0.166.0-alpha.6, Codex Desktop 26.1029.7803.0. Windows 10 and PowerShell 5.1 have not been locally tested. GitHub CI is designed to exercise Windows PowerShell 5.1 and PowerShell 7, but its results cannot be claimed until run on GitHub.
