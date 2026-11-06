# Security policy

For suspected credential exposure, unsafe repair, or code execution vulnerabilities, do not post secrets in a public issue. Contact the repository maintainer privately through GitHub's private vulnerability reporting feature after publication. Until a public repository exists, retain the report locally and do not share sensitive logs. Redact proxy credentials, tokens, user names, and account identifiers from reproductions.

The tool does not request administrator rights. Repair writes only three current-user environment variables after confirmation. Backups use Windows DPAPI; anyone with access to the same unlocked Windows user context may be able to decrypt them. See `docs/security-model.md`.
