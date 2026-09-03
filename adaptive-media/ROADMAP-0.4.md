# Adaptive Media 0.4 roadmap

Everything here comes from something measured while certifying 0.3.2 on real
hardware, not from a wishlist. Each item names the evidence, why it matters, and
how it would be proven done. Ranked by value against risk and testability.

The validation machine throughout: RTX 4080 Laptop GPU with Intel UHD Graphics,
240 Hz BOE NE160QDM-NZ8 internal panel, 4K HEVC Dolby Vision/HDR sample, mpv
v0.41.0-1011-g182fa6ca4 with libplacebo v7.371.0.

---

## 1. Tell the user when motion smoothing fell back

**Evidence.** 0.3.2's motion guard engages about six seconds into playback on the
validation panel and stays engaged. The user asked for Smooth motion, silently
receives native cadence, and has no way to know why.

**Why it matters.** This is the single largest honesty gap introduced by 0.3.2.
The fallback is the right behaviour, but a player that quietly ignores a setting
teaches users not to trust its settings.

**Risk.** Medium. Production playback currently spawns mpv and returns; there is
no IPC channel to observe it. Adding one changes the engine's process lifecycle,
which is exactly the area where 0.3.1's launch bug and this release's Compatibility
bug both lived.

**Done when.** A launched session that falls back surfaces one plain line in the
launcher, and the deterministic integration test covers both the fallback and the
no-fallback case without needing an unstable display.

---

## 2. Decide before playback instead of six seconds into it

**Evidence.** Between launch and the guard engaging, the validation panel
accumulates roughly 13 delayed frames and up to 4 dropped frames. The guard needs
that window because mpv's vsync estimate has not converged before it.

**Why it matters.** Six seconds of degraded playback at the start of every file
is the visible cost of the current design.

**Risk.** Medium. A pre-flight measurement needs a real presenting window, so a
hidden probe is not obviously possible; a cached per-display verdict avoids the
probe but needs invalidation when the display configuration changes.

**Done when.** A display that fails the check never starts in display-sync mode,
and a display that passes is never downgraded, both proven by the hardware gate.

---

## 3. Detect variable refresh rate directly

**Evidence.** The guard infers instability from `vsync-jitter` at 0.21 to 1.01
against a healthy 0.01, and from `estimated-display-fps` wandering between 120 and
231 Hz against a nominal 240. The likely cause is VRR/G-Sync on the panel, but
this was never confirmed: reading
`HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Configuration` was denied
under a normal user token, and `nvidia-smi` does not expose it.

**Why it matters.** A direct signal is cheaper, instant, and explainable to the
user; jitter is a proxy that needs a settling window.

**Risk.** Low to medium. Needs a supported API (DXGI/D3DKMT) rather than a
registry read. Worth a spike before committing.

**Done when.** The diagnostics report states the display's VRR state as fact, and
the guard can consult it.

---

## 4. Certify on a machine with a stable display

**Evidence.** Every measurement in this release comes from one panel. The negative
control that matters most - that the guard does **not** engage on a healthy
display - could only be approximated, by proving an unsatisfiable condition leaves
display sync active for a full run.

**Why it matters.** The guard's thresholds were chosen with a 10x margin either
side of the observed values, but the false-positive case has never been observed
on real stable hardware.

**Risk.** Low. It is a second machine, not a code change.

**Done when.** The hardware gate passes on a stable display with
`MotionGuardEngaged: false` and display sync active.

---

## 5. Certify the Compatibility path on hardware

**Evidence.** 0.3.2 fixes the Compatibility D3D11 escape hatch, which was
inoperative on every NVIDIA machine. The fix is proven by deterministic
integration checks and by a manual mpv IPC measurement
(`gpu-api=d3d11`, `gpu-context=d3d11`, `hwdec=d3d11va-copy`), but the hardware
gate itself only certifies the Enhanced/Smooth path.

**Why it matters.** Compatibility is the path users reach for when the managed
renderer misbehaves. It is the least tested and the most load-bearing.

**Risk.** Low. The gate already knows how to launch a plan and read state back.

**Done when.** The gate certifies Compatibility as a second pass and records its
renderer, decoder and frame-timing state.

---

## 6. Make the diagnostics tool runnable unattended

**Evidence.** The gate needs a media file; without `-MediaPath` it opens a picker,
so a support run cannot be scripted, and the run is only as representative as
whatever file the user picked.

**Why it matters.** The tool ships to end users in 0.3.2. Its value depends on a
support request producing a comparable report.

**Risk.** Low. A short bundled synthetic clip, or a documented default.

**Done when.** The diagnostics entry produces a report with no arguments and no
file dialog.

---

## 7. Record machine contention in the report

**Evidence.** `frame-drop-count` over a 12 s window measured 0, 3, 5, 38 and 47
across runs on the same build and the same machine, moving with system load and
with whether the window was fullscreen. The two clean gate runs and the failing
ones differ by environment, not by build.

**Why it matters.** A hard gate on a load-sensitive counter is a flaky gate. The
report should carry enough context to tell a real regression from a busy machine.

**Risk.** Low. Sampling GPU utilisation and running video processes alongside the
existing metrics.

**Done when.** A report says what else the machine was doing, and a support reader
can tell a contended run from a clean one.

---

## 8. Validate the RTX VSR and RTX Video HDR paths on hardware

**Evidence.** Both are covered by deterministic launch-plan assertions
(`--gpu-api=d3d11` paired with `--gpu-context=d3d11`, `scaling-mode=nvidia`,
`nvidia-true-hdr=yes`) but neither has ever been measured running.

**Why it matters.** They are the two options most likely to be blamed for a bad
experience, and the two with no runtime evidence behind them.

**Risk.** Medium. They depend on driver support that varies.

**Done when.** The gate reports their effective runtime state, or the README says
plainly that they are unverified at runtime.

---

## Deliberately not on this list

- **Weakening any frame-drop limit.** The output and decoder drop gates stayed at
  1 and 0 through this entire release and should stay there.
- **Claiming native Dolby Vision or Profile 7 FEL passthrough, guaranteed Atmos
  passthrough, or universal HDR-TV switching.** None of these were proven and the
  existing honest limitations should survive 0.4.
