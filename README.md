<p align="center">
  <b>perf-lab</b><br>
  <i>Diagnosing and fixing Android jank on a 2.7 GB device - without root</i>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/android-8.0%2B-3DDC84?style=flat-square" alt="Android 8+">
  <img src="https://img.shields.io/badge/root-required-no-3DDC84?style=flat-square" alt="No root required">
  <img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT">
  <img src="https://img.shields.io/badge/shell-adb%20only-E65100?style=flat-square" alt="ADB shell only">
</p>

---

## The problem

A 2-year-old vivo phone that should be usable was **unusable**. Apps froze,
scrolling stuttered, and every app you switched away from had **reloaded from
scratch** when you came back.

The instinct is to reach for a "phone optimizer" app. That does not work,
because the symptom has a specific cause that optimizers do not touch.

This repository is the diagnosis and the fix, with the reasoning and the
measurements preserved.

## What was actually wrong

Not "too many apps". **Three separate defects stacked on top of each other:**

**1. Two independent kill systems, not one.**
Android's low-memory killer was terminating background apps. Underneath it,
vivo's own process supervisors (`com.vivo.sps`, `com.vivo.appfilter`,
`com.vivo.safecenter`) were running a second, vendor-specific kill layer.
The kernel counter showed **19,385 kills** with no sign of the second layer -
which is why the obvious fix did nothing.

**2. The kill tier was being reached too early.**
Android demotes apps that have not been used recently into a bucket that the
LMKD harvests first. Measured directly on a backgrounded app: `oom_score_adj`
of **900+**. That is inside the kill zone. With the demotion disabled the same
app holds `oom_score_adj` of **0**.

**3. Swap was exhausted, so there was no pressure valve.**
1.5 GB of zram was **99.8% full** - 3.5 MB free. Once swap is full the kernel
has nowhere to page to, so it starts killing processes to make room instead.
`kswapd` and `vswap_fn` were burning **208% and 295% CPU** continuously
moving pages back and forth for nothing.

## The result

| Metric | Before | After |
|---|---:|---:|
| **Low-memory process kills** | 19,385 | **0** |
| **App deaths (LOW_MEMORY)** | 1,971 | **0** |
| **SystemUI janky frames** | 48.83% | **4.08%** |
| **SystemUI p99 frame time** | 1,950 ms | **34 ms** |
| **Launcher janky frames** | 21.66% | **4.26%** |
| **MemAvailable** | 445 MB | **1,062 MB** |
| **Swap free** | 3.5 MB | **336 MB** |
| **system_server CPU** | 730% | **2%** |
| Storage free | 14 GB | **19 GB** |

Full numbers, per-mechanism attribution, and the negative results are in
**[data/RESULTS.md](data/RESULTS.md)**.

### The most useful diagnostic in the whole repo

GPU frame time was **identical before and after** - 5 ms in both cases. The
frame budget was never being missed by the graphics pipeline.

```
Before:  50th percentile 20 ms   |  50th GPU percentile  5 ms
After:   50th percentile 12 ms   |  50th GPU percentile  5 ms
```

The UI thread was waiting on memory, not on the renderer. That single
observation is what redirected the entire investigation away from "make the
GPU faster" - which on an Adreno 610 would have been hopeless - and toward
memory pressure, which was fixable.

## Quick start

```bash
git clone https://github.com/AkarshBandi/android-perf-lab.git
cd android-perf-lab

./perf-lab.sh status          # what is the device doing right now
./perf-lab.sh diagnose        # full root-cause report (read-only, safe)
./perf-lab.sh apply --dry-run # show every change before making it
./perf-lab.sh apply           # apply the tuning
./perf-lab.sh status          # verify
./perf-lab.sh rollback        # restore vendor defaults
```

`diagnose` prints a 10-section report: memory pressure, app-death breakdown
by reason, kill counts, the top RAM consumers, swap-thrash detection, CPU
governors, frame timing, which vendor packages are killing other apps, standby
buckets, and wakelock holders.

## How it works

Everything runs as the **ADB shell user (uid 2000)**. No root, no flashing,
nothing is written to `/system`. Every change is reversible via `rollback`.

| Lever | What it does |
|---|---|
| `app_standby_enabled=0` | Stops apps being demoted into the LMKD kill tier. Verified: background `oom_score_adj` 900+ -> 0. |
| Vendor supervisors disabled | Removes vivo's second kill layer. 15 packages, each verified non-critical (no IME, launcher, dialer, or biometric component). |
| `cached_apps_freezer=disabled` | Removes the freeze/thaw stall when resuming an app. |
| Animation scales `0.5x` | Animations finish in half the time. The single biggest perceived-smoothness win on a 60 Hz panel. |
| `cmd game downscale` | Renders at reduced resolution. **Opt-in, off by default** - it reduces GPU work but upscaling to the panel makes text look larger and softer, which on a 720p display reads as "the font size changed". See [docs/RESEARCH-NOTES.md](docs/RESEARCH-NOTES.md) §9. |
| Doze whitelist | Keeps foreground apps out of deep idle. |
| `pm uninstall --user 0` | Removes unused packages in a way that **survives reboots**. |

### A persistence detail worth knowing

Plain `pm uninstall` on a system package is silently reverted by the vendor
package manager on the next boot. The uninstall must be scoped to the user:

```bash
pm uninstall --user 0 <package>    # persists
pm uninstall <package>             # reverts on reboot
```

Verified by rebooting the device and re-checking.

## Repository layout

```
perf-lab.sh            apply / reapply / rollback / status
diagnose.sh            10-section read-only root-cause report
benchmark.sh           reproducible frame-timing benchmark
ab-test.sh             A/B the same app tuned vs. untuned
collect.sh             point-in-time metric snapshot
profiles/              per-device-family configuration
data/RESULTS.md        every measured number, plus what did not work
docs/HARDWARE.md       the test device
```

Device-specific choices live in `profiles/*.profile`, so the tooling is
reusable rather than hardcoded to one handset.

## What did not work

Recorded in full in [data/RESULTS.md](data/RESULTS.md), because the negative
results are the most transferable part of the work:

- **`set-fixed-performance-mode-enabled`** made jank **worse** (60% -> 76%).
  A widely recommended "optimisation" that actively hurts on `schedutil`.
- **`activity_manager_constants`** (`use_compaction`, `max_cached_processes`)
  is accepted and persisted but **never applied** - a control test proved
  this ROM has the `ActivityManagerConstants` observer disabled.
- **Runtime Resource Overlays** - the mechanism behind system-wide UI
  re-skinning - are blocked. The install is rejected on signature mismatch
  and the enable fails with `idmap2d: failed to parse idmap header`, because
  `framework-res.apk` and `SystemUI.apk` declare **zero `<overlayable>`
  policies**. System theming is unavailable without root on this ROM.
- **`setprop` on `dalvik.vm.*`** is blocked by SELinux.

## Honest limitations

- **Hardware ceiling.** 720x1600 at 60 Hz with a 2019-era GPU. No amount of
  tuning produces a 90/120 Hz experience; the panel cannot show it.
- **No root.** Four vendor packages (`com.vivo.abe`, `com.vivo.globalsearch`,
  `com.vivo.website`, `com.bbk.account`) could not be removed. They are
  `UPDATED_SYSTEM_APP` entries the vendor hardcodes as non-removable. Seven
  separate bypass techniques were tried, including direct binder calls at
  transaction IDs derived from AOSP source for this SDK.
- **Some settings reset on boot.** `app_standby_enabled` is re-applied by
  `perf-lab.sh reapply`.
- **One device, one vendor.** The findings are specific to this ROM. The
  *method* generalises; the package lists do not.

## Method notes

Two measurement mistakes were made and corrected during this work, both
recorded because they are easy to repeat:

1. **Benchmarks run with the screen off are meaningless.** With the display
   asleep the compositor idles and `gfxinfo` reports zero frames, which
   looks like a perfect result. `benchmark.sh` now refuses to run unless
   `mWakefulness=Awake`.
2. **`am start -W` has a ~3,000 ms floor on this ROM** - Settings, the
   launcher and a game all reported the same time. It is a fixed artefact of
   the command, not an application measurement. Real launch cost was measured
   with frame timestamps instead.

## License

MIT - see [LICENSE](LICENSE).
