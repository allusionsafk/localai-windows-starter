# Adaptive Media 0.3.2 — Claude Code Takeover Mission

## Mission

Take ownership of Adaptive Media from the current private `0.3.2-dev4` hardware candidate through objective local hardware certification, any necessary bounded fixes, exact-final-bit certification, and (only when every release gate is satisfied) publication of `v0.3.2`.

After `v0.3.2` is safely published, leave the repository in a better state for the next generation by producing a focused post-release hardening plan / 0.4 roadmap. Do not start a broad rewrite before 0.3.2 ships.

The user explicitly wants an ambitious, low-manual-intervention execution. Prefer machine-verifiable evidence over asking the user to inspect playback subjectively.

---

## Non-negotiable release safety

1. **Do not modify, replace, delete, retag, or republish `v0.3.1`.** It is the frozen friend-test baseline.
2. Work on `adaptive-media-dev` using an isolated worktree if practical. Do not enter another agent's active worktree.
3. Do not touch unrelated LocalAI starter work, website work, model-scout work, other PRs, or unrelated release tags.
4. Keep `0.3.2` private until the exact-final-bit hardware gate is green.
5. Do not weaken an existing gate to make a build pass.
6. Do not reintroduce subjective visual QA as a release blocker. Use objective telemetry, launch plans, IPC, self-tests, install tests, hashes, and source assertions.
7. Do not create a parade of standalone throwaway validators. The repository now has one durable hardware certification gate. Improve that gate only if evidence proves the gate itself is wrong.
8. Preserve user settings across candidate installs. Snapshot `%LOCALAPPDATA%\AdaptiveMedia\settings.json` before any operation that could overwrite/remove it and restore it if needed.
9. Never delete, move, rename, transcode, or otherwise modify the user's media files.
10. Never claim native Dolby Vision/Profile 7 FEL passthrough, guaranteed Atmos passthrough, or universal HDR-TV switching unless objectively proven. Preserve the existing honest limitations.

---

## Current authoritative ground truth

Repository:

`allusionsafk/localai-windows-starter`

Branch:

`adaptive-media-dev`

Current 0.3.2 dev4 integration commit at handoff:

`a23b74621195d094c5415c5ce3303462a6069ef4`

Current private CI run:

`33690727007`

CI result:

**PASS**

Private artifact ID:

`9869983964`

Artifact name:

`AdaptiveMedia-0.3.2-dev4-x64`

Candidate installer:

`AdaptiveMediaSetup-0.3.2-dev4-x64.exe`

Candidate installer SHA-256:

`5C4CC0A4FD00665C3536DACD3368BDA29925079D9B59F615EBAA89FB977E3D9E`

The dev4 CI run already proves:

- hardware-certification script Windows PowerShell 5.1 self-test PASS;
- reviewed 0.3.0 source archive hash reconstruction PASS;
- 0.3.1, dev2, dev3, and dev4 patch application PASS;
- Compatibility profile is explicitly D3D11;
- managed NVIDIA profile is explicitly Vulkan + WinVK;
- Vulkan FIFO is added only after final renderer selection and is excluded from D3D11 paths;
- RTX VPP explicitly pairs `gpu-api=d3d11` and `gpu-context=d3d11`;
- deterministic RTX launch-plan integration checks PASS;
- native app self-test PASS;
- WPF → BackendBridge → engine launch-plan integration PASS;
- isolated installer install/self-test/integration/uninstall PASS;
- bundled hardware certification files are staged and installed correctly;
- final private installer build and checksum PASS.

The dev4 change is packaging/certification integration on top of dev3 playback semantics. Do not casually change playback semantics unless the real hardware report proves a defect.

---

## Product policy that must remain true

Adaptive Media is a Windows launcher/manager around mpv with MPC-BE fallback.

### Reference playback

- mpv `gpu-next` / libplacebo is primary.
- NVIDIA managed path is the already-validated `gpu-api=vulkan`, `gpu-context=winvk`, NVDEC-first path.
- Compatibility is the explicit D3D11 escape hatch.
- Reference mode must not silently enable fake HDR, interpolation, aggressive sharpening, or AI processing.

### Motion

- Gentle/Smooth are mpv temporal/cadence interpolation, not AI optical-flow frame generation.
- `display-resample`, interpolation, and Vulkan FIFO are allowed only on the actual managed Vulkan path.
- Compatibility and RTX VPP D3D11 paths must not inherit Vulkan FIFO.

### RTX video processing

- RTX VSR/HDR are opt-in.
- `d3d11vpp` requires D3D11 API + context together.
- Deterministic integration coverage for the RTX plan must remain green.

### Audio / HDR honesty

- decoded PCM is the normal default;
- HDMI compressed bitstream is optional and topology-dependent;
- Atmos metadata in a source does not prove Atmos passthrough;
- Dolby Vision metadata handling through mpv/libplacebo is not a claim of native Windows DV / Profile 7 FEL passthrough;
- external HDR-TV switching remains topology-dependent unless newly proven.

---

# PHASE 1 — Establish machine and repository truth

Before any write:

1. Confirm `adaptive-media-dev` head and working-tree cleanliness.
2. Confirm the existing public `v0.3.1` release remains unchanged.
3. Confirm run `33690727007` is still successful and artifact `9869983964` is available. If it expired, rebuild the same reviewed source/patch stack rather than substituting an older candidate.
4. Download the private dev4 Actions artifact.
5. Extract it into a bounded temporary directory, not the Desktop.
6. Verify the installer SHA-256 exactly equals:

   `5C4CC0A4FD00665C3536DACD3368BDA29925079D9B59F615EBAA89FB977E3D9E`

If any of this differs, stop and establish why before continuing.

---

# PHASE 2 — Objective certification on the user's actual laptop

This phase should be driven by Claude Code itself as far as the local environment permits.

## 2.1 Snapshot before install

Record, without exposing secrets:

- currently installed Adaptive Media product version;
- current Adaptive Media install root;
- SHA-256 of currently installed `AdaptiveMedia.exe` and `AdaptiveMedia.Engine.ps1` if present;
- existence/hash of `%LOCALAPPDATA%\AdaptiveMedia\settings.json`;
- GPU names and driver versions;
- Windows primary display refresh;
- mpv executable/version used by Adaptive Media.

Copy the settings JSON to a temporary backup before candidate install.

## 2.2 Install the verified dev4 candidate

Install `AdaptiveMediaSetup-0.3.2-dev4-x64.exe` normally enough that the real stable install root is exercised.

Do not rely on the user to click through a post-install test if it can be run directly afterward.

## 2.3 Automatically choose a representative local media file

Prefer a real local file rather than streaming content.

Search only normal user media locations such as Videos, Downloads, Desktop, and already-known media folders. Do not recurse across the entire disk unnecessarily.

Prefer, in order:

1. a UHD/2160p HEVC/H.265 file;
2. a 1080p+ HEVC/H.265 file;
3. AV1/VP9/H.264 media suitable for NVDEC;
4. any normal local video as a fallback.

A 23.976/24 fps source is useful because it exercises the high-refresh Smooth path well on the known 240 Hz panel.

If the previously tested Lanterns UHD DV/HDR file is still locally available, it is a strong candidate, but do not depend on its exact filename and do not expose private filenames beyond local logs/report fields already produced by the certification tool.

Do not transcode or alter the file.

## 2.4 Run the installed certification gate directly

Installed script location should be:

`%LOCALAPPDATA%\Programs\Adaptive Media\certification\Test-0.3.2-Hardware.ps1`

Run it under Windows PowerShell 5.1 with an explicit `-MediaPath` so no file-picker/user intervention is needed.

The gate itself already performs:

- installed native self-test;
- installed WPF/backend/engine integration test;
- real Enhanced + Smooth launch-plan generation;
- managed NVIDIA profile assertions;
- real mpv launch using the production plan plus diagnostic IPC/mute/loop instrumentation only;
- hybrid-GPU/display warmup;
- `display-sync-active` verification;
- mpv display refresh measurement;
- Windows-vs-mpv refresh comparison;
- effective `gpu-api` verification;
- effective `gpu-context` verification;
- effective Vulkan swap-mode verification;
- hardware-decoder state / NVDEC verification for supported codecs;
- steady-state output drop delta;
- decoder drop delta;
- delayed-frame delta;
- programmatic fullscreen entry;
- programmatic ESC keypress;
- proof that ESC exits fullscreen without terminating playback;
- cleanup/quit;
- one overwritten JSON report at `%LOCALAPPDATA%\AdaptiveMedia\certification\0.3.2-hardware.json`.

Use the normal warmup/measurement durations unless evidence says otherwise. Do not shorten the test merely to save time.

## 2.5 Certification decision

Read the generated JSON and the process exit status.

For promotion purposes, require an unambiguous **PASS**. UNKNOWN is not a PASS.

Capture at least:

- candidate version;
- GPU topology;
- video codec;
- display-sync active state;
- mpv display Hz;
- Windows display Hz;
- effective GPU API/context;
- effective Vulkan swap mode;
- effective hardware decoder;
- output frame-drop delta;
- decoder frame-drop delta;
- delayed-frame delta;
- ESC fullscreen result;
- overall status;
- failures/unknowns/notes.

Do not ask the user whether it “looked smooth.”

---

# PHASE 3 — If dev4 fails, diagnose once and fix the right layer

A failure is not automatically a product bug.

Classify it first:

### A. Certification-instrument defect

Examples: bad IPC property assumption, quoting bug, incorrect refresh helper, impossible threshold, process-lifetime bug.

If and only if the evidence proves the gate is wrong:

- fix the durable hardware gate;
- add/update its `-SelfTest` or deterministic coverage so the exact failure class cannot recur;
- preserve the product playback plan;
- bump the private packaging candidate (e.g. dev5) only as needed;
- run CI from the beginning;
- rerun the local hardware gate.

### B. Product launch-plan defect

Examples: wrong API/context, FIFO on D3D11, missing FIFO on managed Vulkan Smooth, incorrect hwdec selection.

Make the smallest bounded production change that fixes the proven defect.

Every production fix must have deterministic regression coverage in the existing WPF/backend/engine integration path before hardware retest.

### C. Environment/topology limitation

Examples: driver failure, unsupported swapchain behaviour, display path incapable of the requested renderer, codec outside NVDEC expectation.

Do not lie around it. Either:

- use an existing supported Compatibility/fallback policy if appropriate and prove it objectively; or
- record the limitation and keep 0.3.2 private if it violates the intended supported baseline.

Do not keep cycling through speculative flags.

---

# PHASE 4 — Build the exact final 0.3.2 candidate

Once a private dev candidate passes real hardware certification, create a **final candidate whose payload is intended to become the public v0.3.2 artifact without any rebuild after certification**.

This is critical.

## Final-candidate requirements

1. Product version is `0.3.2` / Windows numeric `0.3.2.0` as appropriate.
2. No `dev`, `dev4`, or RC label remains in user-visible product metadata.
3. Playback semantics are unchanged from the hardware-passing candidate unless a separately proven final-candidate defect requires a fix.
4. Release notes are updated accurately.
5. The hardware-certification capability may remain bundled as a support/diagnostic tool if that is the cleanest way to certify the exact public bits. If retained publicly:
   - do **not** auto-run it by default after ordinary consumer installation;
   - give it a clear support/diagnostic name;
   - do not clutter the normal user experience.
6. The final installer is built privately by CI and uploaded as an Actions artifact first. Do not publish a GitHub release yet.
7. Generate and record the final installer SHA-256.

Run the complete existing CI gate on this final candidate:

- source reconstruction/hash;
- renderer assertions;
- deterministic RTX integration;
- native self-test;
- WPF/backend/engine integration;
- isolated installer install/self-test/integration/uninstall;
- final installer existence/checksum;
- private artifact upload.

---

# PHASE 5 — Certify the exact final public bits

Download the newly built private **0.3.2 final candidate** artifact.

Verify its CI-recorded SHA-256 locally.

Install that exact EXE on the user's laptop.

Run the installed 0.3.2 hardware certification gate against a representative local media file again.

Require PASS.

The file that passes this phase is the file that must later be attached to the public GitHub `v0.3.2` release. **Do not rebuild between hardware certification and publication.**

If the final candidate fails despite dev4 passing, diagnose the actual delta; do not hand-wave it as “metadata only.”

---

# PHASE 6 — Publish v0.3.2 only after exact-final-bit PASS

When and only when Phase 5 is green:

1. Create/update the `v0.3.2` GitHub release from the intended final commit.
2. Upload the **exact hardware-certified installer file**, not a freshly rebuilt copy.
3. Upload its checksum text file.
4. Verify the GitHub release asset digest for the EXE exactly matches the locally certified SHA-256.
5. Verify:
   - tag `v0.3.2`;
   - release title `Adaptive Media 0.3.2`;
   - draft=false;
   - prerelease=false;
   - EXE asset present;
   - checksum asset present;
   - release body matches real capabilities and limitations.
6. Re-fetch the public release through the GitHub API and report the final immutable facts.

Do **not** alter `v0.3.1`.

## Release notes should prominently cover

- renderer-aware Smooth/Gentle presentation;
- Vulkan FIFO only on managed Vulkan paths;
- explicit RTX D3D11 API/context pairing;
- ESC leaves fullscreen rather than quitting;
- UTF-8-safe diagnostics;
- hybrid-GPU topology hints;
- deterministic RTX launch-plan regression coverage;
- objective real-hardware certification on the target laptop;
- limitations around external HDR switching, HDMI bitstream/Atmos topology, and Dolby Vision passthrough.

Do not overclaim.

---

# PHASE 7 — Post-release verification and cleanup

After publication:

1. Download the public release EXE once and verify its hash equals the exact certified hash.
2. Confirm `v0.3.1` assets/digest remain unchanged.
3. Confirm no unintended public 0.3.2 pre-release/dev tags exist.
4. Clean only Adaptive Media temporary build/certification download directories created by this mission.
5. Do not delete unrelated Desktop files, media, repos, logs, or other agents' worktrees.
6. Keep the single current hardware JSON report; avoid timestamped-report clutter.

---

# PHASE 8 — Be ambitious after shipping: supportability + 0.4 roadmap

Only after 0.3.2 is safely public, inspect what would produce the largest real product improvement next.

Create a concise `adaptive-media/ROADMAP-0.4.md` and/or well-scoped GitHub issues. Prioritise concrete supportability and cross-machine robustness over novelty.

Strong candidates to evaluate:

### 1. First-class hardware verification / diagnostics

Turn the proven certification machinery into a polished support workflow:

- one button or command to generate a bounded diagnostics bundle;
- app version/hash;
- mpv version;
- GPU names/drivers;
- display refresh/HDR state if reliably queryable;
- actual playback plan;
- effective renderer/hwdec;
- short objective drop metrics;
- no sensitive unrelated files.

This would make friend-machine debugging dramatically easier.

### 2. Per-machine renderer capability policy

Explore a bounded capability cache rather than model-name hardcoding:

- managed NVIDIA WinVK path when proven healthy;
- Compatibility fallback when Vulkan path is objectively unavailable;
- no broad automatic renderer switching based on guesses;
- explicit reset/re-probe path.

### 3. Multi-display / external-TV awareness

Investigate robustly identifying which display owns the playback window and its refresh/HDR state. Do not implement fragile EDID/HDR magic merely because it is interesting.

### 4. Audio topology diagnostics

Provide clear user-facing distinction between:

- decoded PCM;
- HDMI bitstream eligibility;
- codec/container metadata;
- actual Windows/audio-device path.

Do not claim Atmos merely because TrueHD/E-AC-3 metadata exists.

### 5. RTX feature capability UX

Make RTX VSR/HDR availability explicit and explain when the feature forces the D3D11 VPP path versus the reference WinVK path.

### 6. Update/distribution ergonomics

The user dislikes extracting ZIPs and opening terminals. Keep the product distribution centred on a normal installer and simple in-app/support actions. Avoid developer-oriented setup steps for end users.

### 7. Cross-machine certification matrix

Design a small schema so the user's laptop and the friend's different MSI/NVIDIA laptop can each produce comparable certification JSON. This should help decide whether a renderer policy is broadly safe without hardcoding RTX 4080/ASUS assumptions.

Do not implement all of this at once. Rank by evidence, value, risk, and testability.

---

# Definition of done for this takeover

Claude Code should not stop at “code looks good.” The takeover is complete when it can report one of two clear outcomes.

## Successful release outcome

- dev4 or a bounded successor passed real local hardware certification;
- a final `0.3.2` installer was built privately;
- that exact final installer passed the local hardware gate;
- the exact certified EXE was published as `v0.3.2` without rebuild;
- public GitHub asset digest matches the certified local SHA-256;
- `v0.3.1` remained untouched;
- release limitations are honest;
- post-release 0.4 roadmap/supportability work is captured.

## Blocked outcome

If a genuine hardware/product blocker remains, do not publish. Report:

- exact failing gate;
- exact evidence/metric;
- whether it is instrument, product, or environment;
- minimal next change required;
- current private candidate hash;
- confirmation that `v0.3.1` remains the public safe baseline.

---

# Working style

- Establish ground truth before writes.
- Use exact hashes and run IDs.
- Prefer scripts/CI/API evidence over screenshots.
- Make bounded fixes, not speculative architecture expansion.
- Run focused checks first, then the full cheap/release gates.
- Push coherent commits to `adaptive-media-dev`.
- Keep the user out of terminal work whenever Claude Code can safely do it itself.
- If local machine access allows it, Claude Code should perform the candidate install, media selection, certification invocation, JSON parsing, and cleanup itself.
- Ask the user only when an action truly cannot be automated safely or when explicit approval is needed for something outside this mission.

The north star is simple: **ship a better 0.3.2 because the exact public bits were objectively proven on real hardware, not because another validator said a theoretical plan looked correct.**
