# Optional sign-in monitoring

Proposed task: current-user Task Scheduler logon trigger, delay 2 minutes, no elevation, action `powershell.exe -NoProfile -File "<repository>\src\codex-doctor.ps1" diagnose -SkipNetwork`. Run once per sign-in; do not repeat or keep a resident process. `-SkipNetwork` avoids external requests and still finds stale variables, missing listeners, and missing CLI paths. A notification wrapper may display the exit code; avoid accumulating logs and never include `repair` in the task.

The task is **not installed**. Installation, removal, and any notification integration require user approval. For manual checks, use `diagnose` with network checks enabled.
