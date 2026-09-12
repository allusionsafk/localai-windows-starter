# AFK AI documentation

This directory contains release records, product contracts, design records, and focused technical guides for AFK AI for Windows.

For the normal Friend Beta entry point, start with the repository [README](../README.md). For help, use [SUPPORT.md](../SUPPORT.md). Security reports belong in [SECURITY.md](../SECURITY.md).

## Public references

| Document | Purpose |
|---|---|
| [Friend Beta 0.1.7rc1](releases/0.1.7rc1.md) | Pinned public candidate, qualification status, and known limitations |
| [Installer guide](../installer/README.md) | Bootstrap and installer architecture |
| [Virtualization and Docker preflight](design/virtualization-docker-preflight.md) | Reviewed first-run classification and recovery contract |
| [WebBrain guide](webbrain.md) | Browser and search integration, privacy boundary, and network behaviour |

## Design records

`design/` contains reviewed behavioural or architecture contracts for safety-sensitive subsystems.

A design record explains intended behaviour. It is not proof that every part of the design is present in the pinned public candidate. Check the code, tests, release record, and relevant pull request before making a runtime claim.

## Release records

`releases/` describes named public candidates.

Release records are historical. Development branches and open pull requests can move ahead of the website-pinned Friend Beta without changing what users download.

## Engineering plans

`superpowers/specs/` and `superpowers/plans/` contain implementation specifications and execution plans used during development.

They are engineering records, not setup instructions and not release promises. Current code, tests, accepted contracts, and release evidence take precedence over older plans.

## Documentation standard

Public AFK AI documentation should:

- use **AFK AI** as the product name
- separate local model inference from setup, downloads, updates, and optional web search that use the internet
- state only tests, deployments, and hardware paths that were actually observed
- keep release pins and supported-platform claims exact
- keep credentials, private paths, machine identifiers, chats, prompts, documents, and unrelated diagnostics out of examples
- mark historical and experimental material clearly

When a document becomes historical, keep the record intact and label it rather than rewriting the past to match current development.
