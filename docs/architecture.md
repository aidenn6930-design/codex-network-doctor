# Architecture

`src/codex-doctor.ps1` is the CLI. `CodexNetworkDoctor.psm1` discovers configuration, parses endpoints, performs bounded probes, and generates a schema 1.0 report. `CodexRepair.psm1` selects explicit local HTTP candidates, creates a minimal change plan, backs up registry state, applies only user proxy variables, verifies, and rolls back on failure.

The diagnostic pipeline has independent layers: configuration, listener, HTTPS, Codex Doctor HTTP/WebSocket, optional direct-versus-proxy desktop route comparison, and rule-based findings. Windows system proxy, WinHTTP, process environment, persistent user environment, and machine environment are kept separate. The tool does not infer another process's inherited environment.

The v0.1.0 JSON report has `SchemaVersion`, `ToolVersion`, `GeneratedAt`, `Platform`, `Proxy`, `Probe`, `DesktopDirectProbe`, `CodexDoctor`, `Findings`, and `Summary`. Fields are additive within schema 1.0. Consumers should branch on `SchemaVersion` and tolerate unknown fields. `Findings` entries have code, severity, evidence, possible cause, confidence, next action, and repair support.
