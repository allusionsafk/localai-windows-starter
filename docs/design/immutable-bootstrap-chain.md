# Immutable installer chain

Status: **design only. No code change, no release, no repin.**
Scope: `Install Local AI.cmd`, `installer/bootstrap.ps1`, the website `/download` route

The Friend Beta website verifies a SHA-256-pinned launcher before serving a
single byte. The launcher then downloads and executes a second script from a
**mutable branch** with no integrity check, and that second script is where the
payload pins live. This document states the problem precisely and proposes the
smallest correct fix.

Nothing here changes the current pin, tag, or release. Verified against
`master` at `dbd8107` and tag `v0.1.7rc1`.

---

## 1. The chain as actually executed

A customer downloading from the website executes three stages:

| # | Stage | Integrity | Source |
|---|---|---|---|
| 1 | `Install AFK AI.cmd` | **Verified** — SHA-256 checked, fails closed on mismatch | tag `v0.1.7rc1`, served by the Worker |
| 2 | `installer/bootstrap.ps1` | **None** | `raw.githubusercontent.com/.../master/installer/bootstrap.ps1` |
| 3 | repository payload | **Verified** — commit SHA or zip SHA-256, refuses unverified | tag `v0.1.7rc1` |

Stage 1, `worker.js`: the payload is hashed and compared to `INSTALLER_SHA256`
before it is returned; a mismatch is a 502 and **no executable bytes are
served**. That part is right.

Stage 2, `Install Local AI.cmd` line 21 — the website ships a *single file*, so
there is no sibling `installer\bootstrap.ps1` and this branch always runs:

```bat
Invoke-WebRequest -UseBasicParsing
  'https://raw.githubusercontent.com/allusionsafk/localai-windows-starter/master/installer/bootstrap.ps1'
  -OutFile ($env:TEMP + '\localai-bootstrap.ps1')
```

then line 28 executes it:

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File "%BOOT%" %*
```

No hash. No signature. No pinned ref. `master` is a moving branch.

Stage 3, `bootstrap.ps1`, is properly pinned — but **its pins are its own
parameter defaults**:

```powershell
[string]$Ref = 'v0.1.7rc1',
[string]$ExpectedCommit = '0a03df5f64471b8299c29e8bc86bee1bb1bd4158',
[string]$ExpectedZipSha256 = '6AC5D0B06E1164B7F47348DC4270EA228192548F5176AC06500B0EDED44EE3C2',
```

## 2. Why the website SHA does not cover this

The integrity chain is **self-referential and broken at exactly one hop**. The
launcher's hash proves the launcher. The launcher does not prove the bootstrap.
The bootstrap proves the payload — but the bootstrap is the thing that *names*
which payload to trust.

So whoever controls `master/installer/bootstrap.ps1` controls the entire
installation, on every machine that has ever downloaded the launcher. Editing
`$ExpectedZipSha256` and `$Ref` in that one file silently redirects the payload,
and every integrity check downstream still passes — because they are checking
against the attacker-supplied constants.

The website's fail-closed hash check is genuinely good, and it protects nothing
about stage 2.

### 2.1 The damage is permanent, not versioned

This is the part that matters most for planning.

Every `.cmd` already downloaded has that `master` URL baked in. It will keep
fetching from `master` forever. **Re-pinning the website does not retroactively
fix a single already-distributed launcher.**

Therefore `master/installer/bootstrap.ps1` is not an ordinary source file. It is
a permanently load-bearing, remotely-executed production artefact for every
copy of the installer that has ever left the building, and it must be treated
that way regardless of which fix is chosen.

### 2.2 Old launchers silently follow master to new releases

The same mechanism is also today's upgrade path: because `bootstrap.ps1` on
`master` carries the current `$Ref`, a launcher downloaded months ago will
install whatever release `master` currently points at.

That may well be intended. It should be an explicit product decision rather than
an emergent property, because "the pinned launcher installs the pinned release"
is what the pin *appears* to promise, and is not what happens.

### 2.3 Second finding: the pins are user-overridable parameters

`%*` forwards the launcher's arguments to `bootstrap.ps1`, whose integrity
controls are ordinary parameters — `-AllowUnverified`, `-Owner`, `-Repo`,
`-Ref`, `-ExpectedZipSha256`. So:

```
"Install AFK AI.cmd" -AllowUnverified -Owner someone-else
```

is a supported invocation that disables verification and changes the source.
This is a local/social-engineering vector, not a remote one, and `-AllowUnverified`
is documented as a maintainer dev-testing switch. It is recorded here because a
copy-pasteable "just add this flag" workaround is exactly how integrity controls
get bypassed in the field.

## 3. Options

### Option A — fetch the bootstrap from an immutable ref

Change the launcher's URL from `master` to a **40-character commit SHA**:

```
https://raw.githubusercontent.com/<owner>/<repo>/<commit-sha>/installer/bootstrap.ps1
```

A commit SHA is content-addressed and cannot be moved. A *tag* name in that URL
would still be mutable — tags can be re-pointed — so the tag is not sufficient
here even though it is what stage 3 uses.

- Smallest possible diff: one URL in the `.cmd`.
- Makes the chain immutable end to end.
- Also removes §2.2 silently-follow-master behaviour: a pinned launcher then
  installs exactly its own generation. That is a **behaviour change** and needs
  a deliberate decision about how old launchers learn about new releases.
- Still trusts `raw.githubusercontent.com` to serve the right bytes for that SHA.

### Option B — embed the bootstrap digest and verify before executing

The launcher downloads the bootstrap, hashes it, compares to an embedded
constant, and refuses to execute on mismatch.

- Defends even if the host or transport serves the wrong bytes.
- Makes the launcher self-sufficient: it trusts a constant it carries, not a URL.
- Costs a little batch/PowerShell logic, and the failure path must be a clear
  refusal rather than a generic error.

### Option C — manifest-based pinning

A manifest listing the digests for each stage, fetched and verified once.

- More machinery than this architecture currently needs. The launcher already
  carries constants, and there is exactly one hop to fix.
- Worth revisiting only if the number of independently-fetched stages grows, or
  if signing is introduced.

## 4. Recommendation

**Option A + Option B together**, as one change to the launcher.

Fetch by commit SHA *and* verify the downloaded bootstrap against an embedded
SHA-256 before executing it. A defeats a moved ref; B defeats a bad response.
Neither alone closes both, and together they are still only a few lines.

Sketch — illustrative, not final:

```bat
set "BOOTSHA=<sha256-of-installer/bootstrap.ps1-at-that-commit>"
set "BOOTURL=https://raw.githubusercontent.com/<owner>/<repo>/<commit-sha>/installer/bootstrap.ps1"
rem download, then verify before executing; any mismatch must refuse to run.
```

Required properties of the implementation:

- **No executable bytes are run after an integrity failure.** The downloaded
  file is deleted and the launcher exits with the existing failure path.
- **The failure message is understandable** — "AFK AI could not verify its own
  installer files and stopped. Nothing was installed." — and does not tell the
  user to bypass anything.
- **The existing staged architecture is preserved.** Stage 3's commit/zip
  verification is unchanged and remains the payload's guarantee.
- **Resume and recovery are unaffected.** Verification happens before the
  orchestrator starts, so `installer-state.json`, the exit-10 planned-pause
  contract, and rerun behaviour are untouched.
- **Rollback is trivial**: the change is confined to the launcher, and the
  previous candidate remains servable by reverting the website's two constants.

## 5. What requires a new installer candidate and repin

**Every fix in §3 requires a new `.cmd`.** The launcher is the only file the
website's hash covers, and it is exactly the file containing the vulnerable URL.
Changing it changes its SHA-256, which requires, in order:

1. a new commit on `master` containing the corrected launcher;
2. a new annotated tag / release candidate;
3. recomputing the launcher blob's SHA-256 at that tag;
4. updating `RC_TAG` and `INSTALLER_SHA256` in the website's `worker.js`;
5. re-verifying the site's Case 9 release-pin assertions.

There is a chicken-and-egg detail worth planning for: Option B embeds the
digest of `bootstrap.ps1` *at a specific commit*, so the bootstrap must be
committed first, its digest computed, then the launcher updated to reference
that commit and digest. The launcher and the bootstrap therefore land in two
commits, and the tag is cut on the second.

**What does not require a repin, and can be done now:**

- Treat `master/installer/bootstrap.ps1` as a protected, security-critical
  artefact — branch protection, required review, and a note in the file itself
  saying that already-distributed launchers execute it directly. This is a
  mitigation for §2.1 that is available immediately and remains necessary even
  after the fix, because old launchers never stop using that URL.
- Decide, and write down, whether §2.2 (old launchers following `master` to new
  releases) is intended behaviour.

## 6. Explicit non-goals of this document

- No change to `worker.js`, `RC_TAG`, `INSTALLER_SHA256`, or any tag.
- No release published and no candidate cut.
- No change to `Install Local AI.cmd` or `installer/bootstrap.ps1` in this
  branch — this is design only, and the fix is deliberately not mixed into any
  unrelated pull request.
