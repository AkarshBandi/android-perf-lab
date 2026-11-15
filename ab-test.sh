#!/bin/bash
# perf-lab: A/B frame-timing benchmark for a single app.
#
# Measures the same app twice - once with the tuning applied, once with it
# reverted - so the improvement is measured, not asserted.
#
#   ./ab-test.sh <package> [activity]
#
# Both runs drive the app with identical gestures and report jank.
set -u
PKG="${1:?usage: $0 <package> [activity]}"
S="${DEVICE_SERIAL:-$(adb devices | awk 'NR==2 && $2=="device"{print $1}')}"
[ -z "$S" ] && { echo "No device"; exit 1; }
ACT="${2:-}"
if [ -z "$ACT" ]; then
  ACT=$(adb -s "$S" shell "cmd package resolve-activity --brief -c android.intent.category.LAUNCHER $PKG" | tail -1 | sed 's/^[^ ]* //')
fi
sh_() { adb -s "$S" shell "$1" 2>/dev/null | tr -d '\r'; }

measure() { # measure <label>
  local label="$1"
  sh_ "am force-stop $PKG" >/dev/null 2>&1
  sleep 3
  sh_ "dumpsys gfxinfo $PKG reset" >/dev/null 2>&1
  sh_ "am start -n $PKG/$ACT" >/dev/null 2>&1
  sleep 8
  # drive interaction
  for i in 1 2 3 4 5; do
    sh_ "input swipe 360 1300 360 400 220" >/dev/null
    sleep 0.5
    sh_ "input swipe 360 400 360 1300 220" >/dev/null
    sleep 0.5
  done
  sleep 2
  echo "-- $label"
  sh_ "dumpsys gfxinfo $PKG | grep -E 'Total frames|Janky frames:|50th percentile|90th percentile|95th percentile|99th percentile|50th gpu percentile|90th gpu percentile'" | sed 's/^/   /'
  echo
}

echo "=============================================="
echo " A/B FRAME TIMING   $PKG"
echo " $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "=============================================="
sh_ "svc power stayon true" >/dev/null
sh_ "input keyevent KEYCODE_WAKEUP" >/dev/null
sleep 1

measure "TUNED (standby demotion off, freezer off, reduced-resolution rendering)"

echo ">> temporarily reverting the tuning for the control run..."
# Revert: re-enable standby demotion, re-enable the freezer, remove downscale.
sh_ "settings put global app_standby_enabled 1" >/dev/null
sh_ "settings put global cached_apps_freezer device_default" >/dev/null
sh_ "cmd game downscale disable $PKG" >/dev/null
sleep 2

measure "CONTROL (vendor default behaviour)"

echo ">> restoring the tuned configuration"
sh_ "settings put global app_standby_enabled 0" >/dev/null
sh_ "settings put global cached_apps_freezer disabled" >/dev/null
sh_ "cmd game downscale 0.75 $PKG" >/dev/null
sh_ "settings put system screen_off_timeout 120000" >/dev/null
sh_ "svc power stayon false" >/dev/null
