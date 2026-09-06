# Adaptive Media 0.4 implementation plan

Goal: one inspectable, tested playback plan from the consumer UI to mpv, with adaptive RTX processing and honest runtime feedback.

Starting point: 66290a48061d97a568a099f9d925051f254af5c3. Historical 0.3.2 scripts and publication remain unchanged. No push, tag, merge, or publication. Preserve user settings and existing installs.

Architecture: introduce `source/` as canonical reviewed development source, seeded from the verified final patch stack. Keep the historical transport and add a fail-closed reconstruction command and file manifest. Typed .NET owns playback probing, immutable plan construction, subprocess arguments, IPC observation, diagnostics and fallback. Retain existing Windows inventory interop through a hidden bridge initially. Runtime destination changes must use observed video/display dimensions, not an assumed display resolution. NVIDIA reference remains Vulkan/winvk/NVDEC; RTX uses D3D11/D3D11VA/VPP; Compatibility remains independent.

1. Reconstruct and baseline: verify SHA-256, apply exact workflow order, compare installed engine, build original integration tests. Add a real probe regression that fails against 0.3.2's suppressed marker.
2. Playback core: add typed request/media/capability/target records and one pure builder. Test final argument vectors for renderer, aspect-fit scaling, no-upscale, unknown metadata, non-RTX, motion, cleanup, HDR gating, PCM defaults and hostile paths. Probe through captured mpv.exe with explicit terminal output; timeout, drain both streams and use ArgumentList.
3. Session: GUI and headless command call the same preparation and launch methods. Observe IPC, adapt VPP to window/monitor changes, report requested versus constructed versus observed states. On enhancement failure retry once conservatively with explicit history. Retain measured motion guard and expose fallback.
4. Packaging (independent): harden installer/provisioning and PS5.1 tooling, route diagnostics to native app, hide helper windows, require dependency hash, preserve settings, validate isolated install/upgrade/uninstall. Keep exact installer hash provenance.
5. UX/settings: keep existing visual language; improve responsive sizing, plan feedback, progressive system details, truthful cleanup/HDR text, validated versioned settings and atomic saves. Never claim NVIDIA driver activity from argv.
6. Verification: build, run pure matrix tests and real mpv probe/path/session tests, PS5.1/7 checks, isolated installer smoke tests, collect real GPU IPC metrics. Review final diff, fix findings, commit coherent local changes, document remaining manual hardware checks and exact commands.

Root cause established: installed engine SHA-256 matches reconstructed engine; real mpv probe emits nothing with `--really-quiet`, so Probe-Media returns null and Add-PerVideoEnhancements never constructs VPP. Existing injected integration probe bypasses this failure. Additional divergence: PlanJson omits destination/audio/HDR decisions and deletes its playlist before consumers can launch it.
