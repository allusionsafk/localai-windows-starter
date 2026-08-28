# Virtualization / Docker / WSL preflight and resumable recovery

Status: **implementation-ready design; runtime not implemented**  
Scope: Windows Friend Beta installer only

This document defines the next bounded AFK AI installer unit. It is a design and
test contract only; it does not enable Windows features, start Docker/WSL, edit
boot configuration, download models, or alter the live installer flow.

## 1. Problem statement

A clean-machine Friend Beta run reached Python setup, model selection, and Docker
Desktop installation before Docker reported that virtualization support was
unavailable. The installer discovered the platform blocker too late, after useful
setup work, and the outer `.cmd` ultimately reduced the failure to the generic
`Something went wrong` path.

The next installer unit must:

1. inspect the **local** Windows virtualization / Docker environment early;
2. distinguish known recoverable blockers from unknown state;
3. give one precise next action;
4. persist a durable checkpoint;
5. tolerate a reboot between attempts;
6. re-probe the live machine on every rerun;
7. prevent model downloads before environment readiness is proven.

## 2. Current flow, verified from `master`

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

Current orchestrator order:

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

Current behaviour relevant to this design:

- `bootstrap.ps1` can begin under Windows PowerShell 5.1. It resolves or installs
  PowerShell 7 before launching `Install-LocalAI.ps1`.
- `vet` measures GPU/VRAM/CPU/RAM/disk and chooses a capability tier. It does not
  classify firmware virtualization, the Windows hypervisor layer, WSL readiness,
  Docker context, or Docker-engine health.
- Python/package setup and model scouting occur before Docker readiness is known.
- `ollama-docker` primarily treats the presence of `docker.exe` as Docker
  presence. If the executable already exists, the phase can succeed without
  proving that the **local** Docker Desktop Linux engine is healthy.
- if Docker is absent, the phase installs Docker Desktop, writes the current
  `pending_reboot` checkpoint, and exits through the planned exit-code-10 path.
- `pulls` comes later and can download/build a selected model after only that weak
  Docker-presence check.
- non-checkpoint failures can reach the root `.cmd` generic failure message.

## 3. Existing persistence and resume mechanism

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

Current strengths:

- completed phases are persisted;
- a rerun can continue after the Docker installation checkpoint;
- product selections do not necessarily need to be recomputed.

Current weaknesses:

- state is written with direct `Set-Content`, not an explicit atomic-replacement
  contract;
- corrupt JSON tells the user to delete the state file manually;
- `pending_reboot` is only a boolean and does not record a reason;
- no classifier/probe version is stored;
- a completed phase can be skipped even if machine state changed;
- no safety-critical checkpoint is required to be revalidated live.

**Normative rule:** persisted state is a resume hint and audit record. It is never
proof that the environment is currently ready.

## 4. Friend Beta observed failure

Observed sequence:

```text
Python setup
-> model scout / qwen3.5:4b-16k recommendation
-> Docker Desktop install
-> Docker reports virtualization support unavailable
```

This proves that the blocker was found too late. It does **not** prove which
layer was at fault. Plausible causes include:

- firmware virtualization disabled;
- required Windows virtualization component missing;
- Windows hypervisor installed but not launched at boot;
- WSL absent, outdated, unhealthy, or awaiting a reboot;
- Docker Desktop installed but stopped/starting/reboot-blocked;
- another Docker Desktop failure.

The classifier must prefer measured state over interpreting one Docker error
string as a diagnosis.

## 5. Platform facts and project policy

Use supported Windows/Docker interfaces and current vendor documentation.

### 5.1 Windows-visible virtualization signals

`Win32_Processor.VirtualizationFirmwareEnabled` is a read-only Windows-visible
signal that firmware enabled virtualization extensions. Missing/null/error state
is **UNKNOWN**, not proof that firmware virtualization is disabled.

`Win32_ComputerSystem.HypervisorPresent` is a separate signal that a hypervisor
is currently present. Do not collapse it into firmware state.

Microsoft references:

- https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-processor
- https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-computersystem

### 5.2 WSL

Useful documented commands include:

```text
wsl.exe --version
wsl.exe --status
wsl.exe --list --verbose
```

WSL feature/Virtual Machine Platform changes can require a reboot.

Microsoft references:

- https://learn.microsoft.com/en-us/windows/wsl/basic-commands
- https://learn.microsoft.com/en-us/windows/wsl/install

### 5.3 Docker Desktop

Current Docker Desktop documentation requires WSL 2.1.5 or later **when using
the WSL 2 backend** and requires hardware virtualization for that path. Docker
also supports other Windows backends in applicable configurations.

Therefore:

- WSL 2 is AFK AI's preferred/current Friend Beta path for a new Docker Desktop
  setup;
- WSL is **not** a universal prerequisite if an already-installed, verified local
  Docker Desktop Linux engine is healthy on another supported backend;
- a normal user Linux distribution is not required merely for Docker Desktop's
  WSL backend;
- Docker Desktop must not be made dependent on Docker Hub sign-in by AFK AI.

Docker references:

- https://docs.docker.com/desktop/setup/install/windows-install/
- https://docs.docker.com/desktop/features/wsl/
- https://docs.docker.com/desktop/troubleshoot-and-support/troubleshoot/topics/

### 5.4 Docker contexts are part of readiness

A Docker CLI can target local or remote daemons. `DOCKER_HOST`, `DOCKER_CONTEXT`,
and CLI flags can override the current context.

A successful `docker info` against a remote daemon must **never** make AFK AI
report the local Windows environment as ready.

Docker reference:

- https://docs.docker.com/engine/manage-resources/contexts/

## 6. State model

Keep component state and derive one aggregate disposition. Do not use one flat
enum for all evidence.

### 6.1 Platform support

```text
SUPPORTED
UNSUPPORTED_PLATFORM
UNKNOWN
```

The public Friend Beta target is Windows 11. A known unsupported platform is not
an unknown blocker and must never be classified READY merely because a Docker
endpoint is reachable.

### 6.2 Firmware virtualization

```text
READY
FIRMWARE_VIRTUALIZATION_DISABLED
UNKNOWN
```

Primary signal:

```powershell
Get-CimInstance Win32_Processor |
  Select-Object VirtualizationFirmwareEnabled
```

Classification rules:

- all reliable, non-null processor results are `True` -> READY;
- all reliable, non-null processor results are `False` ->
  FIRMWARE_VIRTUALIZATION_DISABLED;
- mixed `True`/`False`, null, unsupported property, access failure, malformed
  result, or timeout -> UNKNOWN.

Do not use localized Task Manager or `systeminfo` prose as the primary signal.

### 6.3 Windows virtualization / hypervisor layer

```text
READY
WINDOWS_VIRTUALIZATION_FEATURE_MISSING
WINDOWS_HYPERVISOR_NOT_RUNNING
WINDOWS_VIRTUALIZATION_REBOOT_REQUIRED
UNKNOWN
```

This layer distinguishes:

1. optional Windows components needed for the chosen backend;
2. whether a hypervisor is present/usable now;
3. whether a known relevant reboot is pending.

Useful evidence can include:

- `Win32_ComputerSystem.HypervisorPresent`;
- `VirtualMachinePlatform` state when the WSL path is relevant;
- `Microsoft-Windows-Subsystem-Linux` state when the WSL path is relevant;
- bounded read-only boot-configuration evidence if needed to distinguish an
  installed-but-not-launched hypervisor;
- pending-reboot evidence tied to a relevant Windows/Docker transition.

`WINDOWS_HYPERVISOR_NOT_RUNNING` is intentionally separate from firmware state.
The implementation may diagnose this condition; it must not silently edit BCD or
boot configuration.

If a read-only probe needs privilege and has no documented non-admin fallback,
return UNKNOWN rather than elevating the whole installer.

### 6.4 WSL state

```text
READY
NOT_REQUIRED_FOR_CURRENT_HEALTHY_BACKEND
WSL_NOT_INSTALLED
WSL_UPDATE_REQUIRED
WSL_UNHEALTHY
WSL_REBOOT_REQUIRED
UNKNOWN
```

Rules:

- use bounded documented commands;
- do not depend on English labels in command output;
- use exit status and locale-independent numeric data where possible;
- if `wsl --version` is unsupported, distinguish an older/inbox WSL path from a
  missing command;
- a WSL command timeout is not success; classify WSL_UNHEALTHY or UNKNOWN based
  on the remaining evidence;
- WSL below Docker's documented WSL-backend minimum is WSL_UPDATE_REQUIRED;
- absence of a normal Linux distribution is not itself a Docker blocker;
- if a verified local Docker Desktop Linux engine is already healthy on a backend
  that does not require WSL, WSL absence must not override that health result.

### 6.5 Docker state

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

1. Docker Desktop installation / CLI presence is consistent with the expected
   local product path.
2. Resolve the effective Docker target, considering `DOCKER_HOST`,
   `DOCKER_CONTEXT`, `docker context show`, and `docker context inspect`.
3. Reject TCP/SSH/other remote targets as `DOCKER_CONTEXT_REMOTE` for installer
   readiness. Do not deploy AFK AI compose resources there.
4. Run bounded `docker info` against the intended local endpoint.
5. Confirm the reachable engine is suitable for AFK AI's Linux-container compose
   stack.

Do not hard-code one context name; validate endpoint locality and engine
characteristics. On Windows, a local named-pipe Docker Desktop endpoint is an
expected pattern, but the implementation should classify the endpoint rather
than matching one literal context name.

`DOCKER_VERSION_UNSUPPORTED` is only valid if AFK AI defines and documents a
minimum Docker version needed for a concrete feature. Do not invent a version
floor merely to populate the state model.

A Docker Desktop process with an engine that is still unavailable is
`DOCKER_STARTING` for a bounded grace period, then
`DOCKER_INSTALLED_NOT_RUNNING` or UNKNOWN based on evidence.

No Docker Hub login belongs in the readiness contract.

### 6.6 Aggregate disposition

```text
READY
RECOVERABLE_BLOCKER
UNSUPPORTED_PLATFORM
UNKNOWN_BLOCKER
```

**Normative precedence:**

1. known unsupported Friend Beta platform -> UNSUPPORTED_PLATFORM;
2. contradictory or insufficient safety-critical evidence -> UNKNOWN_BLOCKER,
   unless a stronger live success directly proves that the questioned backend
   component is not required;
3. verified `DOCKER_HEALTHY_LOCAL` Linux engine can satisfy backend readiness even
   if an unused backend-specific probe such as WSL is unavailable;
4. one or more known actionable blockers -> RECOVERABLE_BLOCKER;
5. only otherwise -> READY.

Examples:

- Windows 10 + healthy Docker: UNSUPPORTED_PLATFORM for this Friend Beta, not
  READY.
- Windows 11 + healthy local Hyper-V Docker engine + WSL absent: READY with WSL
  marked NOT_REQUIRED_FOR_CURRENT_HEALTHY_BACKEND.
- Windows 11 + `docker info` succeeds only against SSH/TCP remote context:
  RECOVERABLE_BLOCKER (`DOCKER_CONTEXT_REMOTE`), not READY.
- firmware signal UNKNOWN + local Docker not healthy: UNKNOWN_BLOCKER.

## 7. Probe contract

Implement probes as read-only functions returning structured evidence.

Illustrative shape:

```powershell
[pscustomobject]@{
  Platform = [pscustomobject]@{
    Status = 'SUPPORTED'
  }
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
    EndpointKind = 'local-npipe'
    EngineOs = 'linux'
  }
  Overall = 'READY'
  Action = $null
  Code = 'PREFLIGHT-READY'
}
```

Probe requirements:

- explicit timeouts for every external command;
- no network required for the probe itself;
- no model download;
- no Docker sign-in;
- no automatic BIOS, BCD, Windows-feature, WSL-update, or service mutation in
  the read-only layer;
- no dependence on English CLI prose;
- bounded captured output;
- stable machine-readable reason codes;
- exceptions mapped to UNKNOWN evidence rather than escaping directly to the
  generic outer error path.

## 8. Exact insertion point

Future flow:

```text
bootstrap (verify payload, ensure PowerShell 7)
-> environment-preflight          # new, read-only, live
-> environment-recovery/prepare   # bounded action only if separately approved
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

The critical invariant is:

> **No model pull and no product-specific Python/model setup begins until a live
> environment-ready gate has proved a usable local Docker path, or the bounded
> setup action has completed and then been revalidated.**

A missing Docker Desktop installation may use the existing Docker install action
moved earlier in the sequence. Known Windows/WSL recovery can remain
instruction-only in the first implementation unit.

`environment-ready` is safety-critical and is never skipped merely because a
previous run marked a phase done.

## 9. Resume and checkpoint strategy

Evolve state to a versioned schema. Example:

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

- import v1 conservatively and migrate in memory;
- update every current reader/writer that assumes `pending_reboot` is a boolean
  before changing its persisted type;
- reject unknown future schema versions with a stable compatibility message;
- quarantine corrupt state and rebuild safe defaults instead of asking the user
  to guess which file to delete;
- keep product choices where safe, but never let old state bypass live preflight;
- timestamps are audit metadata only; system-clock changes must not create or
  remove readiness;
- a reboot is safe between attempts because the next run always re-probes;
- changed machine state on the next run replaces the previous blocker evidence.

### Atomic state write contract

For safety-critical state, replace direct overwrite with:

1. serialize to a unique temp file in the same directory/volume;
2. close and flush it;
3. parse the temp JSON back to verify completeness;
4. atomically replace the target, optionally retaining one bounded backup;
5. ignore or quarantine abandoned temp files from interrupted prior runs;
6. never leave a half-written target as the only state copy.

Tests must simulate interruption before and during replacement.

## 10. Planned action-required exit contract

Generalize the existing Docker-specific planned checkpoint into a stable action
required contract while preserving an unambiguous distinction from unexpected
failure.

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

The outer `.cmd` should print the precise action already rendered by the
orchestrator for a planned pause. Unexpected probe failures must first be caught
and mapped to a stable UNKNOWN reason plus bounded diagnostic evidence so the
user does not receive only `Something went wrong`.

## 11. UX copy examples

One blocker, one next action.

### Firmware virtualization disabled

```text
AFK AI cannot continue yet.

Hardware virtualization is disabled in your PC firmware.
Docker's local Linux environment cannot start until it is enabled.

Next: enable Intel VT-x / AMD-V / SVM in BIOS/UEFI, save, restart Windows,
then run Install AFK AI.cmd again.

AFK AI will re-check the machine and continue from the saved setup state.
```

### Windows hypervisor not running

```text
AFK AI found virtualization enabled in firmware, but the Windows hypervisor is
not running.

Next: use the documented Windows recovery for this state, restart Windows if
required, then run Install AFK AI.cmd again.

AFK AI will re-check before continuing. It will not edit boot configuration
silently.
```

### WSL update required

```text
AFK AI found WSL, but this Docker WSL path needs a newer WSL version.

Next: update WSL using Microsoft's supported update path, then run the installer
again.
```

### Remote Docker context

```text
AFK AI's Docker command is targeting a remote Docker engine.
The installer will not deploy AFK AI there.

Next: switch Docker back to the local Docker Desktop engine or clear the Docker
context/host override, then run the installer again.
```

### Docker starting

```text
Docker Desktop is installed and appears to be starting, but the local engine is
not healthy yet.

Next: let Docker Desktop finish starting, then retry. If Docker reports a Windows
virtualization or WSL error, keep that exact error for diagnostics.
```

### Unknown blocker

```text
AFK AI could not prove that the local Windows/Docker environment is ready, so it
stopped before downloading a model.

Reason: PREFLIGHT-UNKNOWN
Copy the bounded diagnostic summary and attach it to an installation report.
```

## 12. Privacy implications

Allowed persisted evidence:

- supported/unsupported OS/build class;
- firmware/hypervisor/Windows-feature/WSL/Docker enums and booleans;
- WSL/Docker version strings when relevant;
- Docker endpoint **kind/locality**, not remote endpoint details;
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
- WSL distribution filesystem contents;
- environment-variable values that may contain secrets;
- chats, prompts, documents, or model content.

If `DOCKER_HOST` or context evidence is needed, persist only a classification such
as `local-npipe`, `remote-tcp`, `remote-ssh`, or `unknown`.

## 13. Failure modes

| Failure | Required behaviour |
|---|---|
| CIM firmware property missing | UNKNOWN; never guess disabled |
| processor firmware signals disagree | UNKNOWN |
| firmware enabled but hypervisor absent | classify Windows hypervisor layer, not firmware-disabled |
| Windows feature query unavailable | UNKNOWN unless stronger live evidence proves active backend readiness |
| WSL command missing | distinguish absent WSL from unneeded backend |
| `wsl --version` unsupported | bounded older/inbox compatibility path |
| WSL command hangs | timeout; WSL_UNHEALTHY/UNKNOWN, never success |
| WSL too old for WSL Docker backend | WSL_UPDATE_REQUIRED |
| Docker CLI absent | DOCKER_NOT_INSTALLED / DOCKER_CLI_MISSING |
| Docker installed, engine stopped | DOCKER_INSTALLED_NOT_RUNNING |
| Docker process present, engine not ready | DOCKER_STARTING for bounded grace period |
| `docker info` succeeds against remote endpoint | DOCKER_CONTEXT_REMOTE, never READY |
| local engine is Windows-container mode | DOCKER_LINUX_ENGINE_REQUIRED |
| Docker reports virtualization error but Windows evidence conflicts | UNKNOWN_BLOCKER with both bounded evidence items |
| relevant reboot known to be required | checkpoint + planned exit + live re-probe next run |
| state JSON corrupt | quarantine + safe recovery |
| future state schema | explicit compatibility failure |
| atomic write interrupted | previous or complete new state survives; never half JSON |
| system clock changes | no readiness effect |
| no network | local preflight succeeds/fails independently; download failure occurs later |
| probe throws | map to PREFLIGHT-UNKNOWN before generic wrapper |

## 14. RED test matrix

Write these tests before runtime control-flow implementation.

### Classifier tests

| Scenario | Expected result |
|---|---|
| supported Windows + healthy local Docker Linux engine | READY |
| unsupported Friend Beta OS + healthy Docker | UNSUPPORTED_PLATFORM |
| all firmware signals false | FIRMWARE_VIRTUALIZATION_DISABLED |
| firmware processor signals disagree | UNKNOWN_BLOCKER |
| firmware enabled + required Windows feature missing | WINDOWS_VIRTUALIZATION_FEATURE_MISSING |
| firmware enabled + features present + hypervisor not launched | WINDOWS_HYPERVISOR_NOT_RUNNING |
| Windows feature enabled but relevant reboot pending | WINDOWS_VIRTUALIZATION_REBOOT_REQUIRED |
| WSL absent on selected/new-install WSL path | WSL_NOT_INSTALLED |
| WSL below documented minimum on WSL backend | WSL_UPDATE_REQUIRED |
| WSL command hangs | WSL_UNHEALTHY/UNKNOWN, never READY |
| healthy local Docker on non-WSL backend + WSL absent | READY with WSL not required |
| Docker absent | DOCKER_NOT_INSTALLED |
| Docker executable exists but local engine pipe unavailable | not READY |
| Docker installed and stopped | DOCKER_INSTALLED_NOT_RUNNING |
| Docker process starting but engine not ready | DOCKER_STARTING then bounded transition |
| `docker info` succeeds through remote context | DOCKER_CONTEXT_REMOTE |
| `DOCKER_HOST` points remote despite local Desktop install | DOCKER_CONTEXT_REMOTE |
| local engine reports Windows containers | DOCKER_LINUX_ENGINE_REQUIRED |
| local Linux engine healthy | DOCKER_HEALTHY_LOCAL |
| Docker version below an explicitly configured project minimum | DOCKER_VERSION_UNSUPPORTED |
| no project Docker minimum configured | version alone does not block |
| firmware UNKNOWN + no stronger live backend proof | UNKNOWN_BLOCKER |
| Docker virtualization error conflicts with Windows evidence | UNKNOWN_BLOCKER |
| localized Windows/WSL output | same result as equivalent English machine |
| non-admin user + read-only probes available | succeeds without elevation |
| read-only probe access denied | UNKNOWN unless stronger live proof exists |
| expected probe executable missing | stable absent/unknown state; no uncaught exception |

### Resume/state tests

| Scenario | Expected result |
|---|---|
| machine blocker changes between runs | second live probe wins |
| resume after reboot | re-probe; continue only if ready |
| stale checkpoint says READY but Docker later stopped | stop; live state wins |
| corrupt state | quarantine + safe recovery |
| future schema version | explicit compatibility failure |
| v1 boolean `pending_reboot` | conservative migration succeeds |
| interrupted temp write | valid target remains usable |
| interruption during replacement | previous or complete new JSON, never partial target |
| system clock changes | no false readiness/staleness decision |
| repeated rerun after successful recovery | idempotent READY; no repeated recovery action |
| repeated preflight | non-mutating/idempotent |

### Control-flow tests

- preflight runs before Python/package/model setup;
- model scout/product network work is not entered before environment readiness;
- model-pull function is **never invoked** before environment readiness;
- Docker installation/recovery checkpoint occurs before model download;
- local Docker target is revalidated immediately before Docker-dependent work;
- no Docker Hub sign-in requirement or sign-in probe exists;
- read-only probe does not silently elevate the whole installer;
- recoverable blocker uses planned action-required exit, not generic failure;
- unexpected probe exception produces stable reason + bounded diagnostic;
- a no-network machine can complete local preflight and then fail separately at
  the first genuinely network-dependent download step.

### Fixture-only integration tests

Mock/fixture:

- CIM firmware results, including disagreement;
- `HypervisorPresent` state;
- optional Windows feature states;
- pending reboot evidence;
- `wsl.exe` stdout/stderr/exit/timeout;
- Docker context and host overrides;
- Docker endpoint type;
- `docker info` stdout/stderr/exit/timeout;
- Docker process/startup state;
- v1/v2/future/corrupt state JSON.

Normal automated tests must not enable Windows features, edit BCD, alter firmware,
start real Docker/WSL, reboot the machine, or download models.

## 15. Rollback and fallback

If the future implementation regresses:

1. revert the preflight implementation commits;
2. retain this design/test contract;
3. fall back to current Friend Beta behaviour without destructively rewriting
   existing installer state;
4. never downgrade or interpret unknown/future state as READY.

This design document itself is independently revertible.

## 16. Files likely to change later

Primary:

- `installer/Install-LocalAI.ps1`
- `installer/installer-common.ps1`
- focused PowerShell preflight module if separation improves testability
- focused preflight/state tests under `tests/`

Possible small changes:

- `Install Local AI.cmd` for generalized action-required copy;
- `SUPPORT.md` / installer docs **after** behaviour exists.

Do not mix unrelated model, Open WebUI, website, release, deployment, or ValClip
work into this unit.

## 17. Toolchain recommendation

### PowerShell 7 for the first implementation

PowerShell 7 is the best fit because:

- `bootstrap.ps1` already resolves/installs it before launching the orchestrator;
- the preflight can therefore run before Python/package setup;
- CIM, Windows feature/process state, `wsl.exe`, and `docker.exe` interrogation are
  natural from PowerShell;
- the current installer and state helpers already live in PowerShell;
- pure classification can be deterministic and fixture-driven in tests.

Keep Windows PowerShell 5.1 as bootstrap compatibility glue.

Do not introduce Rust/C++ merely to obtain a native helper. Add one only if a
required state cannot be observed reliably through supported CIM/PowerShell/CLI
surfaces. Do not duplicate the authoritative classifier in Python simply because
Python exists later in the stack.

Timing qualification: PowerShell 7 is available before the **orchestrator
preflight**, not before bootstrap work. Bootstrap still performs verified payload
fetching and may need to install PowerShell 7 first.

## 18. Safety constraints / non-goals

The implementation must not:

- edit BIOS/UEFI;
- silently edit BCD/hypervisor boot settings;
- automatically enable/disable Windows features without a separately reviewed,
  explicit recovery action;
- globally weaken Defender, Smart App Control, antivirus, UAC, or PowerShell
  execution policy;
- require Docker Hub sign-in;
- trust a remote Docker context as local readiness;
- download a model before the live readiness gate;
- run the whole installer elevated;
- touch ValClip, GPU workloads, release pins, deployments, telemetry, billing, or
  unrelated runtime features.

## 19. Definition of done for the later runtime unit

The later implementation is complete only when:

- the RED tests above pass;
- unsupported platform cannot be overridden by a healthy remote/local Docker
  endpoint;
- firmware disabled is distinguished from firmware UNKNOWN and from
  hypervisor-not-running;
- Windows feature, WSL, Docker absent/stopped/starting/reboot-needed, remote
  context, wrong engine mode, and unknown blockers receive coherent states;
- every external probe has a timeout;
- locale does not change classification;
- non-admin read-only probing does not require whole-installer elevation;
- no model download or product-specific Python/model setup starts before the
  live readiness gate;
- state is versioned and atomically replaced;
- stale/corrupt/future checkpoints cannot create false readiness;
- after a fix/reboot, rerun preserves safe product progress but revalidates the
  machine before continuing;
- Docker sign-in is never required by AFK AI;
- unknown failures expose a stable reason/diagnostic before any generic wrapper.

## 20. First implementation brief for Claude/Codex

When AFK AI becomes the active engineering lane:

1. write the RED classifier/state/control-flow tests first;
2. implement fixture-injectable PowerShell 7 read-only probes/classifier;
3. validate the effective Docker target and reject remote contexts/host overrides;
4. distinguish firmware virtualization, Windows feature state, and hypervisor
   launch state;
5. make WSL blocking conditional on the active/new-install backend;
6. migrate v1 state conservatively and implement the atomic replacement contract;
7. insert `environment-preflight` and `environment-ready` before product-specific
   setup/model work;
8. generalize the planned action-required exit while preserving existing exit
   semantics where possible;
9. run cheap synthetic tests before any separately approved clean-machine replay;
10. stop before unrelated refactors.

First real-machine proof target:

> A machine whose `docker.exe` exists but whose **local** Docker Desktop Linux
> engine cannot run because of virtualization/Windows/WSL state must stop before
> Python/model downloads with one correct action. After the blocker is fixed or a
> required reboot occurs, rerunning must live-reprobe and continue without
> trusting the old checkpoint. A remote Docker context must never satisfy the
> gate, and an explicitly unsupported Friend Beta OS must never be classified
> READY merely because Docker happens to be healthy.
