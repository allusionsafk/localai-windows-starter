# Supply-chain and release policy

**Status:** release-design baseline; not a claim that signed packages exist  
**Verified:** 2026-07-24

## What this repository distributes

The starter publishes source, PowerShell installers, configuration, and model
recipes. It does not bundle model weights, FFmpeg, Docker Desktop, an inference
runtime, or an Open WebUI fork. Keep that boundary until redistribution,
license, signing, and rollback gates are complete.

Every executable/archive download must use an official HTTPS source, immutable
version or revision, reviewed SHA-256 manifest, bounded transfer, and explicit
hash failure. Verify Authenticode where the upstream Windows artifact is
signed. A floating `latest` URL may check for updates but must never drive an
installation or release build.

GitHub Actions are pinned to full commit SHAs because release tags can move:
<https://docs.github.com/en/actions/writing-workflows/choosing-what-your-workflow-does/using-pre-written-building-blocks-in-your-workflow#using-shas>.

## Model provenance

Before recommending or publishing a model configuration, record:

- canonical registry identifier and immutable digest/commit revision;
- exact GGUF filename, quantization, SHA-256, and context configuration;
- upstream license and restrictions;
- intended runtime and product support tier;
- measured hardware, driver, runtime, throughput, and memory residency.

An Ollama alias or Modelfile is configuration, not proof of weight provenance.
Promotion fails closed when the backing digest/revision or license is missing.

## Candidate and stable releases

Each candidate should generate `SHA256SUMS`, a CycloneDX or SPDX SBOM,
`THIRD_PARTY_NOTICES.md`, and a machine-readable runtime/model manifest. It must
pass dependency review, full-history Gitleaks, public-readiness, lint, source
typing, unit tests, PowerShell/Compose checks, and a clean-machine installer
gate.

Use immutable nightly, candidate, and stable identifiers. Only a dedicated
release job may request `id-token: write` and `attestations: write`. GitHub
artifact attestations can bind build provenance and SBOM data to released
assets: <https://docs.github.com/en/actions/concepts/security/artifact-attestations>.
Stable promotion remains manual. Never replace a published tag or asset;
supersede it with a new version.

Code-sign Windows release assets with a hardware- or managed-HSM-backed key.
Never store a signing private key in this repository, workflow variables,
logs, or ordinary CI secrets.

## Rollback

Retain the previous known-good manifest and take an application-data backup
before mutation. Restore configuration atomically. Rollback must never delete
models, chats, backups, or unrelated folders. A model rollback restores the
prior alias/digest. Database rollback requires an upstream-supported downgrade
or restoration of a compatible backup—never an improvised reverse migration.

## Third-party boundaries

- **Open WebUI:** current code has a branding-preservation condition. Keep the
  upstream branding intact; do not white-label or co-brand without a fresh
  legal review and required permission:
  <https://github.com/open-webui/open-webui/blob/main/LICENSE>.
- **FFmpeg:** the normal boundary is LGPL-2.1-or-later, optional GPL components
  change the applicable license, and `--enable-nonfree` may make a binary
  unredistributable. Prefer a separately installed upstream build. Bundling
  requires the exact build configuration, notices, corresponding source, and
  codec-license review: <https://ffmpeg.org/legal.html>.
- **Docker Desktop:** do not redistribute it or accept its terms for the user.
  Docker documents free-use categories and the paid-subscription boundary for
  larger professional/government use:
  <https://docs.docker.com/subscription/desktop-license/>.

## Artifact privacy

CI uploads no diagnostics. Any future upload uses a curated allowlist and at
most seven-day retention. Exclude `.env`, databases, backups, chats, prompts,
model files, absolute user paths, hostnames, tailnet data, tokens, browser
state, hardware serials, and raw application logs. Use synthetic fixtures and
scrub paths.
