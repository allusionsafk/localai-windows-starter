# Contributing to AFK AI

AFK AI is still proving its Windows Friend Beta. Contributions are welcome when they make the supported path safer, clearer, more reliable, or easier to test.

## Keep changes focused

Prefer one demonstrated problem and one coherent fix.

Avoid mixing a focused change with broad refactors, repository-wide renames, dependency churn, speculative architecture work, or unrelated visual cleanup.

**AFK AI** is the product name. Existing `localai` package, command, and repository names can remain where a rename would create migration risk without improving the product.

## Before changing behaviour

1. Reproduce the problem or establish the baseline.
2. Add or identify a regression test when practical.
3. Make the smallest maintainable change that addresses the mechanism.
4. Run focused checks first.
5. Run the wider inexpensive gates that cover the touched area.
6. Keep documentation aligned with observed behaviour.

Do not describe a platform, recovery path, privacy property, installer path, or performance result as tested unless it was actually tested.

## Privacy and security

Do not:

- expose local services to the LAN or internet by default
- add telemetry or upload diagnostics without explicit product review
- put chats, prompts, documents, credentials, tokens, cookies, `.env` values, or unrelated machine data in diagnostics
- tell users to disable Defender, Smart App Control, antivirus, UAC, or other Windows security controls as a blanket workaround
- permanently weaken PowerShell execution policy
- bypass pinned download or integrity checks for convenience

Security vulnerabilities belong in the private path described in [SECURITY.md](SECURITY.md).

## Checks

Use the checks appropriate to the files you touched.

The Python project uses:

```text
pytest
ruff
mypy
```

Installer and public-boundary work also has repository-specific checks under `tests/` and `ai-public-audit.ps1`.

Do not run model downloads, Docker setup, GPU workloads, or unrelated end-to-end work for a documentation-only or pure-helper change.

## Pull requests

A useful pull request states:

- the problem
- the change
- what was intentionally left alone
- the checks that ran and their results
- any remaining limitation or follow-up

Call out privacy, security, installation, networking, runtime ownership, or release impact.

Keep release pins unchanged unless the pull request is specifically a reviewed release operation.
