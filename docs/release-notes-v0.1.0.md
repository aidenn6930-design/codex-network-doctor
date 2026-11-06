# Codex Network Doctor v0.1.0 (draft)

First community release candidate. Includes read-only Windows proxy discovery, local listener and bounded HTTPS checks, Codex Doctor HTTP/WebSocket summary when supported, deterministic proxy findings, redacted JSON, confirmed user-level proxy repair with typed approval, DPAPI backup, and conflict-aware rollback. English and Simplified Chinese documentation and Pester tests are included.

Known limits: no automatic repair for SOCKS, credential-bearing proxies, WinHTTP, `CODEX_CLI_PATH`, or upstream service failures. A ChatGPT homepage 200 is not proof that all Codex endpoints work. Other running processes' inherited environments are not inspected or changed. No sign-in task is installed. Public release awaits GitHub CI and explicit publication approval.
