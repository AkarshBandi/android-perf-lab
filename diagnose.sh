#!/bin/bash
# perf-lab: root-cause a laggy Android device from ADB. Read-only.
S="${1:-$(adb devices | awk 'NR==2{print $1}')}"
[ -z "$S" ] && { echo "no device"; exit 1; }
sh_() { adb -s "$S" shell "$1" 2>/dev/null | tr -d '\r'; }

echo "=============================================="
echo " PERF-LAB DIAGNOSTIC REPORT"
echo " $(sh_ 'getprop ro.product.model') | Android $(sh_ 'getprop ro.build.version.release') | $(sh_ 'getprop ro.build.display.id')"
echo " $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "=============================================="

echo; echo "[1] MEMORY PRESSURE"
sh_ "grep -E 'MemTotal|MemAvailable|SwapTotal|SwapFree' /proc/meminfo"

echo; echo "[2] ROOT CAUSE: app deaths by reason (cumulative since boot)"
sh_ "dumpsys activity exit-info | grep -oE 'reason=[0-9]+ \([A-Z_]+\)' | sort | uniq -c | sort -rn"
echo "  -> reason=3 (LOW_MEMORY) = kernel killed the app for memory pressure"

echo; echo "[3] LOW-MEMORY KILL COUNT (LiveContainerManager)"
sh_ "dumpsys activity lmk | head -2 | tail -1"

echo; echo "[4] PROCESS COUNT"
sh_ "echo \"total: \$(ps -A | wc -l)\""
echo "  top 8 by RSS:"
sh_ "ps -A -o RSS,NAME | sort -rn | head -9"

echo; echo "[5] SWAP / ZRAM THRASH (top CPU consumers)"
sh_ "cat /proc/pressure/io 2>/dev/null || echo '  (PSI not readable via adb shell on this ROM)'"
sh_ "top -b -n 1 2>/dev/null | grep -iE 'kswapd|vswap|kshrinkd' | head -4"
echo "  -> kswapd/vswap_fn at high CPU == pages thrashing between RAM and zram"

echo; echo "[6] CPU GOVERNOR / CLUSTERS"
sh_ "for c in 0 1 2 3 4 5 6 7; do printf 'cpu%s: gov=%s cur=%s max=%s\n' \$c \"\$(cat /sys/devices/system/cpu/cpu\$c/cpufreq/scaling_governor 2>/dev/null)\" \"\$(cat /sys/devices/system/cpu/cpu\$c/cpufreq/scaling_cur_freq 2>/dev/null)\" \"\$(cat /sys/devices/system/cpu/cpu\$c/cpufreq/scaling_max_freq 2>/dev/null)\"; done"

echo; echo "[7] FRAME TIMING (is it GPU or CPU bound?)"
for pkg in com.android.systemui com.bbk.launcher2; do
  echo "  [$pkg]"
  sh_ "dumpsys gfxinfo $pkg | grep -E 'Total frames|Janky frames:|50th percentile|90th percentile|95th percentile|50th gpu percentile|90th gpu percentile'" | sed 's/^/    /'
done
echo "  -> LOW gpu percentile + HIGH frame percentiles = CPU/IO bound, NOT graphics bound"

echo; echo "[8] VENDOR BACKGROUND KILLERS (the apps that kill other apps)"
echo "  vivo packages holding REAL_GET_TASKS / FORCE_STOP_PACKAGES / DELETE_PACKAGES:"
sh_ "for p in \$(pm list packages -s | cut -d: -f2); do if dumpsys package \$p 2>/dev/null | grep -q 'FORCE_STOP_PACKAGES'; then echo \"    \$p\"; fi; done" | head -8

echo; echo "[9] STANDBY / APP-OSCILLATION STATE"
sh_ "echo \"  app_standby_enabled = \$(settings get global app_standby_enabled)\""
sh_ "echo \"  cached_apps_freezer = \$(settings get global cached_apps_freezer)\""
sh_ "echo '  apps in RARE/rarely bucket (first to be killed):'"
sh_ "for p in \$(pm list packages -3 | cut -d: -f2); do b=\$(am get-standby-bucket \$p 2>/dev/null); if [ \"\$b\" = 40 ] || [ \"\$b\" = 50 ]; then echo \"    (\$b) \$p\"; fi; done"

echo; echo "[10] WAKELOCK HOLDERS (background work keeping CPU awake)"
sh_ "dumpsys power | grep -A12 'PARTIAL_WAKE_LOCK' | grep -oE \"pkg=[a-zA-Z0-9_.]+\" | sort | uniq -c | sort -rn | head -6"

echo; echo "=============================================="
echo " Run 'perf-lab.sh' to apply the tuned configuration."
echo "=============================================="
