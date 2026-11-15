# Research notes

Working notes from the investigation. Kept because the reasoning is the
transferable part - the package lists are not.

---

## 1. Ruling out the obvious causes

**"Swap is full, so swap is the problem."** - Partly true, but the first
hypothesis tested was wrong about *causality*. Swap being full is a symptom
of memory pressure, not the mechanism that kills apps. The mechanism is the
LMKD, and the *reason* it killed so much was a combination of a mis-tiered
standby bucket and a second vendor kill layer.

**"The GPU is slow."** - Disproved directly. GPU frame time was 5 ms in both
the broken and the fixed state. On a 60 Hz panel the budget is 16.67 ms, so
the graphics pipeline was never the bottleneck. Every frame that stalled was
stalling on the CPU side.

**"The CPU is overloaded."** - Partly. `system_server` was at 730% CPU, but
that was a *symptom* of package-manager churn: apps were killed, restarted,
and killed again. The CPU was busy because the kill loop was spinning, not
because real work was happening.

---

## 2. The two kill layers

Android's LMKD was visible in the counters. The second layer was not.

`com.vivo.sps` (SuperProcessSystem) alone was holding 120 MB across two
processes and running at 54% CPU. `com.vivo.appfilter` and
`com.vivo.safecenter` implement vendor-specific background policy on top of
Android's own.

**How the second layer was found:** `dumpsys activity exit-info` reports
`reason=3 (LOW_MEMORY)` for LMKD kills, but it does not attribute the kill to
*which* agent requested it. Comparing the LMKD counter (19,385) against the
`exit-info` LOW_MEMORY count (1,971) showed the two did not reconcile -
`exit-info` only keeps a bounded history, so the gap alone was not proof.
Confirming the vendor layer required enumerating which packages hold
`FORCE_STOP_PACKAGES` / `REAL_GET_TASKS` / `DELETE_PACKAGES`:

```bash
for p in $(pm list packages -s | cut -d: -f2); do
  dumpsys package $p | grep -q 'FORCE_STOP_PACKAGES' && echo "$p"
done
```

---

## 3. Proving the standby tier was the trigger

The decisive measurement was `/proc/<pid>/oom_score_adj` for a backgrounded
app:

```
before: 900+     (inside the LMKD harvest zone)
after:  0        (protected tier)
```

`app_standby_enabled=0` changes the demotion rule. This is the single most
effective lever in the whole project and it costs nothing.

Note: it is reset by the vendor ROM at boot, so it must be re-applied.

---

## 4. Runtime Resource Overlays - why system theming is blocked

The goal was a system-wide UI re-skin ("Liquid Glass" style). RRO is the
mechanism AOSP provides for this, so the question was whether this ROM
permits it.

**Investigation:**
1. Built a real overlay APK with `aapt2` (compile -> link -> zipalign ->
   `apksigner`), signed it with a debug keystore, installed it.
2. Targeted `android` (framework-res). Install rejected:
   > *Overlay com.test.rro.probe and target android signed with different
   > certificates, and the overlay lacks `<overlay android:targetName>`*
3. Retargeted SystemUI with a `targetName`. Install succeeded. Enable failed:
   > `SecurityException: commit failed`
   with `idmap2d: failed to parse idmap header` in logcat.
4. Root cause: searched `framework-res.apk` and `SystemUI.apk` for
   `<overlayable>` policy declarations, in both the manifest and
   `resources.arsc`. **Zero found.**

AOSP requires the *target* package to declare an `<overlayable>` policy
listing which resources a third-party overlay may replace. With no policy
declared, no user-installed overlay can ever be enabled against it.

**Conclusion:** system-wide theming is unavailable without root on this ROM.
Not a tooling limitation - a deliberate vendor gate. This is why the project
ships a tuning toolkit rather than a theme engine.

---

## 5. The `activity_manager_constants` dead end

`ActivityManagerConstants` is the AOSP mechanism for tuning
`max_cached_processes`, `use_compaction` and the LMKD thresholds. The keys
were verified to exist in the device's own `services.jar` (`use_compaction`,
`max_cached_processes` are real `KEY_*` constants), and
`settings put global activity_manager_constants` was accepted and persisted
across a reboot.

It still did nothing. `dumpsys activity settings` kept reporting
`use_compaction=false, max_cached_processes=32`.

**Control test:** wrote `use_oom_re_ranking=true` (also a real key, also
valid in this ROM) and re-read. Still `false`. A control that is *expected to
change* and does not proves the observer is simply not running - the write
path is broken, not the key name. This ROM has the `ActivityManagerConstants`
observer disabled.

**Consequence:** `use_compaction=true` cannot be enabled, so zram can never
drain back into RAM on its own. The practical substitute is reducing the
number of pages that need swapping at all - which is what the debloat does.

---

## 6. `set-fixed-performance-mode-enabled` - a harmful popular tip

Widely recommended as a performance fix. Measured on this device:

| | janky frames |
|---|---:|
| Default | 60.53% |
| Fixed performance mode ON | **75.82%** |

It forces the CPU to a fixed high-frequency state, which keeps the SoC hot and
triggers thermal governors - on a device already at its thermal envelope this
backs the clock down harder. Reverted immediately. Worth knowing before
anyone else tries it.

---

## 7. `pm uninstall` persistence

| Command | Survives reboot? |
|---|---|
| `pm uninstall <pkg>` | **No** - vendor package manager reverts it |
| `pm uninstall --user 0 <pkg>` | **Yes** - writes a per-user flag |

Verified by rebooting and re-reading `installed=false` from
`dumpsys package`.

**Why it matters:** plain `pm uninstall` on a system package appears to
succeed, and you believe it worked, and then the app is back after a reboot.
Anyone debloating a device has hit this.

**The hard cases:** `UPDATED_SYSTEM_APP` packages (a `/system` app with an
update installed in `/data/app`) that the vendor additionally hardcodes as
non-removable. Seven bypasses were tried on this device:

```
pm uninstall --user 0          -> DELETE_FAILED_USER_RESTRICTED
pm disable-user                -> SecurityException: no root permission
pm hide                        -> needs MANAGE_USERS (system only)
pm uninstall -k --user 0       -> DELETE_FAILED_USER_RESTRICTED
cmd package uninstall-system-updates -> refused
service call package <txn>     -> no effect (see below)
disabling com.vivo.permissionmanager -> no effect
```

For the `service call` attempt, transaction IDs were derived from the AOSP
`IPackageManager.aidl` for SDK 31 rather than guessed: `deletePackageVersioned`
is method 49, `setApplicationEnabledSetting` is 81, `setBlockUninstallForUser`
is 136. Calling the correct IDs produced no effect, because the block is
enforced above the AIDL layer - `com/vivo/services/security/client/VivoPermissionManager`
exists in the device's `services.jar` for exactly this purpose.

**Conclusion:** those packages require root. Reported as a limitation rather
than worked around.

---

## 8. Measurement traps hit along the way

**Benchmarks with the screen off report zero frames.** With the display
asleep the compositor idles, `gfxinfo` returns `Total frames rendered: 0`
and a `4950 ms` sentinel percentile - which looks like a *perfect* result if
you do not check. This invalidated the first round of measurements
completely. `benchmark.sh` now hard-fails unless `mWakefulness=Awake`.

**`am start -W` has a ~3,000 ms floor on this ROM.** Settings, the launcher
and a heavyweight game all reported `WaitTime` within 100 ms of each other
(3023 / 3032 / 3033 ms). A trivial activity cannot take 3 seconds to launch,
so the number is an artefact of the command, not a measurement of the app.
Real launch cost was measured from frame timestamps instead.

**`dumpsys gfxinfo` needs the surface in the foreground.** A reset followed by
an app launch leaves the stats attached to the *old* process, and the new one
reports nothing. The surface has to be brought forward first.

---

## 9. A change that looked fine on paper and had to be reverted

`cmd game downscale` renders an app at 70-75% of native resolution and
upscales the result to the panel. It is a genuine GPU-work reduction, and it
measurably helped frame times.

It was reverted on the user's device anyway. Downscale upscaling makes text
render at a non-native pixel grid, so labels and small UI elements come out
**visibly larger and softer** than native rendering. Users read that as "the
display and font size changed", which is a worse outcome than the frame-rate
gain - the hardware is already a 720p panel, so there is no headroom to trade
away.

**Lesson:** on a low-resolution display, resolution is not a resource worth
trading. It is the one thing the user perceives directly. Kept in the
tooling as an opt-in, but removed from the applied profile.

---

## 10. What would be worth trying next

- **Root.** The `<overlayable>` gate, the four locked packages, and
  `activity_manager_constants` are all root-blocked. With root, system theming
  and real compaction become available.
- **A second device on a different vendor.** The methodology generalises; the
  package lists do not. vivo's ROM differs from stock AOSP in several
  measurable ways.
- **Boot-time persistence.** The re-applied settings still need a host. A
  Termux:Boot task or a `service` trigger would close that gap.
