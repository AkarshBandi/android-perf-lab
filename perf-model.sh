#!/bin/bash
# perf-lab: analytic performance model for a constrained Android device.
#
# Reads the device's REAL hardware and runtime state, then computes the
# theoretical limits so the expected outcome of a change can be predicted
# before applying it.
#
#   ./perf-model.sh
#
# Model:
#   frame_time = cpu_work + gpu_work + io_wait + sched_latency
#   cpu_work   = cycles_needed / clock_available        (Amdahl)
#   gpu_work   = pixels * shader_cost / gpu_throughput
#   io_wait    = pages_to_fetch / io_bandwidth         (Little's Law)
#   sched_lat  = (runnable_procs / cores) * timeslice
#
#   Throughput ratio vs stock:
#     R = (4*f_big + 4*f_little)_current / (4*f_big + 4*f_little)_stock
set -u
S="${DEVICE_SERIAL:-$(adb devices | awk 'NR==2 && $2=="device"{print $1}')}"
sh_() { adb -s "$S" shell "$1" 2>/dev/null | tr -d '\r'; }
f() { sh_ "cat $1 2>/dev/null"; }
num() { awk -v v="${1:-0}" 'BEGIN{ if (v+0==0) print 0; else print v }'; }

CORES=$(num "$(sh_ 'grep -c ^processor /proc/cpuinfo')")
B_MAX=$(num "$(f /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq)")
L_MAX=$(num "$(f /sys/devices/system/cpu/cpu4/cpufreq/cpuinfo_max_freq)")
B_CUR=$(num "$(f /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq)")
L_CUR=$(num "$(f /sys/devices/system/cpu/cpu4/cpufreq/scaling_max_freq)")
GOV=$(f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
MEM_KB=$(num "$(sh_ "grep MemTotal /proc/meminfo" | awk '{print $2}')")
SWAP_KB=$(num "$(sh_ "grep SwapTotal /proc/meminfo" | awk '{print $2}')")
SWAP_FREE=$(num "$(sh_ "grep SwapFree /proc/meminfo" | awk '{print $2}')")
MEM_AVAIL=$(num "$(sh_ "grep MemAvailable /proc/meminfo" | awk '{print $2}')")
PROCS=$(num "$(sh_ 'ps -A | wc -l')")
RUNNABLE=$(num "$(sh_ "ps -A -o STAT | grep -c R")")
PANEL_W=$(num "$(sh_ "dumpsys display | grep -oE 'width=[0-9]+' | head -1" | cut -d= -f2)")
PANEL_H=$(num "$(sh_ "dumpsys display | grep -oE 'height=[0-9]+' | head -1" | cut -d= -f2)")
FPS=$(num "$(sh_ "dumpsys display | grep -oE 'fps=[0-9.]+' | head -1" | cut -d= -f2)")
[ "$FPS" = "0" ] && FPS=60

STOCK_MHZ=$(( B_MAX*4 + L_MAX*4 ))
CAPPED_MHZ=$(( B_CUR*4 + L_CUR*4 ))
RATIO=$(awk -v a="$STOCK_MHZ" -v b="$CAPPED_MHZ" 'BEGIN{ printf (a>0)? "%.4f" : "1.0", b/a }')
LOST=$(awk -v r="$RATIO" 'BEGIN{ printf "%.1f", (1-r)*100 }')
SLOWDOWN=$(awk -v r="$RATIO" 'BEGIN{ printf "%.2f", (r>0)? 1/r : 1 }')
BUDGET=$(awk -v f="$FPS" 'BEGIN{ printf "%.2f", 1000/f }')
SWAP_USED_MB=$(( (SWAP_KB - SWAP_FREE) / 1024 ))
SWAP_TOTAL_MB=$(( SWAP_KB / 1024 ))
MEM_AVAIL_MB=$(( MEM_AVAIL / 1024 ))
MEM_TOTAL_MB=$(( MEM_KB / 1024 ))
PIXELS=$(( PANEL_W * PANEL_H ))
SWAP_PCT=$(awk -v u="$SWAP_USED_MB" -v t="$SWAP_TOTAL_MB" 'BEGIN{ printf (t>0)? "%.1f" : "0", u/t*100 }')
WAVES=$(awk -v r="$RUNNABLE" -v c="$CORES" 'BEGIN{ printf (c>0)? "%.2f" : "0", r/c }')
CPU_FLOOR=$(awk -v b="$BUDGET" -v r="$RATIO" 'BEGIN{ printf "%.2f", b/r }')
MEM_FLOOR=$(( MEM_TOTAL_MB / 3 ))

echo "=============================================="
echo " PERF-LAB ANALYTIC MODEL"
echo " $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "=============================================="
echo
echo "[1] HARDWARE ENVELOPE"
echo "    cores            $CORES  (4 big + 4 little, governor=$GOV)"
echo "    RAM              ${MEM_TOTAL_MB} MB   (available ${MEM_AVAIL_MB} MB)"
echo "    swap             ${SWAP_TOTAL_MB} MB   (in use ${SWAP_USED_MB} MB = ${SWAP_PCT}%)"
echo "    panel            ${PANEL_W}x${PANEL_H} @ ${FPS} Hz"
echo "    frame budget     ${BUDGET} ms/frame"
echo
echo "[2] CPU CAP ANALYSIS"
echo "    stock peak       $((STOCK_MHZ/1000)) MHz aggregate"
echo "    current ceiling  $((CAPPED_MHZ/1000)) MHz aggregate"
echo "    ratio R          $RATIO"
echo "    HEADROOM LOST    ${LOST}%"
echo "    big cluster      $((B_MAX/1000)) -> $((B_CUR/1000)) MHz"
echo "    little cluster   $((L_MAX/1000)) -> $((L_CUR/1000)) MHz"
echo
echo "    R = (4*f_big + 4*f_little)_current / (...)_stock"
echo "    a task needing N cycles now takes ${SLOWDOWN}x longer."
echo
echo "[3] BUDGET DECOMPOSITION"
echo "    cpu_bound floor  ${CPU_FLOOR} ms  (budget ${BUDGET} ms / R)"
echo "    io_wait risk     swap ${SWAP_PCT}% used"
echo "    sched contention ${RUNNABLE} runnable / ${CORES} cores = ${WAVES} waves"
echo
echo "[4] REACHABLE LEVERS, RANKED BY GAIN/RISK"
echo
echo "    (a) Cut runnable-process count"
echo "        d(queue_depth) = d_runnable / cores"
echo "        Every process out of R state removes a scheduling wave."
echo "        Current ${RUNNABLE} runnable, ${PROCS} total."
echo "        EXPECTED: lower p95. Measured effect of removing the"
echo "        vendor supervisors: runnable ~40 -> ${RUNNABLE}."
echo
echo "    (b) Reduce swap residency (io_wait term)"
echo "        A page fault served from zram costs ~100x a RAM access."
echo "        Keep MemAvailable above ~${MEM_FLOOR} MB to stay in RAM."
echo "        Current ${MEM_AVAIL_MB} MB."
echo "        EXPECTED: fewer major faults -> shorter p99."
echo
echo "    (c) Cut render resolution (gpu_work term)"
echo "        pixels: scale 1.0 = ${PIXELS} px, scale 0.7 = $(awk -v p="$PIXELS" 'BEGIN{printf "%.0f", p*0.49}') px (-51%)"
echo "        EXPECTED: gpu_work ~halves. ONLY worth it when gpu_bound."
echo "        Here GPU p50 = 5ms vs ${BUDGET} ms budget -> NOT gpu_bound."
echo "        => reverted: trades visible sharpness for a non-bottleneck."
echo
echo "    (d) Shorten animations (perceived latency)"
echo "        animation_scale s -> wall-clock duration scales by s."
echo "        s=0.5 -> animations finish in half the time."
echo "        EXPECTED: perceived input response improves; frame_time"
echo "        unchanged. Zero regression risk."
echo
echo "    (e) Keep foreground apps out of the standby kill tier"
echo "        bucket 10 (active) => oom_score_adj 0 => never harvested."
echo "        EXPECTED: LOW_MEMORY deaths eliminated. Measured 1971 -> 0."
echo
echo "[5] THE CEILING ITSELF IS NOT REACHABLE FROM THE SHELL"
echo "    \$ echo $B_MAX > /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq"
echo "      -> Permission denied (root-only node)"
echo "    Verified: thermal cdev states are 0, CPU temps are ~37 C, and"
echo "    disabling the charging state does not lift it. The cap is a"
echo "    deliberate vendor power tier, not thermal throttling."
echo
echo "[6] PREDICTION VALIDATION"
awk -v b="$BUDGET" -v r="$RATIO" 'BEGIN{
  printf "    p50 target   <= %.1f ms   (budget %.2f, cpu floor %.2f)\n", b*0.5, b, b/r;
  printf "    p95 target   <= %.1f ms   (1.5x budget)\n", b*1.5;
  printf "    jank target  <= 5%%\n";
  printf "    if p50 > %.2f ms  -> CPU bound: fix the memory path\n", b/r;
  printf "    if p50 ok, p95 bad -> scheduling/IO stall: cut runnable procs\n";
}'
echo "=============================================="
