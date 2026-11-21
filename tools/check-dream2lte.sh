#!/usr/bin/env bash
# Capture read-only health checks for an attached Galaxy S8+.
set -euo pipefail

device=$(adb -d shell getprop ro.product.device | tr -d '\r')
if [[ "$device" != dream2lte ]]; then
    printf 'Expected dream2lte, found %s\n' "$device" >&2
    exit 1
fi

adb -d shell '
set -e
for key in ro.product.model ro.build.display.id ro.build.version.security_patch \
    sys.boot_completed ro.boot.bootloader gsm.version.baseband gsm.sim.state \
    gsm.network.type ro.vendor.multisim.simslotcount persist.radio.multisim.config; do
    printf "%s=%s\n" "$key" "$(getprop "$key")"
done
printf "kernel=%s\n" "$(uname -r)"
printf "selinux=%s\n" "$(getenforce)"
for policy in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$policy" ] || continue
    for key in scaling_driver scaling_governor scaling_min_freq scaling_max_freq; do
        printf "%s/%s=%s\n" "${policy##*/}" "$key" "$(cat "$policy/$key" 2>/dev/null || echo unavailable)"
    done
done
printf "zram_compression=%s\n" "$(cat /sys/block/zram0/comp_algorithm 2>/dev/null || echo unavailable)"
cat /proc/swaps
dumpsys bluetooth_manager | awk "/^[[:space:]]*(enabled|state):/ {print}"
dumpsys thermalservice | awk "/^[[:space:]]*Thermal Status:/ {print}"
'

adb -d shell dumpsys connectivity | python3 -c '
import re
import sys

data = sys.stdin.read()
default = re.search(r"Active default network: (\d+)", data)
for line in data.splitlines():
    agent = re.search(r"NetworkAgentInfo\{network\{(\d+)\}", line)
    transport = re.search(r"Transports: ([A-Z_|]+)", line)
    if agent and transport:
        role = "default" if default and agent[1] == default[1] else "secondary"
        status = "validated" if re.search(r"\bVALIDATED\b", line) else "unvalidated"
        print(f"{transport[1]} {role} {status}")
'
