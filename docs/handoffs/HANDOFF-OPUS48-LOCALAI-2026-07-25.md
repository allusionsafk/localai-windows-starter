# Public starter portable-hardware handoff

PR: <https://github.com/allusionsafk/localai-windows-starter/pull/1>

## Verified this session

- Customer-safe capability module, CLI integration, Scout compatibility, and
  synthetic tests were mirrored semantically.
- Local gates: 310 pytest tests, Ruff, source/capability typing,
  PowerShell/Compose checks, Actionlint, strict public audit with no findings,
  and a full-history Gitleaks scan.
- CI uses immutable action SHAs, official Windows/Linux/macOS runners,
  dependency review, strict public audit, and no artifact uploads.

## Recorded but not rerun

Earlier released installer evidence predates this branch. This branch has not
been installed on a fresh machine or released.

## Inferred

Hosted non-Windows execution is expected from the fail-closed built-in probes;
the latest PR matrix is authoritative.

## Blocked/open

- Real Apple/Linux/AMD/NPU qualification.
- Clean-machine install and rollback of this exact branch.
- Reproducible SBOM, signing, and immutable release manifest.

## Owner decisions

Do not merge or release until hosted CI, semantic diff review, and the
clean-machine candidate gate are approved. Windows 11 x64 + NVIDIA CUDA remains
the only first-class installer target.
