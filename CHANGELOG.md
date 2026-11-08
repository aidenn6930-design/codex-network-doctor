# Changelog

## 0.1.0 — unreleased

- Initial Windows proxy and Codex diagnostic CLI with redacted JSON output.
- Explicit, validated user environment repair and encrypted backup/rollback.
- English and Simplified Chinese documentation, Pester tests, and read-only CI.
- Detect the CLI bundled with Codex Desktop when it is absent from PATH.
- Keep verified proxy repairs if a follow-up diagnostic fails, and warn when rollback removes variables.
- Add an app-only Codex Desktop proxy launcher for installations where the Windows system proxy must remain disabled.
- Read the app-only launcher endpoint from matching user proxy variables or explicit `-ProxyUrl`, without a fixed port.
- Add opt-in direct-versus-proxy desktop route comparison, regression tests, and the launcher to the source archive.
