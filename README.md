# Codex Network Doctor

An independent community toolkit for diagnosing Windows proxy and Codex connectivity problems. **Not affiliated with or endorsed by OpenAI.** It does not claim to fix every Codex error.

**Diagnose first. Explain clearly. Repair safely. Verify results.** Version 0.1.0 targets Windows 10/11 with Windows PowerShell 5.1 or PowerShell 7. Windows 11 and PowerShell 7.6.5 were tested locally; the other combinations remain CI targets, not verified environments.

## Why

A browser reaching ChatGPT does not prove that Codex Desktop, Codex CLI, and their background processes inherited the same proxy. One anonymized Windows 11 incident had working browser access and a working local HTTP proxy, while user-level `HTTP_PROXY` and `HTTPS_PROXY` were absent. Persisting those variables and rebooting resolved that incident. HTTP 432 and workspace routing errors can have other causes.

## Features

- Read-only discovery of system proxy, WinHTTP category, process/user/machine proxy variables, local listener, Codex versions, and background processes.
- Bounded HTTPS probe through an explicitly configured local proxy; uses `curl.exe` with 5-second connection and 12-second total timeout.
- Codex `doctor --network-only` and WebSocket summary when installed CLI supports it.
- Rule-based findings with evidence, confidence, next action, and repair eligibility. JSON schema 1.0.
- Repair limited to three user-level variables, with candidate validation, explicit typed approval, encrypted backup, post-check, and rollback conflict protection.
- No login task or background monitor installed automatically.

## Install and quick start

Clone or download the repository from a trusted source. No administrator rights are needed. `curl.exe` is needed for a network probe; if it is absent, diagnostics report unsupported. Codex CLI is optional for the read-only checks. Do not bypass your organization's PowerShell execution policy.

```powershell
.\src\codex-doctor.ps1 diagnose
.\src\codex-doctor.ps1 diagnose -Detailed
.\src\codex-doctor.ps1 diagnose -Json
.\src\codex-doctor.ps1 diagnose -SkipNetwork
.\src\codex-doctor.ps1 version
```

Example output from a sanitized, hypothetical configuration:

```text
Codex Network Doctor 0.1.0
Candidate: http://127.0.0.1:7892
HTTPS probe: Pass HTTP 200
[WARNING] PROXY_ENV_CONFLICT: User proxy URLs differ or cannot be parsed
  Next: Review explicit endpoints before repair
Summary: 0 errors, 1 warnings. No changes made.
```

Exit codes: `0` no error/warning, `1` warning, `2` error, `3` command failure. A missing Codex CLI is an informational finding. JSON output is redacted: proxy credentials, raw `NO_PROXY`, raw `CODEX_CLI_PATH`, and Codex Doctor output are omitted.

## Repair and rollback

Run `diagnose` first. Then run `repair` only if a repairable user proxy mismatch is found. Repair rechecks the configuration, requires an explicit local HTTP proxy candidate, checks its listener, and requires an HTTP 200 from `https://chatgpt.com/` through it. Multiple candidates require `-Candidate 1` (or another displayed one-based index). It shows intended changes and requires typing `YES`. Other applications launched under this user may inherit the changed variables. Credential-bearing URLs and SOCKS candidates are rejected for automatic repair.

```powershell
.\src\codex-doctor.ps1 repair
.\src\codex-doctor.ps1 repair -Candidate 1
.\src\codex-doctor.ps1 rollback -Backup .\backups\backup-YYYYMMDD-HHMMSS-<id>.cndb
```

Backups are versioned and encrypted with Windows DPAPI for the current user on the current machine. Rollback restores exact values and whether each variable existed, warns about newer changes, and requires a second `OVERWRITE` confirmation on conflict. It also saves a safety backup of the pre-rollback state. Neither operation changes already-running process environments. Close and reopen Codex in a controlled way; Windows sign-out or restart may be needed for all launchers to refresh environment variables.

## Optional sign-in check

An opt-in Task Scheduler task can run `diagnose -SkipNetwork` once, two minutes after user sign-in, under the current user without highest privileges. It should show a warning or overwrite a single fixed report file; it must never run `repair`. The proposed command is `powershell.exe -NoProfile -File "<repo>\src\codex-doctor.ps1" diagnose -SkipNetwork`. No task is created by this repository. See [monitoring design](docs/monitoring.md).

## FAQ and limits

- **Browser works, Codex fails?** Compare the process/user proxy variables and run Codex Doctor. Browser and Codex paths can differ.
- **HTTP 403 or 432?** These status codes alone do not prove a proxy error. Preserve time and sanitized error category, then check authentication, upstream service status, and Codex Doctor.
- **WebSocket unavailable?** Older CLI builds may not support `doctor --network-only`. The tool reports unsupported rather than inventing a test.
- **Homepage returns 200?** This only establishes that one HTTPS path works. Codex-specific checks are still needed.
- **Can it fix `CODEX_CLI_PATH`?** It detects a stale override but does not automatically remove it.
- **Can it inspect another running process's inherited environment?** No; Windows does not offer a safe general read-only process environment API here. The current shell environment is shown, and stale background processes remain a possible cause.

## Test and contribute

```powershell
Invoke-Pester .\tests -PassThru
```

Tests use mocks and local data; they do not require OpenAI connectivity or write system proxy variables. See [contribution guide](CONTRIBUTING.md), [architecture](docs/architecture.md), [security model](docs/security-model.md), and [troubleshooting](docs/troubleshooting.md). Report security issues privately as described in [SECURITY.md](SECURITY.md).

## License and disclaimer

MIT licensed; see [LICENSE](LICENSE). Supplied as-is. Back up settings and inspect the repair plan. Network and upstream service failures may require action outside this tool.
