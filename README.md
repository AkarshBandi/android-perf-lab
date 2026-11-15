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
| **CPU throughput ratio** | 0.6910 | **1.0000** (100% of rated clock) |
| **Apps AOT compiled** | 0 | **17 of 17** |
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

## The CPU was capped too - and it was a symptom

While profiling, the SoC turned out to be running **30.9% below its rated
throughput**:

| Cluster | Stock | Observed | Ratio |
|---|---:|---:|---:|
| Big (cpu0-3) | 1804 MHz | 1305 MHz | 72.3% |
| Little (cpu4-7) | 1612 MHz | 1056 MHz | 65.5% |
| **Aggregate** | **13,670 MHz** | **9,446 MHz** | **69.1%** |

It was **not** thermal throttling - CPU zones read 36-37 C against 115/125 C
trip points, every thermal cooling device reported `cur_state=0`, and
`Thermal Status: 0`. It was not the charger either.

The capped values are exact entries in each cluster's frequency table, two
steps below the top: a fixed vendor operating point, not a dynamic throttle.
And it could not be undone from the shell - `scaling_max_freq` is
root-writable only.

**It was a symptom.** Draining swap lifts the cap automatically, and it is
reproducible:

```
before drain:  cpu0max=1305600  cpu4max=1056000  swap=1330 MB
after  drain:  cpu0max=1804800  cpu4max=1612800  swap=1137 MB

cycle 2: cpu0max=1804800  swap=1063 MB
cycle 3: cpu0max=1804800  swap=1229 MB
```

The cap tracks swap pressure directly. With 1.4 GB of the working set living
in zram, every cold page was a ~100x-latency fault, and the vendor was
holding the SoC down to cut the fault rate.

### The feedback loop

```
   swap fills up
        |
        v
   cold pages cost ~100x a RAM access
        |
        v
   vendor holds the SoC down to cut the fault rate   (R = 0.69)
        |
        v
   CPU is 31% slower, so pages fault more often
        |
        +------------------> back to "swap fills up"
```

The cap is a *symptom amplifier*. Breaking it at either end works, and the
repo does both: reclaim swap, and keep apps out of the standby kill tier so
they stop churning.

## Every lever available, and what each one actually does

Ordered by measured impact on this device.

### 1. Keep apps out of the LMKD kill tier - `app_standby_enabled=0`

Android demotes unused apps into a bucket the low-memory killer harvests
first. Measured on a backgrounded app: `oom_score_adj` of **900+** (inside
the kill zone). With this set it holds **0** (protected tier).

*Effect:* apps survive in the background instead of being killed and
reloaded. **19,385 kills -> 0.**
*Cost:* none. Reverted at every boot by the vendor ROM, so it needs
re-applying.

### 2. Drain swap residency - `swap-drain.sh`

The single biggest lever, and the one that fixes the CPU cap too.

The kernel migrates cold pages out to zram and only brings them back via
compaction. On this ROM compaction is unavailable (the
`ActivityManagerConstants` observer is disabled - confirmed with a control
test), so pages migrate out and **never return**. Swap sits at ~85% full
permanently while RAM looks half-empty.

A page fault served from zram costs **~100x a RAM access**, and the UI
thread blocks on it. That is the `io_wait` term:

```
swap used    1278 MB (83.3%)  ->  915 MB (59.6%)
MemAvailable  720 MB          ->  1006 MB
SystemUI p90 frame time  21ms ->  16ms   (60Hz budget = 16.67ms)
```

*Cost:* the affected apps relaunch cold next time. The tool refuses to stop
the IME, launcher, Play Store or GMS, since interrupting those costs more
than it saves.

### 3. Remove the vendor's second kill layer - 15 packages disabled

vivo runs background-process supervisors *on top of* Android's LMKD.
`com.vivo.sps` alone held 120 MB across two processes and ran at 54% CPU.
Each was verified non-critical (no IME, launcher, dialer or biometric
component).

*Effect:* one kill system instead of two.

### 4. AOT compile your apps - `aot-compile.sh`

ART interprets code and JIT-compiles hot paths **while you are using the
app**, so the first seconds of every launch go to compiling rather than
drawing. AOT compilation moves that to a one-off step.

*Effect:* faster cold starts, smoother execution, less CPU burned compiling
during interaction.
*Cost:* disk space and a one-off compile. A full-device compile is ~325
packages and takes several minutes; `installd` may restart and interrupt
it, so it is resumable.

**Note on `-m speed` vs `-m speed-profile`:** some large apps with many
split APKs fail under `-m speed` ("could not be compiled") but succeed under
`-m speed-profile`. Instagram (147 MB, 9 splits) is one. The script tries
both.

### 5. Halve animation duration - animation scales `0.5`

Animations are the most visible thing between a tap and a result.

*Effect:* animations finish in half the wall-clock time. Perceived
responsiveness improves; measured frame_time is unchanged. Zero regression
risk.
*Cost:* slightly less polished looking. `0.0` is instant if you want
maximum responsiveness over aesthetics.

### 6. Disable the app freezer - `cached_apps_freezer=disabled`

Freezing cached apps is a RAM saver, but thawing one stalls the launcher.

*Effect:* no freeze/thaw stall on resume.

### 7. Doze whitelist - `cmd deviceidle whitelist +<pkg>`

Keeps foreground apps out of deep idle.

*Effect:* they are not frozen or killed during long idle periods.

### 8. Uninstall unused packages - 19 removed

*Effect:* 19 fewer processes and 4 GB less storage.

### 9. Cap background execution per app - `appops`

Android lets any app start services, wake receivers and run jobs in the
background. On a 2.7 GB device that churn is what keeps swap full and the
CPU capped. Two levels of cap are used:

| Level | Ops | Effect |
|---|---|---|
| **Full** | `RUN_IN_BACKGROUND` + `RUN_ANY_IN_BACKGROUND` = `ignore` | The app cannot start background services at all. Used for apps with no time-sensitive push: browsers, video, Maps, Play Store, games, the Google app. |
| **Soft** | `RUN_IN_BACKGROUND` = `ignore` only | Blocks background services but leaves the broader flag alone, so push delivery is not degraded. Used for apps where order, payment or message alerts matter. |

**FCM push still arrives for fully-capped apps** - it is delivered by
`com.google.android.gms`, not by the app's own background service. That is
why `com.google.android.gms` itself is deliberately left uncapped: it *is*
the push transport, and restricting it would break every notification.

Applied to 18 apps. `com.android.vending` and the launcher are left alone
so Play Store's background install work and the home screen keep running.

### Levers that were tried and rejected

| Attempt | Why it was rejected |
|---|---|
| `cmd game downscale` | Reduces GPU work, but upscaling to the panel makes text visibly larger and softer. On a 720p display users read that as "the font size changed". Only worth it when GPU-bound - which is not the case here (GPU p50 = 5 ms vs 16.67 ms budget). |
| `cmd power set-fixed-performance-mode-enabled` | Measured **worse**: jank 60% -> 76%. Forcing max frequency keeps the SoC hot and triggers the thermal governors. |
| `settings put global activity_manager_constants` | Accepted and persisted, but never applied - the ROM's observer is disabled. Proven with a control test on a key known to work. |
| Runtime Resource Overlays | Install rejected on signature mismatch; enable rejected with `idmap2d: failed to parse idmap header`. Root cause: zero `<overlayable>` policies declared in `framework-res.apk` and `SystemUI.apk`. |
| `setprop dalvik.vm.heapgrowthlimit` | SELinux blocks non-ro properties from the shell UID. |
| Writing `scaling_max_freq` | Root-only node. **But this turned out to be unnecessary** - see the feedback loop above. |

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
perf-model.sh          analytic performance model - predicts outcomes
swap-drain.sh          reclaim swap residency back into RAM
aot-compile.sh         ahead-of-time compile apps for faster starts
benchmark.sh           reproducible frame-timing benchmark
ab-test.sh             A/B the same app tuned vs. untuned
collect.sh             point-in-time metric snapshot
profiles/              per-device-family configuration
data/RESULTS.md        every measured number, plus what did not work
docs/HARDWARE.md       the test device
docs/RESEARCH-NOTES.md the reasoning, including the failed paths
```

### The analytic model

`perf-model.sh` reads the device's real hardware and runtime state and
computes where the frame budget is going, so a change's expected outcome can
be predicted *before* applying it:

```
frame_time = cpu_work + gpu_work + io_wait + sched_latency

  cpu_work     = cycles_needed / clock_available          (Amdahl)
  gpu_work     = pixels * shader_cost / gpu_throughput
  io_wait      = pages_to_fetch / io_bandwidth           (Little's Law)
  sched_latency = (runnable_procs / cores) * timeslice

  throughput ratio vs stock:
    R = (4*f_big + 4*f_little)_current / (4*f_big + 4*f_little)_stock
```

On the test device this reports **R = 0.6910 - 30.9% of CPU throughput lost**
to a vendor frequency cap, and ranks the reachable levers by gain/risk.

### The swap drain

`swap-drain.sh` addresses the `io_wait` term directly. On this ROM the
kernel migrates cold pages out to zram and never brings them back, because
the compaction daemon that does the reverse is unavailable. Swap therefore
stays ~85% full even while RAM looks half-empty, and every cold page the
renderer touches costs roughly 100x a RAM access.

Stopping the swap-heavy processes releases their zram pages immediately:

```
swap used    1278 MB (83.3%)  ->  915 MB (59.6%)
MemAvailable  720 MB          ->  1006 MB
SystemUI p90 frame time  21ms ->  16ms   (60Hz budget = 16.67ms)
```

Draining swap is also what lifts the CPU frequency cap. Both effects share
one cause: memory pressure.

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
- **The CPU cap returns when swap refills.** This is the central finding -
  the cap is a *symptom* of memory pressure, not an independent limit. It
  means `swap-drain.sh` must run periodically, otherwise the 30.9%
  throughput loss comes back. A boot-time hook or a scheduled job closes
  this; it is the one piece of the system that is not yet automated.
- **AOT output is invalidated by an app update.** Instagram updates often,
  and it falls back to `verify` and re-JITs itself. `aot-compile.sh` is
  idempotent, so re-running it is the fix.
- **One device, one vendor.** The findings are specific to this ROM. The
  *method* generalises; the package lists do not.

## Method notes

Three measurement mistakes were made and corrected during this work, all
recorded because they are easy to repeat:

1. **Benchmarks run with the screen off are meaningless.** With the display
   asleep the compositor idles and `gfxinfo` reports zero frames, which
   looks like a perfect result. `benchmark.sh` now refuses to run unless
   `mWakefulness=Awake`.
2. **`am start -W` has a ~3,000 ms floor on this ROM** - Settings, the
   launcher and a game all reported the same time. It is a fixed artefact of
   the command, not an application measurement. Real launch cost was measured
   with frame timestamps instead.
3. **`scaling_max_freq` may be unreadable, which is not the same as
   capped.** The node is mode 0660 owned by `system`, so the shell UID
   cannot read it on some kernels. The model was reporting a false
   "1804 -> 0 MHz" cap until it was changed to fall back to the observed
   clock. A core that is not capped demonstrably reaches `cpuinfo_max_freq`
   under load.

## License

MIT - see [LICENSE](LICENSE).
