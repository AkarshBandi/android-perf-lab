#!/bin/bash
# perf-lab: reclaim swap residency back into RAM.
#
# WHY THIS EXISTS
# --------------
# On Android 12 the kernel migrates cold pages out to zram (swap), and only
# migrates them back via "compaction" (madvise(MADV_PAGEOUT) on the page
# cache). On many vendor ROMs compaction is effectively unavailable - on this
# device the ActivityManagerConstants observer that would enable it is
# disabled, so `use_compaction=true` is accepted but never applied.
#
# Result: pages migrate OUT and never come back. Swap stays ~90% full
# forever even while RAM looks half-empty.
#
# WHY THAT IS SLOW
# ---------------
#   A page fault served from zram costs roughly 100x a RAM access, and the
#   UI thread blocks on it. This is the io_wait term in the frame-time model:
#
#     frame_time = cpu_work + gpu_work + io_wait + sched_latency
#
#   With ~1.4 GB of the working set living in swap, every cold page the
#   renderer touches becomes a 100x-latency hit.
#
# WHAT THIS DOES
# --------------
# Finds the processes holding the most swap and stops them. Stopping a
# process releases its swap pages immediately and returns that memory to
# RAM. The apps restart on next launch with clean, RAM-resident pages.
#
#   ./swap-drain.sh            # report only, change nothing
#   ./swap-drain.sh --apply    # reclaim
#
set -u
S="${DEVICE_SERIAL:-$(adb devices | awk 'NR==2 && $2=="device"{print $1}')}"
[ -z "$S" ] && { echo "No device"; exit 1; }
APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1
sh_() { adb -s "$S" shell "$1" 2>/dev/null | tr -d '\r'; }

# Discovery runs on-device: /proc is readable there but the quoting through
# adb shell mangles nested awk.
# Helper runs on-device: /proc is readable there, and running it there also
# gives us the FULL cmdline (ps -o comm truncates to 15 chars, which loses
# the package name and makes force-stop fail).
# The helper is written locally then pushed, so the quoting survives intact.
HELPER_FILE="$(mktemp)"
cat > "$HELPER_FILE" <<'HELPER'
for p in $(ls /proc | grep -E '^[0-9]+$'); do
  s=$(awk '/VmSwap/{print $2}' /proc/$p/status 2>/dev/null)
  [ -n "$s" ] || continue
  [ "$s" -gt 20000 ] || continue
  full=$(cat /proc/$p/cmdline 2>/dev/null | tr '\0' '\n' | head -1)
  [ -z "$full" ] && full=$(cat /proc/$p/comm 2>/dev/null)
  echo "$s $p $full"
done | sort -rn | head -14
HELPER
adb -s "$S" push "$HELPER_FILE" /data/local/tmp/perflab_find_swap.sh >/dev/null 2>&1
rm -f "$HELPER_FILE"
sh_ "sh /data/local/tmp/perflab_find_swap.sh" > /tmp/.perflab_swap 2>/dev/null

swap_used() { sh_ "grep -E 'SwapTotal|SwapFree' /proc/meminfo" | awk '/SwapTotal/{t=$2}/SwapFree/{f=$2}END{print int((t-f)/1024)}'; }
mem_avail() { sh_ "grep MemAvailable /proc/meminfo" | awk '{print int($2/1024)}'; }
swap_pct()  { sh_ "grep -E 'SwapTotal|SwapFree' /proc/meminfo" | awk '/SwapTotal/{t=$2}/SwapFree/{f=$2}END{printf (t>0)? "%.1f":0, (t-f)/t*100}'; }

echo "=============================================="
echo " SWAP DRAIN REPORT"
echo " $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "=============================================="
echo
B4=$(swap_used); A4=$(mem_avail); P4=$(swap_pct)
echo "  BEFORE   swap ${B4} MB used (${P4}%)   MemAvailable ${A4} MB"
echo
echo "  swap holders (>=20 MB):"
awk '{printf "    %7d KB  pid=%-7s %s\n", $1, $2, $3}' /tmp/.perflab_swap
echo
EST=$(awk '{s+=$1} END{print int(s/1024)}' /tmp/.perflab_swap)
echo "  reclaimable: ~${EST} MB"

if [ $APPLY -eq 0 ]; then
  echo "  >> dry run. Re-run with --apply to reclaim."
  echo "=============================================="
  exit 0
fi

echo "  >> draining..."
while read -r kb pid name; do
  # Never stop these. Stopping the IME, the launcher or the Play Store
  # saves swap but costs the user a visible interruption, which is a bad
  # trade. Only background apps are worth reclaiming from.
  case "$name" in
    system_server|surfaceflinger|zygote|zygote64) continue ;;
    com.android.systemui|com.bbk.launcher2) continue ;;
    com.google.android.inputmethod.latin|com.google.android.inputmethod.*) continue ;;
    com.android.vending|com.google.android.gms) continue ;;
    com.vivo.appstore|com.vivo.hiboard|com.vivo.theme|com.bbk.theme) continue ;;
  esac
  # A colon suffix means a secondary process; the package is the part before ':'.
  pkg=${name%%:*}
  echo "     stopping $pkg (${kb} KB swapped)"
  # </dev/null is essential: `am force-stop` otherwise reads stdin and
  # swallows the rest of the loop's input.
  adb -s "$S" shell "am force-stop $pkg" </dev/null >/dev/null 2>&1
  sleep 1
done < /tmp/.perflab_swap

sleep 4
AF=$(swap_used); AA=$(mem_avail); PF=$(swap_pct)
echo
echo "  AFTER    swap ${AF} MB used (${PF}%)   MemAvailable ${AA} MB"
echo "  RECLAIMED $((AF-B4)) MB of swap, $((AA-A4)) MB returned to RAM"
echo "=============================================="
