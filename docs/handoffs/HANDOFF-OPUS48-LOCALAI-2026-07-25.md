# Public starter portable-hardware handoff

PR: <https://github.com/allusionsafk/localai-windows-starter/pull/1>

## Verified this session

- Customer-safe capability module, CLI integration, Scout compatibility, and
  synthetic tests were mirrored semantically.
- Local gates: 312 pytest tests, Ruff, source/capability typing,
  PowerShell/Compose checks, Actionlint, strict public audit with no findings,
  and a full-history Gitleaks scan.
- CI uses immutable action SHAs, official Windows/Linux/macOS runners,
  a dependency-review gate, strict public audit, and no artifact uploads.
- Hosted run `30117251912` passed Windows, Linux, macOS, Windows operational,
  strict public-audit, and secret-history gates. Dependency review was
  intentionally skipped because its repository prerequisite is disabled.
- Missing and blank Windows identity variables are regression-tested and no
  longer create match-everything audit patterns.

## Recorded but not rerun

Earlier released installer evidence predates this branch. This branch has not
been installed on a fresh machine or released.

## Inferred

The pure-Python seam runs on hosted Linux and macOS. This does not establish
real accelerator support on those platforms.

## Blocked/open

- Real Apple/Linux/AMD/NPU qualification.
- Clean-machine install and rollback of this exact branch.
- Reproducible SBOM, signing, and immutable release manifest.
- GitHub Dependency Graph is disabled; dependency review remains skipped until
  the owner enables the graph and sets `DEPENDENCY_REVIEW_ENABLED=true`.

## Owner decisions

Do not merge or release until semantic diff review and the clean-machine
candidate gate are approved. Latest implementation-head hosted CI is green.
Windows 11 x64 + NVIDIA CUDA remains the only first-class installer target.
