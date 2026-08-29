# AFK AI documentation

This directory contains product design records, release notes, and focused technical guides for AFK AI for Windows.

For the normal Friend Beta entry point, start with the repository [README](../README.md). For installation details, use [installer/README.md](../installer/README.md). For support and security reporting, use [SUPPORT.md](../SUPPORT.md) and [SECURITY.md](../SECURITY.md).

## Current public references

| Document | Use it for |
|---|---|
| [Friend Beta 0.1.7rc1](releases/0.1.7rc1.md) | Current release-candidate scope, qualification status, limitations, and release evidence |
| [Virtualization and Docker preflight design](design/virtualization-docker-preflight.md) | The reviewed environment-preflight contract and recovery model |
| [WebBrain guide](webbrain.md) | Browser/search integration, privacy boundary, and expected network behaviour |

## Design records

`design/` contains reviewed architecture or behavioural contracts that are useful when changing a safety-sensitive subsystem.

A design record describes intended behaviour. It should not be treated as proof that every part of the design has shipped. Check the current code, tests, release notes, and relevant pull request before making a runtime claim.

## Release notes

`releases/` records the scope and evidence for named public candidates.

Release notes are historical records. A newer branch or pull request can contain work that is not part of the currently pinned website download.

## Engineering plans and specifications

`superpowers/specs/` and `superpowers/plans/` contain implementation specifications and execution plans used during development.

These are engineering records, not end-user setup instructions and not a promise that proposed work has shipped. When they disagree with the current runtime, tests, release notes, or a later accepted design, the newer verified implementation state takes precedence.

## Documentation rules

Public documentation should:

- use **AFK AI** as the product name
- distinguish local model inference from internet-using setup, downloads, updates, and optional web search
- describe only tests or deployments that were actually observed
- keep release pins and supported-platform claims exact
- avoid exposing credentials, private paths, machine identifiers, chats, prompts, documents, or unrelated diagnostics
- avoid em dashes in public copy

When a document becomes historical, say so explicitly rather than silently rewriting the past to match the newest implementation.
