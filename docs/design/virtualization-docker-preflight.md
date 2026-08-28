# Virtualization / Docker / WSL preflight and resumable recovery

Status: **implementation-ready design; runtime not implemented**  
Scope: Windows Friend Beta installer only

This revision incorporates an adversarial merge-readiness review. In particular,
it distinguishes firmware virtualization from the Windows hypervisor launch state,
does not assume every healthy Docker Desktop installation uses WSL 2, and refuses
to accept a remote Docker context as proof that the local AFK AI environment is
ready.

## Problem statement

A clean-machine Friend Beta run reached Python setup, model selection, and Docker
Desktop installation, then Docker reported that virtualization support was
unavailable. The installer had already done useful work, but it discovered the
platform blocker too late and the outer `.cmd` reduced the failure path to the
generic `Something went wrong` message.

The next installer unit should classify the local Windows virtualization and
Docker environment before expensive/product-specific setup continues, give one
precise recovery action for known blockers, persist a durable checkpoint, and
revalidate the machine on every rerun.

This document does **not** implement system-changing behaviour.

## 1. Current flow, verified from `master`

Entry path:

```text
Install Local AI.cmd
  -> installer/bootstrap.ps1
       -> verify/fetch pinned repository payload
       -> resolve/install PowerShell 7
       -> installer/Install-LocalAI.ps1
            -> installer/installer-common.ps1 state helpers
            -> phase runner
```

The current orchestrator runs:

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

- `bootstrap.ps1` can start under Windows PowerShell 5.1, then resolves or
  installs PowerShell 7 before launching `Install-LocalAI.ps1`.
- `vet` measures hardware/model capability; it does **not** classify firmware
  virtualization, Windows virtualization features, WSL readiness, Docker
  context, or Docker-engine health.
- Python and the editable `localai` package are installed before Docker readiness
  is known.
- model scouting runs before Docker readiness is known.
- `ollama-docker` primarily treats `docker.exe` existence as Docker presence.
- if Docker is absent, the current phase installs Docker Desktop, writes
  `pending_reboot = true`, and exits through the existing planned checkpoint.
- if `docker.exe` exists, the phase can succeed without proving that a **local**
  Docker Desktop Linux engine is running.
- `pulls` follows later and can download/build a model before the environment has
  passed a strong Docker-readiness gate.
- unexpected non-checkpoint failures eventually reach the `.cmd` generic
  `Something went wrong` path.

That is the failure mechanism this unit is intended to change.

## 2. Existing persistence and why it is not yet sufficient

Current `installer-state.json` is effectively:

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

Current behaviour has useful resumability but several weaknesses:

- writes use direct `Set-Content`, not an atomic replacement contract;
- corrupt JSON requires manual deletion;
- `pending_reboot` does not say why the checkpoint exists;
- no classifier/probe version is persisted;
- a completed phase can be skipped even though machine state changed later;
- there is no rule that a safety-critical checkpoint must be re-probed live.

The new preflight must treat persisted state as a **resume hint and audit record,
never as proof that the machine is currently ready**.

## 3. Friend Beta evidence

The observed clean-machine sequence was:

```text
Python setup
-> model scout / qwen3.5:4b-16k recommendation
-> Docker Desktop install
-> Docker reports virtualization support unavailable
```

This evidence proves only that the blocker was discovered too late. It does not,
by itself, prove which layer was at fault. Possible causes include firmware
virtualization disabled, missing Windows virtualization components, the Windows
hypervisor not launching at boot, WSL being absent/outdated/unhealthy, Docker
requiring a reboot, or another Docker Desktop startup failure.

The classifier must therefore prefer measured state over guessing from one Docker
error string.

## 4. Platform facts and supported-path policy

The implementation should be based on these current platform facts:

- `Win32_Processor.VirtualizationFirmwareEnabled` is a Windows-visible signal for
  whether firmware enabled CPU virtualization extensions. A missing/null/error
  result is **UNKNOWN**, not proof that firmware virtualization is disabled.
- `Win32_ComputerSystem.HypervisorPresent` is a distinct Windows-visible signal
  that a hypervisor is currently present. It must not be collapsed into the
  firmware signal.
- WSL 2 requires Windows virtualization support, including Virtual Machine
  Platform; Windows feature changes can require a reboot.
- current Docker Desktop documentation requires WSL 2.1.5 or later **when using
  the WSL 2 backend**.
- Docker Desktop on Windows also supports Hyper-V and Docker VMM in applicable
  configurations. Therefore `WSL_NOT_INSTALLED` is **not automatically a blocker
  when a verified local Docker Desktop Linux engine is already healthy through a
  different backend**.
- Docker's troubleshooting documentation explicitly distinguishes firmware
  virtualization from a hypervisor that is installed but not launched at Windows
  startup.
- Docker Desktop does not require Docker Hub sign-in by default. AFK AI must not
  make sign-in an installation requirement.
- Docker CLI contexts can target local or remote daemons, and `DOCKER_HOST` /
  `DOCKER_CONTEXT` can override the selected endpoint. A successful `docker info`
  against a remote daemon is **not** proof that the local AFK AI environment is
  ready.

For a new Docker Desktop installation, AFK AI's Friend Beta recovery path should
prefer the normal WSL 2 backend because that is Docker Desktop's default Windows
path today. This is a **project path choice**, not a claim that Docker Desktop
universally requires WSL 2.

Authoritative references:

- Microsoft Win32_Processor:
  https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-processor
- Microsoft Win32_ComputerSystem:
  https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-computersystem
- Microsoft WSL commands:
  https://learn.microsoft.com/en-us/windows/wsl/basic-commands
- Microsoft WSL installation:
  https://learn.microsoft.com/en-us/windows/wsl/install
- Docker Desktop Windows requirements:
  https://docs.docker.com/desktop/setup/install/windows-install/
- Docker Desktop WSL backend:
  https://docs.docker.com/desktop/features/wsl/
- Docker virtualization troubleshooting:
  https://docs.docker.com/desktop/troubleshoot-and-support/troubleshoot/topics/
- Docker contexts:
  https://docs.docker.com/engine/manage-resources/contexts/

## 5. State model

Do not use one flat enum for everything. Preserve component evidence and derive a
single aggregate disposition.

### 5.1 Platform support

```text
SUPPORTED
UNSUPPORTED_PLATFORM
UNKNOWN
```

Friend Beta currently targets Windows 11. A machine known to be outside the
published target is not an `UNKNOWN_BLOCKER`; it is `UNSUPPORTED_PLATFORM`.

### 5.2 Firmware virtualization

```text
READY
FIRMWARE_VIRTUALIZATION_DISABLED
UNKNOWN
```

Primary signal:

```powershell
Get-CimInstance Win32_Processor | Select-Object VirtualizationFirmwareEnabled
```

Rules:

- any reliable `True` from the relevant processor set -> READY;
- reliable `False` -> FIRMWARE_VIRTUALIZATION_DISABLED;
- null, unsupported property, access failure, malformed result, or probe timeout
  -> UNKNOWN.

Do not parse localized Task Manager or `systeminfo` prose as the primary signal.

### 5.3 Windows virtualization/hypervisor layer

```text
READY
WINDOWS_VIRTUALIZATION_FEATURE_MISSING
WINDOWS_HYPERVISOR_NOT_RUNNING
WINDOWS_VIRTUALIZATION_REBOOT_REQUIRED
UNKNOWN
```

This layer must distinguish:

1. optional features/components required for the chosen backend;
2. the hypervisor being launchable/present now;
3. a known pending-reboot condition.

`WINDOWS_HYPERVISOR_NOT_RUNNING` is intentionally separate from both firmware
virtualization and missing Windows features. Docker documents the case where the
hypervisor is installed but disabled at Windows startup. The first implementation
may **diagnose** that condition; it must not silently edit BCD or otherwise change
boot configuration.

Useful evidence includes:

- `Win32_ComputerSystem.HypervisorPresent`;
- optional feature states for `VirtualMachinePlatform` and
  `Microsoft-Windows-Subsystem-Linux` when the WSL 2 path is relevant;
- bounded, read-only boot-configuration evidence if needed to distinguish an
  installed-but-not-launched hypervisor;
- pending-reboot evidence only when it can be tied to a relevant Windows/Docker
  transition.

If privilege prevents a read-only probe, return UNKNOWN unless a documented
non-elevated fallback exists. Do not silently elevate the whole installer.

### 5.4 WSL

```text
READY
NOT_REQUIRED_FOR_CURRENT_HEALTHY_BACKEND
WSL_NOT_INSTALLED
WSL_UPDATE_REQUIRED
WSL_UNHEALTHY
WSL_REBOOT_REQUIRED
UNKNOWN
```

Probe with bounded calls to documented commands such as:

```text
wsl.exe --version
wsl.exe --status
wsl.exe --list --verbose
```

Rules:

- do not require a normal user Linux distribution merely to satisfy Docker
  Desktop; Docker documents that its WSL backend does not require one;
- do not depend on English labels in CLI output;
- use exit status and machine-readable/locale-independent numeric extraction where
  possible;
- if `wsl --version` is unsupported, distinguish an older/inbox WSL path from a
  missing command instead of treating all failures as `WSL_NOT_INSTALLED`;
- a command timeout is `WSL_UNHEALTHY` or UNKNOWN depending on the evidence, not a
  success;
- WSL below Docker's current documented minimum of 2.1.5 on the WSL backend is
  `WSL_UPDATE_REQUIRED`;
- if a verified local Docker Desktop Linux engine is already healthy on a backend
  that does not require WSL, WSL absence must not override that health result.

### 5.5 Docker

```text
DOCKER_NOT_INSTALLED
DOCKER_CLI_MISSING
DOCKER_INSTALLED_NOT_RUNNING
DOCKER_STARTING
DOCKER_REQUIRES_REBOOT
DOCKER_CONTEXT_REMOTE
DOCKER_LINUX_ENGINE_REQUIRED
DOCKER_VERSION_UNSUPPORTED
DOCKER_HEALTHY_LOCAL
UNKNOWN
```

`DOCKER_HEALTHY_LOCAL` requires more than `docker.exe` existing.

Minimum evidence:

1. Docker Desktop installation/CLI presence is consistent with the expected local
   product path.
2. Resolve the effective Docker target, including `DOCKER_HOST`, `DOCKER_CONTEXT`,
   `docker context show`, and `docker context inspect`.
3. Reject a TCP/SSH/other remote endpoint as `DOCKER_CONTEXT_REMOTE` for installer
   readiness. Do not run AFK AI compose operations against it.
4. Run bounded `docker info` against the intended local endpoint.
5. Confirm the reachable engine is suitable for the Linux-container compose stack.

Do **not** hard-code one context name as truth. Docker context names can vary;
validate endpoint locality and engine characteristics instead.

`DOCKER_VERSION_UNSUPPORTED` should only be used if AFK AI defines a documented
minimum Docker Desktop/Engine version for a required feature. Do not invent a
minimum merely to populate this state.

A Docker Desktop process that exists while `docker info` is still failing is
`DOCKER_STARTING` for a bounded grace period, then
`DOCKER_INSTALLED_NOT_RUNNING`/UNKNOWN based on evidence.

No Docker Hub login is part of the readiness contract.

### 5.6 Aggregate disposition

```text
READY
RECOVERABLE_BLOCKER
UNSUPPORTED_PLATFORM
UNKNOWN_BLOCKER
```

Precedence:

1. a verified `DOCKER_HEALTHY_LOCAL` Linux engine can establish READY even if an
   unused backend-specific probe (for example WSL on a healthy Hyper-V setup) is
   unavailable;
2. known unsupported Friend Beta platform -> UNSUPPORTED_PLATFORM;
3. contradictory or insufficient safety-critical evidence -> UNKNOWN_BLOCKER;
4. one or more known actionable blockers -> RECOVERABLE_BLOCKER;
5. otherwise -> READY.

Do not make every component independently mandatory when observed local engine
health proves that component is not part of the active backend.

## 6. Probe contract

Implement probes as read-only functions returning structured evidence. Example:

```powershell
[pscustomobject]@{
  Firmware = [pscustomobject]@{
    Status = 'READY'
    Source = 'Win32_Processor.VirtualizationFirmwareEnabled'
  }
  WindowsVirtualization = [pscustomobject]@{
    Status = 'READY'
    HypervisorPresent = $true
  }
  Wsl = [pscustomobject]@{
    Status = 'READY'
    Version = '2.6.1'
  }
  Docker = [pscustomobject]@{
    Status = 'DOCKER_HEALTHY_LOCAL'
    Context = 'desktop-linux'
    EndpointKind = 'npipe'
    EngineOs = 'linux'
  }
  Overall = 'READY'
  Action = $null
  Code = 'PREFLIGHT-READY'
}
```

Requirements:

- explicit command timeouts;
- no network access required for the probe itself;
- no model download;
- no Docker sign-in;
- no automatic BIOS, BCD, Windows-feature, WSL-update, or service mutation inside
  the read-only probe layer;
- no dependency on English CLI prose;
- bounded captured output;
- stable machine-readable reason codes;
- probe exceptions caught and mapped to UNKNOWN evidence rather than leaking into
  a generic outer failure.

## 7. Exact insertion and control-flow change

The safe future flow is:

```text
bootstrap (fetch verified payload, ensure PowerShell 7)
-> environment-preflight          # new, read-only, live
-> environment-recovery/prepare   # bounded existing/new action if approved
-> environment-ready              # new, live gate
-> vet
-> intent
-> python
-> pip
-> scout
-> ollama setup
-> pulls
-> compose
-> seed
-> secure
-> self-test
```

The important invariant is stronger than the original design:

> **No model pull and no product-specific package/model work begins until a live
> environment-ready gate has proved a local usable Docker path or the bounded
> setup action has completed and been revalidated.**

For the first implementation unit, it is acceptable for known Windows/WSL
recovery to remain instruction-only. Existing Docker installation behaviour may
be moved earlier so a missing Docker Desktop is discovered/prepared before Python
and model work.

Even after a phase is recorded complete, `environment-ready` is never skipped on
resume.

## 8. Resume/checkpoint strategy

Evolve the state to a versioned schema, for example:

```json
{
  "version": 2,
  "phases_done": [],
  "hardware": null,
  "intent": [],
  "models": {},
  "preflight": {
    "classifier_version": 1,
    "overall": "RECOVERABLE_BLOCKER",
    "reason": "WINDOWS_HYPERVISOR_NOT_RUNNING",
    "action": "restart-after-hypervisor-recovery",
    "observed_at": "2026-08-28T16:00:00Z"
  },
  "pending_reboot": {
    "required": true,
    "reason": "windows-hypervisor-recovery"
  }
}
```

Rules:

- v1 imports conservatively and migrates in memory;
- unknown future schema version fails closed with a stable compatibility message;
- corrupt state is quarantined, not silently trusted and not left requiring the
  user to guess which file to delete;
- old state can help resume product choices, but **never** bypasses live preflight;
- timestamps are audit metadata only. Do not decide readiness from clock age, so a
  system-clock change cannot make a stale checkpoint authoritative;
- a reboot can occur safely after a checkpoint because the next run always
  re-probes before continuing;
- a state change between runs is expected and should replace the old blocker with
  the new measured state.

### Atomic write contract

Do not continue using direct overwrite for safety-critical state.

1. serialize to a uniquely named temporary file in the same directory;
2. close/flush it;
3. parse the temporary JSON back to verify it is complete;
4. atomically replace the target on the same volume, retaining at most one bounded
   backup if useful;
5. ignore/quarantine abandoned temporary files from an interrupted previous run;
6. never leave a half-written target as the only copy.

Tests should simulate interruption before and during replacement.

## 9. Action-required exit contract

Generalize the existing exit-code-10 checkpoint into a stable action-required
contract.

Example reason codes:

```text
PREFLIGHT-FIRMWARE-VIRT-DISABLED
PREFLIGHT-WINDOWS-FEATURE-MISSING
PREFLIGHT-HYPERVISOR-NOT-RUNNING
PREFLIGHT-WSL-NOT-INSTALLED
PREFLIGHT-WSL-UPDATE-REQUIRED
PREFLIGHT-DOCKER-NOT-INSTALLED
PREFLIGHT-DOCKER-STARTING
PREFLIGHT-DOCKER-NOT-RUNNING
PREFLIGHT-DOCKER-REMOTE-CONTEXT
PREFLIGHT-DOCKER-REBOOT-REQUIRED
PREFLIGHT-UNSUPPORTED-PLATFORM
PREFLIGHT-UNKNOWN
```

The outer `.cmd` should distinguish a planned action-required exit from a true
unexpected crash and print the precise action already rendered by the
orchestrator.

Unknown probe failures must still produce a bounded reason code and diagnostic
hint before the generic wrapper can run.

## 10. UX copy principles and examples

One screen, one blocker, one next action.

Firmware virtualization disabled:

```text
AFK AI cannot continue yet.

Hardware virtualization is disabled in your PC firmware.
Docker's local Linux environment cannot start until it is enabled.

Next: enable Intel VT-x / AMD-V / SVM in BIOS/UEFI, save, restart Windows,
then run Install AFK AI.cmd again.

AFK AI will re-check the machine and continue from the saved setup state.
```

Windows hypervisor not running:

```text
AFK AI found virtualization enabled in firmware, but the Windows hypervisor is
not running.

Next: use the documented Windows recovery for this state, restart Windows if
required, then run Install AFK AI.cmd again.

AFK AI will re-check before continuing. It will not edit boot configuration
silently.
```

WSL update required:

```text
AFK AI found WSL, but this Docker WSL path needs a newer WSL version.

Next: update WSL using Microsoft's supported update path, then run the installer
again.
```

Docker remote context:

```text
AFK AI's Docker command is currently targeting a remote Docker engine.
The installer will not deploy AFK AI there.

Next: switch Docker back to the local Docker Desktop engine or clear the Docker
context/host override, then run the installer again.
```

Docker starting:

```text
Docker Desktop is installed and appears to be starting, but the local engine is
not healthy yet.

Next: let Docker Desktop finish starting, then retry. If Docker reports a Windows
virtualization or WSL error, keep that exact error for diagnostics.
```

Unknown:

```text
AFK AI could not prove that the local Windows/Docker environment is ready, so it
stopped before downloading a model.

Reason: PREFLIGHT-UNKNOWN
Copy the bounded diagnostic summary and attach it to an installation report.
```

## 11. Privacy implications

Preflight should need only coarse machine state:

Allowed persistence:

- Friend Beta supported/unsupported OS/build class;
- booleans/enums for firmware, hypervisor, Windows feature, WSL, Docker state;
- WSL/Docker version strings where relevant;
- Docker endpoint **kind/locality**, not remote credentials or full remote URLs;
- stable reason code;
- checkpoint timestamp;
- classifier version.

Do not persist by default:

- usernames;
- full filesystem paths;
- hostnames;
- Docker registry credentials;
- Docker context TLS material;
- remote Docker host addresses;
- WSL distro filesystem contents;
- environment-variable values that may contain secrets;
- chat/model prompts or documents.

If `DOCKER_HOST`/context evidence is needed, persist only a classification such as
`local-npipe`, `remote-tcp`, `remote-ssh`, or `unknown`.

## 12. Failure modes and required behaviour

| Failure | Required behaviour |
|---|---|
| CIM virtualization property missing | UNKNOWN, never guess disabled |
| firmware reports enabled but hypervisor absent | classify Windows hypervisor layer; do not rewrite as firmware-disabled |
| Windows feature query unavailable | UNKNOWN unless another live success proves the active backend works |
| WSL command missing | distinguish absent WSL from unsupported/unneeded backend |
| `wsl --version` unsupported | bounded legacy/inbox compatibility path |
| WSL command hangs | timeout and actionable WSL_UNHEALTHY/UNKNOWN |
| WSL installed but too old for WSL Docker backend | WSL_UPDATE_REQUIRED |
| Docker CLI absent | DOCKER_NOT_INSTALLED/DOCKER_CLI_MISSING |
| Docker Desktop installed but engine stopped | DOCKER_INSTALLED_NOT_RUNNING |
| Docker process exists but engine not ready | DOCKER_STARTING for bounded grace period |
| `docker info` succeeds against remote engine | DOCKER_CONTEXT_REMOTE, never READY |
| local Docker engine is Windows-container mode | DOCKER_LINUX_ENGINE_REQUIRED |
| Docker says virtualization failed while Windows evidence conflicts | UNKNOWN_BLOCKER with both bounded evidence items |
| reboot known to be required | checkpoint + planned exit; live re-probe next run |
| state JSON corrupt | quarantine and rebuild safe state |
| future state schema | compatibility failure; do not downgrade silently |
| atomic write interrupted | previous valid state remains usable; temp ignored/quarantined |
| system clock moves backward/forward | no readiness impact; timestamps informational only |
| no network | local preflight still runs; later download failure reported separately |
| probe throws unexpected exception | map to PREFLIGHT-UNKNOWN before outer generic wrapper |

## 13. RED test matrix

Write these tests before runtime control-flow implementation.

### Pure classifier tests

| Scenario | Expected result |
|---|---|
| local Docker Linux engine healthy | READY |
| firmware disabled, Docker not healthy | FIRMWARE_VIRTUALIZATION_DISABLED |
| firmware enabled + required Windows feature missing | WINDOWS_VIRTUALIZATION_FEATURE_MISSING |
| firmware enabled + features present + hypervisor not launched | WINDOWS_HYPERVISOR_NOT_RUNNING |
| Windows feature enabled but reboot pending | WINDOWS_VIRTUALIZATION_REBOOT_REQUIRED |
| WSL absent on chosen/new-install WSL path | WSL_NOT_INSTALLED |
| WSL below 2.1.5 on WSL backend | WSL_UPDATE_REQUIRED |
| WSL command hangs | WSL_UNHEALTHY/UNKNOWN, never READY |
| healthy local Docker on non-WSL backend, WSL absent | READY with WSL not required |
| Docker absent | DOCKER_NOT_INSTALLED |
| Docker installed, stopped | DOCKER_INSTALLED_NOT_RUNNING |
| Docker process starting, info not yet healthy | DOCKER_STARTING then bounded failure/ready transition |
| Docker executable exists but engine pipe unavailable | not READY |
| `docker info` succeeds through remote context | DOCKER_CONTEXT_REMOTE |
| `DOCKER_HOST` points remote despite local Desktop install | DOCKER_CONTEXT_REMOTE |
| Docker engine reports Windows containers | DOCKER_LINUX_ENGINE_REQUIRED |
| Docker healthy locally | DOCKER_HEALTHY_LOCAL |
| Docker version below an explicitly configured project minimum | DOCKER_VERSION_UNSUPPORTED |
| no project Docker minimum configured | version alone does not block |
| firmware UNKNOWN + no stronger health proof | UNKNOWN_BLOCKER |
| firmware signal conflicts with Docker virtualization error | UNKNOWN_BLOCKER with diagnostic evidence |
| unsupported Friend Beta OS | UNSUPPORTED_PLATFORM |
| localized Windows/WSL output | same classification as equivalent English machine |
| non-admin user, read-only probes available | classification succeeds without elevation |
| read-only probe access denied | UNKNOWN unless stronger live health evidence exists |
| expected probe executable missing | stable absent/unknown state, not uncaught exception |

### Resume/state tests

| Scenario | Expected result |
|---|---|
| blocker changes between runs | second live probe wins |
| resume after reboot | re-probe then continue only if ready |
| stale checkpoint says ready but Docker stopped | stop; stale state never bypasses live gate |
| corrupt state | quarantine + safe recovery path |
| future schema version | explicit compatibility failure |
| interrupted temp write | valid target survives |
| interruption during replacement | either previous or complete new state, never half JSON |
| system clock changed | no readiness bypass or false stale decision |
| repeated rerun after successful recovery | idempotent READY, no repeated recovery action |
| preflight rerun | idempotent and non-mutating |

### Control-flow tests

- preflight runs before Python/package/model setup;
- model-scout network/product work is not entered before environment-ready;
- model pull function is **never invoked** before environment-ready;
- Docker installation/recovery checkpoint occurs before model download;
- no Docker Hub sign-in requirement or sign-in probe exists;
- no read-only probe silently requests whole-installer elevation;
- recoverable blocker uses planned action-required exit rather than generic failure;
- unknown probe exception produces stable reason + bounded diagnostic;
- no-network machine can complete the local preflight and then fail separately at
  the first genuinely network-dependent setup step;
- local Docker context is revalidated immediately before compose/pulls even if a
  checkpoint says it was previously healthy.

### Integration tests without changing the host

Use fixtures/mocks for:

- CIM results;
- optional feature states;
- hypervisor present/not-present evidence;
- `wsl.exe` stdout/stderr/exit/timeout;
- Docker context/host overrides;
- `docker info` stdout/stderr/exit/timeout;
- Docker process/startup state;
- pending reboot evidence;
- v1/v2/future/corrupt installer-state JSON.

Normal automated tests must not enable Windows features, edit BCD, alter firmware,
start real Docker/WSL, or reboot the developer machine.

## 14. Rollback/fallback

If the future implementation causes regressions:

1. revert the preflight implementation commits;
2. keep this design and tests as the known target;
3. fall back to current Friend Beta behaviour while preserving existing state;
4. never migrate state destructively without a version check;
5. never interpret an unknown/future state file as READY.

The design itself is documentation-only and can be reverted independently.

## 15. Likely files for the later implementation

Primary:

- `installer/Install-LocalAI.ps1`
- `installer/installer-common.ps1`
- new focused PowerShell preflight module if separation improves testability
- new focused preflight/state tests under `tests/`

Possible small changes:

- `Install Local AI.cmd` for generalized action-required copy;
- `SUPPORT.md` / installer docs after behaviour is actually implemented.

Avoid unrelated edits to model selection, Open WebUI, site deployment, releases,
or ValClip.

## 16. Toolchain recommendation

### Recommendation: PowerShell 7 for the first implementation

Why:

- the bootstrap already resolves/installs PowerShell 7 before launching the
  orchestrator;
- the classifier therefore runs before Python/package setup;
- PowerShell has direct CIM and Windows feature/process access;
- bounded `wsl.exe`/`docker.exe` interrogation is natural;
- current installer/state code is already PowerShell, reducing packaging and
  handoff risk;
- pure classifier logic can still be written as deterministic functions fed by
  mocked probe results.

Keep Windows PowerShell 5.1 limited to the bootstrap compatibility layer.

Do **not** introduce a native helper unless a required Windows state cannot be
reliably observed through supported CIM/PowerShell/CLI surfaces. Do not duplicate
the authoritative classifier in Python merely because the repository also has a
Python runtime.

Important timing qualification: PowerShell 7 is available before the
**orchestrator** preflight, not before the bootstrap itself. The bootstrap still
has to fetch/verify the pinned payload and may install PowerShell 7 first.

## 17. Safety constraints / non-goals

The next bounded implementation must not:

- edit BIOS/UEFI;
- silently edit BCD/hypervisor boot settings;
- automatically enable/disable Windows features without a separately reviewed,
  explicit recovery action;
- weaken Defender, Smart App Control, antivirus, UAC, or execution policy
  globally;
- require Docker Hub sign-in;
- trust a remote Docker context;
- download a model before the live readiness gate;
- run the whole installer elevated;
- touch ValClip, Ollama production jobs, GPU workloads, release pins, deployment,
  analytics, billing, licensing implementation, or unrelated runtime features.

## 18. Definition of done for the later runtime unit

Implementation is complete only when:

- all RED tests above pass;
- a healthy local Docker environment proceeds without unnecessary WSL blocking;
- firmware-disabled is distinguished from hypervisor-not-running;
- missing Windows feature, WSL absent/outdated/unhealthy, Docker absent/stopped/
  starting/reboot-needed, remote Docker context, wrong engine mode, and unknown
  blocker each produce an appropriate state;
- every external probe has a timeout;
- locale does not change classification;
- a non-admin user can run read-only probes without whole-installer elevation;
- no model download begins before environment readiness;
- persisted state is versioned and atomically replaced;
- stale/corrupt/future checkpoints cannot create false readiness;
- after a fix/reboot, rerunning recognizes prior product progress but revalidates
  the environment and continues automatically;
- Docker sign-in is never required by AFK AI;
- unknown failures produce a useful reason code/diagnostic instead of only
  `Something went wrong`.

## 19. First implementation brief for Claude/Codex

After this design is approved and AFK AI becomes the active engineering lane:

1. write RED classifier/state/control-flow tests first;
2. implement pure PowerShell 7 probe/classifier seams using injected command/CIM
   results in tests;
3. add local Docker-context validation so remote `DOCKER_HOST`/context success
   cannot produce READY;
4. distinguish firmware virtualization, Windows feature state, and hypervisor
   launch state;
5. make WSL blocking conditional on the active/new-install backend rather than a
   universal Docker requirement;
6. migrate v1 installer state conservatively and replace direct state writes with
   the atomic contract;
7. add `environment-preflight` and `environment-ready` before product-specific
   setup/model work;
8. generalize the planned action-required exit while preserving existing exit
   semantics where possible;
9. run only cheap synthetic tests first, then a separately approved clean-machine
   replay;
10. stop before unrelated refactors or platform expansion.

The first real-machine proof target is:

> A machine whose `docker.exe` exists but whose **local** Docker Desktop Linux
> engine cannot run because of virtualization/Windows/WSL state must stop before
> Python/model downloads with one correct action. After the blocker is fixed or a
> required reboot occurs, rerunning must re-probe the live machine and continue
> without trusting the old checkpoint. A remote Docker context must never satisfy
> that gate.
