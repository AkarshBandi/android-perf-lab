#!/bin/bash
# perf-lab metric collector - works on any adb-connected Android device
S="${1:-$(adb devices | awk 'NR==2{print $1}')}"
[ -z "$S" ] && { echo "no device"; exit 1; }
echo "device_serial: $S"
echo "model: $(adb -s "$S" shell getprop ro.product.model | tr -d '\r')"
echo "android: $(adb -s "$S" shell getprop ro.build.version.release | tr -d '\r') (sdk $(adb -s "$S" shell getprop ro.build.version.sdk | tr -d '\r'))"
echo "rom: $(adb -s "$S" shell getprop ro.build.display.id | tr -d '\r')"
echo "captured_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "---memory---"
adb -s "$S" shell "grep -E 'MemTotal|MemAvailable|SwapTotal|SwapFree|Cached' /proc/meminfo" | tr -d '\r'
echo "---processes---"
echo "total: $(adb -s "$S" shell 'ps -A | wc -l' | tr -d '\r')"
echo "---lmk_kills---"
adb -s "$S" shell "dumpsys activity lmk | head -2 | tail -1" | tr -d '\r'
echo "---packages---"
echo "system_total: $(adb -s "$S" shell 'pm list packages | wc -l' | tr -d '\r')"
echo "third_party: $(adb -s "$S" shell 'pm list packages -3 | wc -l' | tr -d '\r')"
echo "disabled: $(adb -s "$S" shell 'pm list packages -d | wc -l' | tr -d '\r')"
echo "---storage---"
adb -s "$S" shell "df -h /data | tail -1" | tr -d '\r'
echo "---lowmemory_deaths---"
adb -s "$S" shell "dumpsys activity exit-info | grep -oE 'reason=[0-9]+ \([A-Z_]+\)' | sort | uniq -c | sort -rn" | tr -d '\r'
