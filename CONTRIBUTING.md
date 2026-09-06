# Contributing to AFK AI

AFK AI is still proving its Windows Friend Beta. Contributions are welcome when
they make the supported path safer, clearer, more reliable, or easier to test.

## Keep the scope sharp

Prefer one demonstrated problem and one coherent fix.

Avoid mixing a focused change with:

- broad refactors
- repository-wide renames
- dependency churn
- speculative architecture changes
- unrelated visual or documentation cleanup

**AFK AI** is the customer-facing product name. Existing `localai` package,
command, and repository names can remain where renaming would add migration risk
without improving the product.

## Before changing behavior

1. Reproduce the problem or establish the current baseline.
2. Add or identify a regression test when practical.
3. Implement the smallest maintainable fix for the demonstrated mechanism.
4. Run focused checks first.
5. Run the appropriate wider cheap checks once the change is stable.
6. Keep documentation aligned with actual runtime behavior.

Do not claim that a platform, recovery path, privacy property, or installer
behavior has been tested unless it actually has.

## Privacy and security defaults

Changes must preserve AFK AI's local-first boundary.

Do not:

- expose local services to the LAN or internet by default
- add telemetry or upload diagnostics without explicit product review
- include chats, prompts, documents, credentials, tokens, cookies, `.env`
  values, or unrelated machine data in diagnostics
- tell users to disable Defender, Smart App Control, antivirus, UAC, or other
  Windows security controls as a blanket workaround
- permanently weaken PowerShell execution policy
- bypass pinned download or integrity checks for convenience

Security vulnerabilities belong in the private reporting flow documented in
[SECURITY.md](SECURITY.md).

## Tests and checks

Use the checks appropriate to the files you touched.

The Python project uses:

```text
pytest
ruff
mypy
```

Installer and public-boundary work also has repository-specific checks under
`tests/` and `ai-public-audit.ps1`.

Do not run heavyweight model downloads, Docker setup, GPU workloads, or
unrelated end-to-end work merely to change documentation or a pure helper.

## Pull requests

A useful pull request answers five questions:

1. What concrete problem does this solve?
2. What changed?
3. What intentionally did not change?
4. What checks actually ran, with results?
5. What limitations or follow-up work remain?

Call out any privacy, security, installation, networking, or release impact.

Keep release pins unchanged unless the PR is specifically a reviewed release
operation.
