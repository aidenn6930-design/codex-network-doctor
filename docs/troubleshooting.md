# Troubleshooting

1. Run `diagnose -Detailed` and preserve only the redacted output.
2. If the configured listener is absent, check whether your proxy software is running and whether its port changed.
3. If a port mismatch appears, inspect both explicit candidates. Do not guess from other open ports.
4. If HTTPS fails but the listener exists, check proxy protocol, DNS, TLS certificates, and upstream connectivity. A 403 challenge or 432 alone does not establish the cause.
5. If HTTPS passes but Codex Doctor WebSocket fails, inspect the full Codex Doctor output locally and check WebSocket support in the proxy. Redact any logs before sharing.
6. If CLI checks pass while the desktop window still shows “Couldn't load workspace settings”, run `diagnose -CheckDesktopPath`. This compares direct HTTPS with the local proxy path without changing settings. A `DESKTOP_PROXY_ROUTE_GAP` warning suggests a route difference, not a proven app cause. Inspect desktop network logs at the error time.
7. If direct access times out but the proxy succeeds, and the Windows system proxy must stay off, preview the app-only launcher with `src\Start-CodexWithProxy.ps1 -Preview`. Exit Codex normally, relaunch through the script, and confirm its process command line and app logs.
8. If all checks pass while workspaces still fail, note the error time, Codex versions, and service status; investigate application routing and upstream service health.

The installed CLI's `doctor --network-only` command is used only when `doctor --help` advertises it. Unsupported checks are reported as such.
