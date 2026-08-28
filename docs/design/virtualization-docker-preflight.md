# Virtualization / Docker / WSL preflight and resumable recovery

Status: **implementation-ready design; runtime not implemented**  
Target: next bounded AFK AI installer unit after the current ValClip production cycle  
Scope: Windows Friend Beta installer only

## Problem statement

A clean-machine Friend Beta run reached Python setup, model selection, and Docker Desktop installation, then Docker reported that virtualization support was unavailable. The installer had already done useful work, but it discovered the platform blocker too late and the outer `.cmd` reduced the failure path to the generic `Something went wrong` message.

The next installer unit should classify Windows virtualization, WSL, and Docker readiness **before expensive/product-specific setup continues**, give one precise recovery action, persist a durable checkpoint, and revalidate on the next run.

This document does not implement system-changing behaviour. It maps the current code and defines the state model, insertion points, probes, tests, safety boundary, and handoff contract for the implementation agent.

## 1. Current flow (verified from `master`)

Entry path:

```text
Install Local AI.cmd
  -> installer/bootstrap.ps1
       -> verify/fetch pinned repository payload
       -> ensure PowerShell 7
       -> installer/Install-LocalAI.ps1
            -> installer/installer-common.ps1 state helpers
            -> phase runner
```

`bootstrap.ps1` is the clean-machine bootstrap. It can run under Windows PowerShell 5.1, installs/resolves PowerShell 7, obtains the pinned repository copy, then launches `Install-LocalAI.ps1` under PowerShell 7.

`Install-LocalAI.ps1` currently executes these phases in order:

```text
vet
intent
python
pip
scout
ollama-docker
pulls
compose
seed
secure
self-test
```

Important current behaviour:

- `vet` measures GPU/VRAM/RAM/CPU/disk and chooses a capability tier. It does **not** classify firmware virtualization, Windows virtualization features, WSL readiness, or Docker-engine health.
- Python and the editable `localai` package are installed before Docker readiness is known.
- model scouting runs before Docker readiness is known.
- `ollama-docker` checks only whether `docker.exe` resolves. If it does not, the phase installs Docker Desktop, sets `pending_reboot = true`, saves state, prints a manual Docker/restart instruction, and returns `$false`.
- the runner maps that `$false` to process exit code `10`, which `Install Local AI.cmd` treats as a planned Docker checkpoint.
- if `docker.exe` **does exist**, `ollama-docker` currently returns success without proving that the Docker engine, WSL backend, Windows hypervisor path, or required reboot state is healthy.
- `pulls` follows immediately and may download a model after that weak Docker-presence check.
- compose/startup is therefore capable of discovering an environment failure later than it should.
- any non-checkpoint non-zero exit reaches the `.cmd` `:failed` label and ends with the generic `Something went wrong - read the messages above this line.`

## 2. Existing persistence / resume mechanism

`installer/installer-common.ps1` stores `installer-state.json` next to the installer. Current schema:

```json
{
  "version": 1,
  "phases_done": [],
  "hardware": null,
  "intent": [],
  "models": {},
  "pending_reboot": false
}
```

`Set-PhaseDone` appends completed phase names and saves after each phase. Re-running the root `.cmd` therefore skips completed phases even without an explicit `-Resume` flag. The `-Resume` flag currently mainly affects the `pending_reboot` reset behaviour.

Current weaknesses relevant to this design:

- corrupt state throws an instruction to delete the state file manually;
- state writes are direct, not explicitly temp-file + atomic replace;
- `pending_reboot` is only a boolean and does not say *why* the checkpoint exists;
- no probe snapshot or classifier version is stored;
- a stale checkpoint has no explicit compatibility/version policy;
- the planned-pause contract is Docker-install-specific rather than a general recoverable-blocker contract.

## 3. Friend Beta observed failure

The clean-machine test sequence was:

```text
Python setup
-> model scout / model recommendation
-> Docker Desktop installation
-> Docker reports virtualization support unavailable
-> user-facing install cannot proceed
```

This proves a product UX failure, not a Docker crash or a completed AFK AI fix.

The design must not assume the exact cause on that machine. The correct first split is between firmware virtualization, Windows virtualization/WSL readiness, reboot state, Docker installation/running state, and an unknown blocker.

## 4. Proposed state model

Do not force every signal into one flat enum. Store **component status** plus one derived `overall` disposition. That preserves evidence and avoids treating `DOCKER_HEALTHY` and `READY` as competing meanings.

### Component statuses

```text
firmware_virtualization:
  READY
  FIRMWARE_VIRTUALIZATION_DISABLED
  UNKNOWN

windows_virtualization:
  READY
  WINDOWS_VIRTUALIZATION_FEATURE_MISSING
  REBOOT_REQUIRED
  UNKNOWN

wsl:
  READY
  WSL_NOT_INSTALLED
  WSL_UPDATE_REQUIRED
  REBOOT_REQUIRED
  UNKNOWN

docker:
  DOCKER_NOT_INSTALLED
  DOCKER_INSTALLED_NOT_RUNNING
  DOCKER_REQUIRES_REBOOT
  DOCKER_HEALTHY
  UNKNOWN
```

### Derived overall state

```text
READY
RECOVERABLE_BLOCKER
UNKNOWN_BLOCKER
```

`READY` means all prerequisites required for AFK AI's current Docker/WSL path have been positively revalidated and Docker is healthy.

`RECOVERABLE_BLOCKER` means the classifier has a supported, specific next action.

`UNKNOWN_BLOCKER` means evidence is conflicting, unavailable, timed out, privilege-blocked, localized beyond safe interpretation, or otherwise insufficient. Unknown must fail closed **before model pulls** and surface useful diagnostics rather than invent a fix.

### Blocker precedence

When several problems exist, show one action in this order:

1. `FIRMWARE_VIRTUALIZATION_DISABLED`
2. `REBOOT_REQUIRED`
3. `WINDOWS_VIRTUALIZATION_FEATURE_MISSING`
4. `WSL_NOT_INSTALLED`
5. `WSL_UPDATE_REQUIRED`
6. `DOCKER_NOT_INSTALLED`
7. `DOCKER_INSTALLED_NOT_RUNNING`
8. `DOCKER_REQUIRES_REBOOT`
9. `UNKNOWN_BLOCKER`
10. `DOCKER_HEALTHY` / `READY`

Rationale: do not ask the user to repair a higher layer while a lower platform prerequisite is known to be false.

## 5. Probe result contract

Use one structured object, never downstream parsing of already-rendered user copy.

Suggested shape:

```json
{
  "schema_version": 1,
  "classifier_version": "windows-preflight-v1",
  "observed_at_utc": "2026-08-28T00:00:00Z",
  "firmware_virtualization": {
    "status": "READY",
    "source": "Win32_Processor.VirtualizationFirmwareEnabled",
    "evidence": {"virtualization_firmware_enabled": true}
  },
  "windows_virtualization": {
    "status": "READY",
    "evidence": {
      "hypervisor_present": true,
      "virtual_machine_platform": "enabled",
      "wsl_optional_component": "enabled"
    }
  },
  "wsl": {
    "status": "READY",
    "version": "2.x.x",
    "minimum_for_docker": "2.1.5"
  },
  "docker": {
    "status": "DOCKER_HEALTHY",
    "cli_found": true,
    "engine_reachable": true
  },
  "reboot": {
    "required": false,
    "reasons": []
  },
  "overall": "READY",
  "action": null,
  "diagnostic_codes": []
}
```

Do not persist full command output by default. Persist bounded booleans, versions, exit/status codes, and short AFK-defined diagnostic codes.

## 6. Platform probes / commands

The first implementation should use built-in Windows/CIM/CLI surfaces already available before Python package setup.

### Firmware virtualization

Primary probe:

```powershell
Get-CimInstance Win32_Processor
```

Relevant properties:

- `VirtualizationFirmwareEnabled`
- `VMMonitorModeExtensions`
- `SecondLevelAddressTranslationExtensions` where available/relevant

Microsoft documents `VirtualizationFirmwareEnabled` as the firmware virtualization-extension signal on supported Windows versions.

Cross-check:

```powershell
Get-CimInstance Win32_ComputerSystem
```

Use `HypervisorPresent` as corroborating evidence that a hypervisor is active, not as a substitute for every firmware/feature check.

Do not parse Task Manager UI. `systeminfo.exe` may be a bounded fallback/corroborator, but its human-readable text is localized; do not make English substring parsing the primary classifier.

### WSL

Probe command availability, then bounded calls:

```text
wsl.exe --version
wsl.exe --status
wsl.exe --list --verbose
```

Microsoft documents `--version`, `--status`, `--update`, and `--list --verbose`. Older inbox WSL builds may not support the same version-reporting surface, so unsupported options must classify deliberately rather than become a generic exception.

Current Docker documentation requires WSL 2.1.5 or later for its WSL 2 backend. Store the minimum in one constant with a source comment; do not scatter it across user copy and tests.

Do **not** require an ordinary Linux distribution to be installed merely to satisfy Docker Desktop. Docker documents that its WSL 2 backend does not require a particular user distribution.

### Windows optional features

The current AFK AI Docker path relies on WSL 2. Detect at least:

- Windows Subsystem for Linux feature/readiness;
- Virtual Machine Platform feature/readiness;
- hypervisor boot/readiness where evidence indicates the feature exists but the hypervisor is not active.

Candidate built-in probes include PowerShell optional-feature/DISM surfaces. The implementation must determine which query works reliably without forcing the *entire installer* to run elevated. If a query is privilege-blocked, classify that observation as unknown and provide a bounded diagnostic code rather than silently escalating.

Do not enable Windows features in the initial probe function. Probe and action are separate capabilities.

### Docker

Presence is not health.

Probe in layers:

1. resolve `docker.exe` (PATH plus the existing post-install PATH refresh rules);
2. optionally resolve the Docker Desktop application path/process for user-facing launch guidance;
3. run a bounded engine query such as `docker info` with a short timeout;
4. classify engine success as `DOCKER_HEALTHY`;
5. classify installed CLI + unreachable engine as `DOCKER_INSTALLED_NOT_RUNNING`, `DOCKER_REQUIRES_REBOOT`, or `UNKNOWN` based on the lower-level Windows/WSL evidence.

Do not scrape large Docker diagnostic bundles during normal preflight.

AFK AI must not require Docker Hub sign-in. A local Docker Desktop engine health check is sufficient.

### Reboot evidence

Persist a reboot reason whenever AFK AI itself initiates or observes an operation known to require a restart. The implementation may also inspect conservative Windows pending-reboot indicators, but should avoid treating every vendor-specific registry key as authoritative.

At minimum distinguish:

- AFK AI just enabled/installed a prerequisite whose completion requires reboot;
- Docker/WSL operation explicitly reports reboot required;
- a stale `pending_reboot` checkpoint whose machine has since been revalidated healthy.

## 7. Recommended insertion points

The goal is early diagnosis **and** a hard guard before any model download.

### A. Early platform preflight

Add a new first installer phase before the current `vet` phase:

```text
environment-preflight
vet
intent
python
pip
scout
...
```

This phase should be non-destructive by default. It gathers/classifies platform readiness before Python/package/model-selection work is performed.

For a known blocker it writes the checkpoint, renders one action, and exits intentionally through the generalized recoverable-blocker contract.

### B. Split environment recovery from Ollama setup

The current `ollama-docker` phase combines unrelated responsibilities. During implementation, split only as much as required to make the state machine explicit:

```text
environment-preflight
[environment-recovery / Docker install if appropriate]
environment-ready-gate
vet
intent
python
pip
scout
ollama-setup
pulls
compose
...
```

The smallest acceptable implementation may keep existing phase names internally, but **there must be a positively revalidated environment-ready gate before `pulls`**.

### C. No model download before readiness

`Invoke-PhasePulls` must be unreachable unless the current-run environment probe says `READY` / `DOCKER_HEALTHY`. Do not trust only a historical phase marker for this gate because the machine can change between runs.

## 8. Resume / checkpoint strategy

Evolve `installer-state.json` rather than inventing a second unrelated persistence file.

Suggested schema additions:

```json
{
  "version": 2,
  "checkpoint": {
    "kind": "RECOVERABLE_BLOCKER",
    "reason": "FIRMWARE_VIRTUALIZATION_DISABLED",
    "created_at_utc": "...",
    "classifier_version": "windows-preflight-v1"
  },
  "environment": {
    "last_probe": {"...": "bounded structured state"}
  }
}
```

Rules:

- every rerun re-probes live machine state; never trust a previous `READY` result for system readiness;
- phase completion may still skip deterministic product work, but environment readiness is a live gate;
- a resolved blocker clears/replaces the checkpoint automatically;
- a stale checkpoint is harmless because live revalidation wins;
- a corrupt state file should be quarantined/renamed with an AFK-generated suffix and a fresh schema created where safe, rather than telling a novice to manually delete JSON;
- state writes should use a temp file followed by replace/rename so interruption does not leave half-written JSON;
- schema migration must be explicit and tested; unknown future schema versions fail safely with an actionable message.

## 9. Exit/result contract and error rendering

Do not overload generic exit code `1` for every expected machine state.

Recommended logical outcomes:

```text
0   completed / ready path
10  recoverable action required; checkpoint saved
1   genuine unexpected failure
```

The internal result should carry a stable AFK diagnostic code and user copy. Exit `10` can remain the outer `.cmd` planned-pause code so the existing distribution contract does not needlessly change.

Generalise the current Docker-only `:dockerwait` presentation into an action-required path. The `.cmd` should not invent diagnosis; it should display the already-classified action summary written/returned by the orchestrator.

Unexpected failures must still include a bounded diagnostic code and the location of the privacy-scrubbed support path. Replace the final user experience of bare `Something went wrong` with something equivalent to:

```text
AFK AI could not classify this setup problem.
Code: PREFLIGHT-UNKNOWN
Nothing further was installed after the readiness gate.
Copy the diagnostic summary above when asking for help.
```

Do not claim the installer made no changes if earlier bootstrap work actually installed PowerShell or fetched the repository. Scope the copy to the current gate/action.

## 10. UX copy examples

These are examples for implementation tests, not final marketing copy.

### Firmware virtualization disabled

```text
ACTION NEEDED — turn on hardware virtualization

Windows reports that CPU virtualization is disabled in firmware.
Open your PC's BIOS/UEFI settings and enable Intel VT-x / Intel Virtualization
Technology or AMD SVM / AMD-V, then start Windows and run AFK AI again.

AFK AI saved your setup checkpoint. You do not need to start over.
```

Do not guess a motherboard-specific BIOS path unless the product has verified hardware-specific guidance.

### Windows virtualization feature missing

```text
ACTION NEEDED — Windows virtualization support is not ready

Hardware virtualization is available, but the Windows feature required by the
current WSL 2 path is not enabled.

AFK AI has not changed Windows features in this step.
Follow the displayed Windows action, restart if requested, then run AFK AI again.
```

### WSL update required

```text
ACTION NEEDED — update WSL

WSL is installed, but its detected version is below the version required by the
current Docker Desktop WSL 2 backend.

Update WSL, then run AFK AI again. The installer will re-check it before
continuing.
```

### Docker installed but not running

```text
ACTION NEEDED — start Docker Desktop

Docker Desktop is installed, but the local Docker engine is not reachable.
Open Docker Desktop and let it finish starting, then run AFK AI again.

No Docker Hub sign-in is required by AFK AI.
```

### Reboot required

```text
ACTION NEEDED — restart Windows

A Windows/WSL/Docker prerequisite changed and needs a restart before AFK AI can
verify the environment.

Restart Windows, then run AFK AI again. Your checkpoint is saved.
```

## 11. Privacy implications

Preflight should collect only machine-readiness facts needed to classify setup:

- boolean virtualization/hypervisor/feature states;
- WSL version/status category;
- Docker installed/running/healthy category;
- bounded exit codes/AFK diagnostic codes;
- reboot-required category.

Do not collect or upload:

- usernames/home paths except transiently where Windows APIs require them;
- WSL distro file contents;
- Docker container/image inventories unless later diagnostics explicitly need a sanitised subset;
- Docker account identity;
- network credentials;
- environment-variable values;
- chat/model prompt/document content.

No telemetry is introduced by this unit. Support diagnostics remain user-initiated.

## 12. Failure modes and fail-closed rules

| Failure | Required behaviour |
|---|---|
| CIM virtualization property unavailable | corroborate with other bounded Windows evidence; otherwise `UNKNOWN_BLOCKER` |
| Windows feature query needs elevation | do not silently elevate merely to probe; return a diagnostic code / supported next step |
| localized CLI output | prefer exit/status/API facts; do not depend on English prose for core state |
| `wsl.exe` missing | `WSL_NOT_INSTALLED` when evidence is sufficient |
| WSL option unsupported on older inbox build | classify version/status deliberately; do not crash |
| WSL command hangs | timeout -> `UNKNOWN_BLOCKER` with command-specific code |
| Docker CLI missing | `DOCKER_NOT_INSTALLED` |
| Docker CLI present, engine unreachable | use platform evidence to distinguish stopped/reboot/unknown |
| Docker health query hangs | timeout -> stopped/unknown based on corroboration, never healthy |
| state file corrupt | quarantine + fresh safe state, report what happened |
| state schema newer than code | fail with actionable incompatibility; do not overwrite blindly |
| machine state changes between runs | live re-probe wins over checkpoint |
| preflight not ready | no model pull and no compose start |
| probe throws unexpected exception | bounded `UNKNOWN_BLOCKER`/unexpected diagnostic, never guessed remediation |

## 13. RED test matrix

Implement these tests **before** activating new installer control flow.

| Scenario | Expected classification / behaviour |
|---|---|
| virtualization enabled + Windows/WSL/Docker healthy | overall `READY`; Docker `DOCKER_HEALTHY`; installer may continue |
| firmware virtualization disabled | `FIRMWARE_VIRTUALIZATION_DISABLED`; one firmware action; checkpoint saved |
| virtualization enabled but Windows feature missing | `WINDOWS_VIRTUALIZATION_FEATURE_MISSING`; no Docker/model action yet |
| WSL absent | `WSL_NOT_INSTALLED`; precise WSL action |
| WSL installed but below supported Docker minimum | `WSL_UPDATE_REQUIRED`; update action |
| WSL installed but command unhealthy/timeout | `UNKNOWN_BLOCKER`; useful diagnostic code |
| Docker absent with lower prerequisites ready | `DOCKER_NOT_INSTALLED`; bounded Docker-install transition allowed |
| Docker installed but engine not running | `DOCKER_INSTALLED_NOT_RUNNING`; start-Docker action |
| Docker install/feature operation requires reboot | `DOCKER_REQUIRES_REBOOT` or reboot component status; planned exit |
| Docker healthy | `DOCKER_HEALTHY`; ready gate passes |
| state changes between runs | second run ignores stale result and uses live probe |
| resume after reboot | saved phase work retained; live environment revalidated; continuation automatic when ready |
| checkpoint stale | stale reason replaced by live state without user cleanup |
| checkpoint corrupt | quarantined/recovered safely; clear message; no manual JSON surgery required |
| preflight rerun twice with same machine | idempotent result; no duplicate destructive action |
| environment not ready before pulls | model-pull function is not invoked |
| Docker sign-in absent | local engine readiness does not require/account-check Docker Hub sign-in |
| unknown platform failure | no generic-only `Something went wrong`; stable diagnostic code + support guidance |
| probe output contains user path/hostname | persisted/support result does not retain unnecessary value |
| WSL/Docker probe times out | bounded timeout; no hang; fail closed |
| localized command output | core classifier still uses structured/exit evidence or returns unknown, never false ready |
| future state schema version | older installer refuses safe overwrite and explains incompatibility |

### Test seams

Do not test this by toggling real firmware/Windows features in the normal unit suite.

Create an injectable probe boundary. Each probe returns a small object; the classifier consumes those objects. Fixture tests should be able to supply:

```text
firmware probe result
windows-feature probe result
WSL probe result
Docker probe result
reboot probe result
```

Then separately have a small Windows integration test lane that exercises the real probe commands on a healthy CI/VM without changing machine state.

At least one test must assert that no function capable of `ollama pull`, Docker compose startup, or model download is called while the environment-ready gate is false.

## 14. Toolchain recommendation

### Recommendation: PowerShell 7 for the first preflight implementation

Use the existing PowerShell installer/runtime seam for this unit, with pure/injectable helper functions in `installer/installer-common.ps1` or a focused new `installer/windows-preflight.ps1`.

Reasons:

1. **Earliest availability.** `bootstrap.ps1` already guarantees PowerShell 7 before it launches the orchestrator. Python is installed later, so a Python-only preflight cannot diagnose the earliest clean-machine blocker without first doing work the preflight is supposed to avoid.
2. **Windows integration.** CIM, registry, Windows optional-feature queries, process/path resolution, and bounded invocation of `wsl.exe` / `docker.exe` are native PowerShell strengths.
3. **Packaging.** No new binary/runtime needs to be shipped before the installer can inspect the machine.
4. **Maintainability.** This keeps platform-changing/Windows-specific installer logic in the existing Windows installer layer rather than duplicating state in a new native helper.
5. **Testability.** Probe and classification functions can be separated and fed synthetic objects; tests do not need to mutate the host.

### Do not introduce a native helper yet

Rust/C++ would only be justified if Windows APIs unavailable/reliably inaccessible from the existing runtime became a demonstrated blocker. That has not been shown.

### Do not make Python the only preflight layer

The Python package remains appropriate for reusable product orchestration and pure hardware/model logic after Python exists. If the future Control Center needs the normalized environment state, consider a later shared schema/reader. Do not duplicate the first classifier merely for language symmetry.

### PowerShell 5.1 remains bootstrap glue

Keep `bootstrap.ps1` compatible with Windows PowerShell 5.1 for the tiny fetch/PowerShell-7 bootstrap contract. Run the substantive preflight under PowerShell 7 in the orchestrator.

## 15. Likely files for the implementation unit

Expected primary changes:

- `installer/Install-LocalAI.ps1` — insert/gate phases and generalized planned-pause handling;
- `installer/installer-common.ps1` — state schema/migration, atomic save, probe/classifier helpers **or** source a new focused helper;
- optionally `installer/windows-preflight.ps1` — preferred if helpers become large enough to obscure generic installer utilities;
- `Install Local AI.cmd` — replace Docker-specific/generic outer messaging with a generalized action-required contract, without moving diagnosis into batch code;
- `installer/README.md` — update current-flow documentation after implementation;
- new focused tests under `tests/` for classifier, checkpoint, gating, and outer error contract.

Possible secondary changes only if demonstrated necessary:

- `src/localai/installer_vet.py` / Python CLI if the normalized environment state becomes useful after installation;
- diagnostic-report code to include bounded preflight diagnostic codes.

Do not touch release pins, website download hashes, model selection policy, Docker Compose configuration, or unrelated Control Center features in this unit.

## 16. Safety constraints / non-goals

This unit is **not** permission to:

- run the entire installer elevated;
- silently change BIOS/UEFI settings;
- silently enable Windows features just because they are missing;
- edit BCD/hypervisor boot settings without a separate explicit recovery design;
- disable Windows security controls;
- require a Docker Hub account/sign-in;
- download a model before environment readiness;
- change model recommendations;
- change release pins/hashes;
- replace Docker/WSL architecture;
- add telemetry;
- solve cross-platform installation.

Initial implementation should prefer **detect -> classify -> explain -> checkpoint -> intentional exit -> revalidate**. System-changing recovery automation can be added only where the action is well-bounded, consented, testable, and genuinely improves the Friend Beta path.

## 17. Definition of done

The implementation unit is done when:

1. the RED matrix above is implemented and passes for the supported classifier paths;
2. clean-machine execution classifies virtualization/Windows/WSL/Docker before model downloads;
3. firmware-disabled, feature-missing, WSL-absent/update, Docker-absent/stopped, reboot, healthy, and unknown states have distinct stable diagnostics;
4. one precise user action is shown for each known recoverable blocker;
5. recoverable blockers use a planned checkpoint/exit, not a generic failure;
6. rerun after a fix/reboot automatically revalidates and resumes without manual state deletion;
7. stale/corrupt state is handled safely and tested;
8. no model pull/compose start occurs before a live ready gate;
9. no Docker Hub sign-in requirement is introduced;
10. diagnostics remain bounded/privacy-safe;
11. existing pinned-bootstrap/release integrity behaviour is unchanged;
12. documentation is updated only after the behaviour exists;
13. cheap focused and repository test gates pass;
14. a new clean-machine Friend Beta run reaches the next meaningful milestone or produces a precise new blocker.

## 18. Implementation brief for Claude/Codex

**Title:** Add virtualization / Docker / WSL preflight and resumable recovery

**Problem:** The current installer checks only Docker CLI presence late in the phase order. A clean-machine run reached Docker before discovering an unavailable virtualization path, while the outer batch file rendered unexpected failures generically.

**Implement:** a non-destructive Windows readiness probe/classifier, persistent reasoned checkpoint, early blocker UX, live ready gate before model pulls, and generalized planned-pause/error rendering. Reuse the existing installer state/phase architecture; do not redesign unrelated runtime.

**Start RED:** implement the test matrix in section 13 with synthetic probe fixtures. First prove that the current flow can reach the model-pull boundary with `docker.exe` present but an unhealthy engine; then make that regression impossible.

**Non-goals:** model/runtime changes, Docker/WSL execution during unit tests, broad refactors, release changes, telemetry, cross-platform support, auto-editing BIOS, permanent security weakening.

**Likely first code seam:** a new `installer/windows-preflight.ps1` containing bounded probes + a pure classifier, sourced by `Install-LocalAI.ps1`, with state/checkpoint helpers kept in `installer-common.ps1`.

**Acceptance:** all supported blocker states are distinguishable; live readiness gates model pulls; checkpoint survives reboot/rerun; unknown failures are actionable; no existing release-integrity or privacy boundary regresses.

## 19. External platform references used for this design

- Microsoft WSL basic commands: https://learn.microsoft.com/windows/wsl/basic-commands
- Microsoft WSL install/update guidance: https://learn.microsoft.com/windows/wsl/install
- Microsoft `Win32_Processor` class (`VirtualizationFirmwareEnabled`): https://learn.microsoft.com/windows/win32/cimwin32prov/win32-processor
- Microsoft `Win32_ComputerSystem` class (`HypervisorPresent`): https://learn.microsoft.com/windows/win32/cimwin32prov/win32-computersystem
- Docker Desktop Windows install/system requirements: https://docs.docker.com/desktop/setup/install/windows-install/
- Docker Desktop WSL 2 backend: https://docs.docker.com/desktop/features/wsl/
- Docker Desktop virtualization troubleshooting: https://docs.docker.com/desktop/troubleshoot-and-support/troubleshoot/topics/

These references inform probe selection and requirements; runtime truth and measured Friend Beta behaviour still outrank documentation assumptions during implementation.
