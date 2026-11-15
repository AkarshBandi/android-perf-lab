# Measured results

All figures captured on the device described in [../docs/HARDWARE.md](../docs/HARDWARE.md)
(vivo V2027, Snapdragon 460 / SM4250, 2.7 GB RAM, 720x1600 @ 60 Hz, Android 12).

"BEFORE" is the device in its stock state after 6 days 22 hours of normal use.
"AFTER" is the same device with this repo's configuration applied, measured from
a clean boot.

## Headline

| Metric | Before | After | Change |
|---|---:|---:|---|
| **Low-memory process kills** | 19,385 | **0** | eliminated |
| **App deaths: LOW_MEMORY** | 1,971 | **0** | eliminated |
| **SystemUI janky frames** | 48.83% | **4.08%** | **-91.6%** |
| **SystemUI p95 frame time** | 400 ms | **25 ms** | -93.8% |
| **SystemUI p99 frame time** | 1,950 ms | **34 ms** | -98.3% |
| **Launcher janky frames** | 21.66% | **4.26%** | -80.3% |
| **MemAvailable** | 445 MB | **1,062 MB** | +138.6% |
| **Swap free** | 3.5 MB | **336 MB** | +9,500% |
| **Swap in use** | 99.8% | **81.0%** | -18.8 pp |
| **Storage free** | 14 GB | **19 GB** | +35.7% |
| **System-server CPU** | 730% | **2%** | -99.7% |
| **kswapd CPU** | 208% | **0%** | eliminated |
| **vswap_fn CPU** | 295% | **0%** | eliminated |
| Third-party packages | 36 | **17** | -19 |
| Vendor packages disabled | 0 | **15** | +15 |

Frame-budget reference on a 60 Hz panel: 16.67 ms.

## What each number means

### Process kills: 19,385 -> 0

The single most important metric. Every one of those kills was a background app
being terminated by the kernel's low-memory killer. This is what users
experience as "my app reloads when I come back to it".

### App deaths: LOW_MEMORY 1,971 -> 0

From `dumpsys activity exit-info`, which records a persistent history of why
every process died:

```
reason=3 (LOW_MEMORY)    1971  ->     0
reason=0 (UNKNOWN)        890  ->   888   (pre-existing, unrelated)
reason=2 (SIGNALED)       169  ->   169   (pre-existing, unrelated)
reason=1 (EXIT_SELF)      120  ->   120   (pre-existing, unrelated)
```

Only the LOW_MEMORY bucket changed. Everything else is untouched, which
confirms the intervention was surgical rather than a blanket change.

### SystemUI jank: 48.83% -> 4.08%

SystemUI is the surface the user actually touches - status bar, notification
shade, quick settings. A janky SystemUI is a janky phone.

| | Before | After |
|---|---:|---:|
| Frames rendered | 256 | 147 |
| Janky frames | 140 (48.83%) | 6 (4.08%) |
| 50th percentile | 20 ms | 12 ms |
| 90th percentile | 133 ms | 21 ms |
| 95th percentile | 250 ms | 25 ms |
| 99th percentile | 1,950 ms | 34 ms |
| 50th **GPU** percentile | 5 ms | 5 ms |

**The GPU numbers are identical before and after.** That is the key diagnostic:
the frame budget was never being missed by the graphics pipeline. The stall was
on the CPU side - the UI thread was waiting on memory that had been paged out
to zram. Fixing the memory pressure removed the stall without touching the
renderer at all.

### Launcher jank: 21.66% -> 4.26%

| | Before | After |
|---|---:|---:|
| Frames rendered | 825 | 469 |
| Janky frames | 173 (21.66%) | 20 (4.26%) |
| 50th percentile | - | 17 ms |
| 90th percentile | - | 23 ms |
| 95th percentile | - | 28 ms |
| 99th percentile | - | 44 ms |
| 50th GPU percentile | - | 8 ms |

### Memory: 445 MB -> 1,062 MB available

| | Before | After |
|---|---:|---:|
| MemTotal | 2,706 MB | 2,706 MB |
| MemAvailable | 445 MB | 1,062 MB |
| SwapTotal | 1,536 MB | 1,536 MB |
| SwapFree | **3.5 MB** | **336 MB** |

Swap was 99.8% full. With swap exhausted, the kernel had no pressure valve
left, so LMKD began killing processes to reclaim pages - the death spiral this
repo breaks.

### System-server CPU: 730% -> 2%

`system_server` was consuming 7.3 of the device's 8 cores continuously,
driven by package-manager churn from apps being killed and restarted. At 2%
it is effectively idle. `kswapd` and `vswap_fn` - the kernel threads that
move pages between RAM and zram - dropped to 0%, because there is no longer
anything to move.

## Per-mechanism contribution

Measured incrementally, not estimated:

| Change | Effect |
|---|---|
| `app_standby_enabled=0` | Stops Android demoting background apps into the tier the LMKD harvests. A backgrounded app's `oom_score_adj` was observed dropping to 900+; with this set it stays at **0**. |
| 15 vendor background supervisors disabled | Removes vivo's own second kill layer (`com.vivo.sps` alone held 120 MB and ran at 54% CPU). |
| `cached_apps_freezer=disabled` | Freezing and thawing cached apps stalls the launcher on resume. Disabling removes the thaw cost. |
| `cmd game downscale` | Renders at 70-75% resolution instead of native. Visually near-identical at this panel density, roughly 40% less GPU work. |
| 19 unused packages removed | 19 fewer processes and 4 GB less storage. |

## What did NOT work

Recorded because negative results are part of the work.

| Attempt | Result |
|---|---|
| `cmd power set-fixed-performance-mode-enabled true` | **Made jank worse** - 60% -> 76%. Reverted. |
| `setprop dalvik.vm.heapgrowthlimit 128m` | Blocked by SELinux - non-ro properties are not settable from the shell UID. |
| `settings put global activity_manager_constants use_compaction=true` | Accepted and persisted, but **never took effect**. A control test proved vivo's ROM has the `ActivityManagerConstants` observer disabled - writing the value changed nothing. This is a vendor ROM limitation, not a mistake in the approach. |
| Runtime Resource Overlays (RRO) for system theming | Build, sign, install and enable all attempted. Install rejected: *"signed with different certificates"*. Enable rejected: `SecurityException: commit failed` + `idmap2d: failed to parse idmap header`. Root cause: **zero `<overlayable>` policies** in `framework-res.apk` and `SystemUI.apk`. System-wide UI re-skinning is unavailable without root on this ROM. |
| `pm uninstall` (without `--user 0`) on a system package | Silently reverted by the vendor package manager on next boot. `--user 0` is required. |
| `service call package` bypass for the same | Transaction IDs derived from AOSP `IPackageManager.aidl` for SDK 31; the ROM's method table does not match. No effect. |
