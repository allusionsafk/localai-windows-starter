# Contributing to AFK AI

AFK AI is still proving its Windows Friend Beta. Contributions are welcome when they make the supported path safer, clearer, more reliable, or easier to test.

## Scope first

Prefer one demonstrated problem and one coherent fix. Avoid broad refactors, repository-wide renames, dependency churn, or speculative architecture changes mixed into a bug fix.

AFK AI is the customer-facing product name. Existing `localai` package, command, and repository names may remain where changing them would create migration risk without improving the product.

## Before changing behaviour

1. Reproduce or establish the current baseline.
2. Add or identify a regression test when practical.
3. Implement the smallest change that addresses the demonstrated mechanism.
4. Run focused tests first, then the appropriate wider cheap checks.
5. Keep documentation aligned with actual runtime behaviour.

Do not claim a platform, recovery path, privacy property, or installer behaviour has been tested unless it actually has.

## Privacy and security defaults

Changes must preserve the project's local-first boundary:

- do not expose local services to the LAN or internet by default;
- do not add telemetry or upload diagnostics without explicit product review;
- do not include chats, prompts, documents, credentials, tokens, cookies, `.env` values, or unrelated machine data in diagnostics;
- do not tell users to disable Defender, Smart App Control, antivirus, UAC, or other Windows security controls as a blanket workaround;
- do not permanently weaken PowerShell execution policy;
- do not bypass pinned download or integrity checks for convenience.

Security vulnerabilities should follow [SECURITY.md](SECURITY.md), not a public issue containing exploit details.

## Tests and checks

Use the checks appropriate to the files you touched. The Python project uses `pytest`, Ruff, and mypy; installer and public-boundary changes also have repository-specific checks under `tests/` and `ai-public-audit.ps1`.

Do not run heavyweight model downloads, Docker setup, GPU workloads, or unrelated end-to-end work merely to change documentation or a pure helper.

## Pull requests

A useful pull request explains:

- the concrete problem;
- what changed;
- what did **not** change;
- tests/checks actually run;
- known limitations or follow-up work;
- any privacy, security, installation, or release impact.

Keep unrelated cleanup out of the same PR. Preserve release pins unless the change is specifically a reviewed release operation.
