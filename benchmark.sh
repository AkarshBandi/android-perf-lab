#!/bin/bash
# perf-lab: reproducible frame-timing benchmark over ADB.
#
# Measures jank on the surfaces that exist on every device (system UI + the
# active launcher), so results are comparable across devices without naming
# any user-installed app.
#
#   ./benchmark.sh            # run the standard benchmark
#   ./benchmark.sh --quick    # shorter run
set -u
S="${DEVICE_SERIAL:-$(adb devices | awk 'NR==2 && $2=="device"{print $1}')}"
[ -z "$S" ] && { echo "No device"; exit 1; }
DUR=${1:-12}
sh_() { adb -s "$S" shell "$1" 2>/dev/null | tr -d '\r'; }

# The screen MUST be on and unlocked or every frame metric is meaningless:
# with the display off the compositor idles and gfxinfo reports zero frames.
echo "== ensuring display is awake for valid frame metrics =="
sh_ "svc power stayon true" >/dev/null
sh_ "input keyevent KEYCODE_WAKEUP" >/dev/null
sleep 1
WAKE=$(sh_ "dumpsys power | grep -oE 'mWakefulness=[A-Za-z]+'")
echo "   $WAKE"
case "$WAKE" in
  *Awake*) : ;;
  *) echo "   WARNING: display not awake - unlock the device, results will be invalid."; exit 1 ;;
esac

# Identify the active launcher generically (no hardcoded package names).
# resolve-activity returns "pkg/activity" - the package is the part before "/".
LAUNCHER=$(sh_ "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME" | tail -1 | sed 's|/.*||')
[ -z "$LAUNCHER" ] && LAUNCHER="com.android.launcher3"
SYSTEMUI="com.android.systemui"

bench() { # bench <package> <label> [focus_cmd]
  local pkg="$1" label="$2" focus="${3:-}"
  # Bring the target surface to the foreground, otherwise the compositor
  # never asks it to draw and gfxinfo reports zero frames.
  [ -n "$focus" ] && { sh_ "$focus" >/dev/null 2>&1; sleep 3; }
  sh_ "dumpsys gfxinfo $pkg reset" >/dev/null 2>&1
  # generate frames: swipe the screen in both directions
  local n=6
  [ "${DUR:-12}" = "--quick" ] && n=3
  for i in $(seq 1 $n); do
    sh_ "input swipe 360 1300 360 400 220" >/dev/null
    sleep 0.4
    sh_ "input swipe 360 400 360 1300 220" >/dev/null
    sleep 0.4
  done
  sleep 2
  echo "-- $label ($pkg)"
  sh_ "dumpsys gfxinfo $pkg | grep -E 'Total frames|Janky frames:|50th percentile|90th percentile|95th percentile|99th percentile|50th gpu percentile|90th gpu percentile'" | sed 's/^/   /'
  echo
}

echo "=============================================="
echo " PERF-LAB FRAME BENCHMARK"
echo " device : $(sh_ 'getprop ro.product.model') / Android $(sh_ 'getprop ro.build.version.release')"
echo " $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "=============================================="
echo
bench "$SYSTEMUI" "System UI (status bar, notifications, quick settings)"
bench "$LAUNCHER" "Launcher (home screen scroll)" "am start -a android.intent.action.MAIN -c android.intent.category.HOME"

echo "-- system-wide resource snapshot"
sh_ "grep -E 'MemAvailable|SwapFree' /proc/meminfo" | sed 's/^/   /'
sh_ "echo \"   processes: \$(ps -A | wc -l)\"" | sed 's/^/   /'
sh_ "dumpsys activity lmk | head -2 | tail -1" | sed 's/^/   /'
echo
sh_ "settings put system screen_off_timeout 120000" >/dev/null
sh_ "svc power stayon false" >/dev/null
