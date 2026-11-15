#!/bin/bash
# perf-lab: ahead-of-time (AOT) compile installed apps.
#
# WHY
# ---
# ART normally runs app code through an interpreter and JIT-compiles hot
# paths at runtime. On a slow CPU that JIT work happens *while the user is
# interacting with the app*, so the first seconds of every launch are spent
# compiling instead of drawing. That is why apps feel slow to start.
#
# AOT compilation moves that work to a one-off compile step. The result is
# native code on disk, so the app starts already compiled.
#
#   -m verify    : check the dex, no codegen      (default, cheap)
#   -m speed     : full AOT, no profile          (best startup, biggest size)
#   -m speed-profile : AOT + hotness profile    (best steady-state perf)
#
# WHAT IT BUYS
#   - Faster cold starts (no JIT on the critical path)
#   - Smoother execution (interpreted -> native)
#   - Less CPU burned compiling while you interact
#
# WHAT IT COSTS
#   - Disk space (AOT .oat files are large)
#   - One-off CPU time (the compile itself)
#   - Time to complete: a full-device compile is ~325 packages and takes
#     several minutes; installd may restart and interrupt it.
#
# USAGE
#   ./aot-compile.sh              # compile the apps you actually use
#   ./aot-compile.sh --all        # every installed package
#   ./aot-compile.sh --status     # show current compile state
set -u
S="${DEVICE_SERIAL:-$(adb devices | awk 'NR==2 && $2=="device"{print $1}')}"
[ -z "$S" ] && { echo "No device"; exit 1; }
sh_() { adb -s "$S" shell "$1" 2>/dev/null | tr -d '\r'; }

status() {
  echo "  compile state (status=speed* means AOT compiled):"
  sh_ "dumpsys package dexopt" | awk '
    /^  \[/ { pkg=$0; gsub(/[][]/,"",pkg); sub(/^ /,"",pkg) }
    /status=speed/ { print "    " pkg "  -> " $0 }' | head -40
  echo
  echo -n "  total AOT-compiled: "
  sh_ "dumpsys package dexopt" | grep -c 'status=speed'
}

case "${1:-}" in
  --status)
    echo "=== AOT COMPILE STATUS ==="
    status
    ;;
  --all)
    echo "=== AOT compiling ALL packages (takes several minutes) ==="
    sh_ "cmd package compile -m speed-profile -f -a"
    echo "=== done ==="
    status
    ;;
  "")
    # Only the apps the user actually runs. Compiling all 325 packages for
    # hours of CPU to speed up an app you never open is a bad trade.
    echo "=== AOT compiling the apps you use ==="
    for p in $(sh_ "pm list packages -3" | cut -d: -f2); do
      printf '  %-36s ' "$p"
      # Some large multi-split apps fail under -m speed but succeed under
      # -m speed-profile, so fall back to that.
      out=$(sh_ "cmd package compile -m speed -f $p" | tail -1)
      case "$out" in
        *Success*) ;;
        *) out=$(sh_ "cmd package compile -m speed-profile -f $p" | tail -1) ;;
      esac
      echo "$out" | cut -c1-40
    done
    echo
    status
    ;;
  *)
    echo "usage: $0 [--all|--status]"
    ;;
esac
