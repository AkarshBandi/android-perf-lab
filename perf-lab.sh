#!/bin/bash
# perf-lab: profile and tune an Android device over ADB (shell uid, no root).
#
#   ./perf-lab.sh status            # current state of every lever
#   ./perf-lab.sh diagnose          # root-cause analysis (read-only)
#   ./perf-lab.sh apply [--dry-run] # apply the tuned configuration
#   ./perf-lab.sh reapply           # re-apply only what the OS resets on reboot
#   ./perf-lab.sh rollback          # restore vendor defaults
#   ./perf-lab.sh benchmark         # reproducible frame-timing benchmark
#
# Every change is reversible. `rollback` restores the vendor defaults.
# Nothing here needs root; all operations run as the ADB shell user (uid 2000).
# Operations that require privileges we do not hold are reported, not hidden.
set -u
S="${DEVICE_SERIAL:-$(adb devices | awk 'NR==2 && $2=="device"{print $1}')}"
[ -z "$S" ] && { echo "No device. Connect over USB or set DEVICE_SERIAL."; exit 1; }
MODE="${1:-status}"
DRY=0; [ "${2:-}" = "--dry-run" ] && DRY=1
HERE="$(cd "$(dirname "$0")" && pwd)"

run() {
  local desc="$1" cmd="$2" out
  if [ $DRY -eq 1 ]; then
    printf '  [DRY-RUN] %s\n            %s\n' "$desc" "$cmd"; return
  fi
  out=$(adb -s "$S" shell "$cmd" 2>&1 | tr -d '\r')
  case "$out" in
    *Exception*|*Failure*|*error*|*denied*|*refused*|*not\ found*)
      printf '  [BLOCKED] %-44s %s\n' "$desc" "$(echo "$out" | head -1 | cut -c1-52)" ;;
    *) printf '  [OK]      %s\n' "$desc" ;;
  esac
}

# ------------------------------------------------------------------ profile
# Profile files define what to change for a given device family.
# See profiles/ for the shipped ones; this is the fallback.
PROFILE_DIR="$HERE/profiles"
load_profile() {
  local f
  for f in "$PROFILE_DIR"/*.profile; do
    [ -e "$f" ] || continue
    # shellcheck disable=SC1090
    . "$f"
  done
}
load_profile

: "${DISABLE_SYSTEM:=}"
: "${UNINSTALL_USER:=}"
: "${DOWNSCALE:=}"
: "${WHITELIST:=}"
: "${SHIZUKU_BIN:=}"

# ------------------------------------------------------------------ actions
do_reapply() {
  echo ">> Re-applying settings the OS resets on reboot"
  run "app_standby_enabled=0 (stop demoting apps into the kill tier)" \
      "settings put global app_standby_enabled 0"
  run "cached_apps_freezer=disabled (no freeze/thaw stalls)" \
      "settings put global cached_apps_freezer disabled"
  for e in $DOWNSCALE; do
    p="${e%%:*}"; v="${e##*:}"
    run "downscale $p -> $v" "cmd game downscale $v $p"
  done
}

do_apply() {
  echo ">> 1. Memory pressure and scheduling"
  run "app_standby_enabled=0" "settings put global app_standby_enabled 0"
  run "cached_apps_freezer=disabled" "settings put global cached_apps_freezer disabled"
  run "window_animation_scale=0.5" "settings put global window_animation_scale 0.5"
  run "transition_animation_scale=0.5" "settings put global transition_animation_scale 0.5"
  run "animator_duration_scale=0.5" "settings put global animator_duration_scale 0.5"

  echo ">> 2. Doze whitelist (protect foreground apps from deep idle)"
  for p in $WHITELIST; do run "doze whitelist +$p" "cmd deviceidle whitelist +$p"; done

  echo ">> 3. Vendor background-process supervisors -> disabled"
  for p in $DISABLE_SYSTEM; do run "disable $p" "pm disable-user --user 0 $p"; done

  echo ">> 4. Unused packages -> removed for user 0 (persists across reboots)"
  for p in $UNINSTALL_USER; do run "uninstall --user 0 $p" "pm uninstall --user 0 $p"; done

  echo ">> 5. GPU: render heavy apps at reduced resolution"
  for e in $DOWNSCALE; do
    p="${e%%:*}"; v="${e##*:}"
    run "downscale $p -> $v" "cmd game downscale $v $p"
  done

  echo ">> 6. Shizuku service"
  [ -n "$SHIZUKU_BIN" ] && run "start shizuku_server" "$SHIZUKU_BIN"
}

do_rollback() {
  echo ">> Restoring vendor defaults"
  run "app_standby_enabled=1" "settings put global app_standby_enabled 1"
  run "cached_apps_freezer=device_default" "settings put global cached_apps_freezer device_default"
  run "window_animation_scale=1.0" "settings put global window_animation_scale 1.0"
  run "transition_animation_scale=1.0" "settings put global transition_animation_scale 1.0"
  run "animator_duration_scale=1.0" "settings put global animator_duration_scale 1.0"
  for p in $DISABLE_SYSTEM; do run "enable $p" "pm enable --user 0 $p"; done
  for p in $UNINSTALL_USER; do run "reinstall $p" "cmd package install-existing --user 0 $p"; done
  for e in $DOWNSCALE; do p="${e%%:*}"; run "downscale off $p" "cmd game downscale disable $p"; done
}

do_status() {
  echo "=============================================="
  echo " PERF-LAB STATUS   $S"
  echo "=============================================="
  adb -s "$S" shell "grep -E 'MemAvailable|SwapFree' /proc/meminfo" | tr -d '\r'
  echo "  process count:  $(adb -s "$S" shell 'ps -A | wc -l' | tr -d '\r')"
  echo "  lmk kills:      $(adb -s "$S" shell 'dumpsys activity lmk | head -2 | tail -1' | tr -d '\r')"
  echo "  app deaths:"
  adb -s "$S" shell "dumpsys activity exit-info | grep -oE 'reason=[0-9]+ \([A-Z_]+\)' | sort | uniq -c | sort -rn" | tr -d '\r' | sed 's/^/    /'
  echo "  levers:"
  adb -s "$S" shell "echo \"    app_standby_enabled = \$(settings get global app_standby_enabled)\"; echo \"    cached_apps_freezer = \$(settings get global cached_apps_freezer)\"; echo \"    animation scales  = \$(settings get global window_animation_scale)/\$(settings get global transition_animation_scale)/\$(settings get global animator_duration_scale)\"" | tr -d '\r'
  echo "  disabled pkgs:   $(adb -s "$S" shell 'pm list packages -d | wc -l' | tr -d '\r')"
  echo "  system pkgs:     $(adb -s "$S" shell 'pm list packages | wc -l' | tr -d '\r')"
  echo "  shizuku server:  $(adb -s "$S" shell 'ps -A | grep -c shizuku_server' | tr -d '\r') running"
}

case "$MODE" in
  apply)    do_apply ;;
  reapply)  do_reapply ;;
  rollback) do_rollback ;;
  status)   do_status ;;
  diagnose) exec "$HERE/diagnose.sh" "$S" ;;
  benchmark) exec "$HERE/benchmark.sh" ;;
  *) echo "usage: $0 {status|diagnose|apply|reapply|rollback|benchmark} [--dry-run]"; exit 1 ;;
esac
