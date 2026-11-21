#!/usr/bin/env bash
# Capture a structured, diffable health & regression snapshot for Galaxy S8+ (dream2lte).
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: regression-dream2lte.sh [--output FILE] [--pi]
  --output FILE  Write snapshot to FILE (also prints to stdout)
  --pi           Run Play Integrity check via SPIC (interacts with UI)
EOF
}

OUT_FILE=""
RUN_PI=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            OUT_FILE="${2:?Missing FILE for --output}"
            shift 2
            ;;
        --pi)
            RUN_PI=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

device=$(adb -d shell getprop ro.product.device | tr -d '\r')
if [[ "$device" != dream2lte ]]; then
    printf 'Expected dream2lte, found %s\n' "$device" >&2
    exit 1
fi

run_snapshot() {
    adb -d shell '
set -u
echo "=== IDENTITY & SECURITY ==="
for key in ro.product.model ro.build.display.id ro.build.type ro.build.tags \
    ro.debuggable ro.secure ro.adb.secure ro.build.version.security_patch \
    ro.vendor.build.security_patch org.pixelexperience.build_type \
    ro.boot.verifiedbootstate ro.boot.flash.locked ro.boot.vbmeta.device_state \
    ro.boot.warranty_bit sys.boot_completed sys.system_server.start_elapsed \
    ro.boot.bootloader gsm.version.baseband; do
    printf "%s=%s\n" "$key" "$(getprop "$key")"
done
printf "kernel=%s\n" "$(uname -r)"
printf "selinux=%s\n" "$(getenforce)"

echo "=== LOADAVG & D-STATE THREADS ==="
printf "loadavg=%s\n" "$(cat /proc/loadavg)"
d_threads=$(ps -A -o PID,STAT,WCHAN,NAME | grep " D " || true)
d_count=$(printf "%s\n" "$d_threads" | grep -c " D " || true)
printf "d_state_count=%s\n" "$d_count"
if [ -n "$d_threads" ]; then
    printf "%s\n" "$d_threads"
fi

echo "=== CPU, GPU, HMP, POWERHAL ==="
for policy in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$policy" ] || continue
    for key in scaling_driver scaling_governor scaling_min_freq scaling_max_freq; do
        printf "%s/%s=%s\n" "${policy##*/}" "$key" "$(cat "$policy/$key" 2>/dev/null || echo unavailable)"
    done
    if [ -d "$policy/interactive" ]; then
        for key in hispeed_freq go_hispeed_load target_loads above_hispeed_delay; do
            printf "%s/interactive/%s=%s\n" "${policy##*/}" "$key" "$(cat "$policy/interactive/$key" 2>/dev/null || echo unavailable)"
        done
    fi
done
ps -A -o PID,PCY,PRI,RTPRIO,PSR,NAME | grep -E "cfinteractive|surfaceflinger|traced|wpa_supplicant" | grep -v grep || true
sf_pid=$(pidof surfaceflinger 2>/dev/null || true)
[ -n "$sf_pid" ] && printf "surfaceflinger_cpuset=%s\n" "$(cat "/proc/$sf_pid/cpuset" 2>/dev/null || echo unavailable)"
printf "wpa_supplicant_cmdline=%s\n" "$(tr "\0" " " < "/proc/$(pidof wpa_supplicant 2>/dev/null || echo 0)/cmdline" 2>/dev/null || echo unavailable)"
printf "wifi_logtrace_info=%s\n" "$(cat /data/vendor/conn/.logtrace.info 2>/dev/null || echo unavailable)"
printf "hmp_wakeup_to_idle_cpu=%s\n" "$(cat /sys/kernel/hmp/wakeup_to_idle_cpu 2>/dev/null || echo unavailable)"
printf "gpu_governor=%s\n" "$(cat /sys/devices/13900000.mali/dvfs_governor 2>/dev/null || cat /sys/kernel/gpu/gpu_governor 2>/dev/null || echo unavailable)"
printf "powerhal_looper=%s\n" "$(logcat -d -b main -b system 2>/dev/null | grep -c "NodeLooperThread started" || true)"
printf "powerhal_write_errors=%s\n" "$(logcat -d -b main -b system 2>/dev/null | grep -c "Failed to write to node" || true)"

echo "=== MEMORY, ZRAM, LMK, UFS, TCP ==="
head -n 3 /proc/meminfo
printf "zram_comp_algorithm=%s\n" "$(cat /sys/block/zram0/comp_algorithm 2>/dev/null || echo unavailable)"
printf "zram_mm_stat=%s\n" "$(cat /sys/block/zram0/mm_stat 2>/dev/null || echo unavailable)"
cat /proc/swaps
printf "vm_swappiness=%s\n" "$(cat /proc/sys/vm/swappiness 2>/dev/null || echo unavailable)"
for key in ro.lmk.use_psi ro.lmk.use_minfree_levels ro.lmk.kill_heaviest_task ro.lmk.kill_timeout_ms ro.lmk.log_stats; do
    printf "%s=%s\n" "$key" "$(getprop "$key")"
done
for f in scheduler read_ahead_kb nr_requests iostats rq_affinity add_random; do
    printf "sda/%s=%s\n" "$f" "$(cat "/sys/block/sda/queue/$f" 2>/dev/null || echo unavailable)"
done
printf "vm_page_cluster=%s\n" "$(cat /proc/sys/vm/page-cluster 2>/dev/null || echo unavailable)"
printf "vm_stat_interval=%s\n" "$(cat /proc/sys/vm/stat_interval 2>/dev/null || echo unavailable)"
printf "net_default_qdisc=%s\n" "$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || echo unavailable)"
printf "tcp_fastopen=%s\n" "$(cat /proc/sys/net/ipv4/tcp_fastopen 2>/dev/null || echo unavailable)"
printf "tcp_congestion_control=%s\n" "$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo unavailable)"

echo "=== CELLULAR, WIFI, BLUETOOTH ==="
for key in ro.vendor.multisim.simslotcount persist.radio.multisim.config gsm.sim.state gsm.network.type; do
    printf "%s=%s\n" "$key" "$(getprop "$key")"
done
dumpsys bluetooth_manager | awk "/^[[:space:]]*(enabled|state):/ {print}"
printf "bt_crashes=%s\n" "$(dumpsys bluetooth_manager | grep -c "Bluetooth crashed" || true)"
dumpsys bluetooth_manager | grep -E "Bluetooth crashed" | head -n 3 || true
printf "wifi_on=%s\n" "$(settings get global wifi_on)"
printf "wifi_scan_results=%s\n" "$(cmd wifi list-scan-results 2>/dev/null | tail -n +2 | wc -l | tr -d " ")"
dumpsys thermalservice | awk "/^[[:space:]]*Thermal Status:/ {print}"

echo "=== HALS ==="
lshal 2>/dev/null | grep -oE "android\.hardware\.(audio(@7\.1|\.effect@7\.0)|camera\.provider@2\.5|sensors@1\.0|gnss@1\.1|nfc@1\.2|biometrics\.fingerprint@2\.3|vibrator@1\.0|bluetooth@1\.0|wifi@1\.[0-6]|radio@1\.4|keymaster@3\.0|gatekeeper@1\.0)::[A-Za-z0-9_/@.-]+" | sort -u

echo "=== INPUT & BIXBY ==="
dumpsys input | grep -A 12 -i "gpio_keys" | grep -E "gpio_keys|Path:|KeyLayoutFile:"
cat /system/usr/keylayout/gpio_keys.kl

echo "=== CRASHES ==="
printf "crash_count=%s\n" "$(logcat -b crash -d 2>/dev/null | grep -cE "Fatal signal|FATAL EXCEPTION" || true)"
logcat -b crash -d 2>/dev/null | grep -E "Cmdline:|FATAL EXCEPTION:|Process:" | sort | uniq -c | sort -rn | head -n 15 || true

echo "=== SELINUX AVC SUMMARY ==="
avc_all=$(logcat -d -b all 2>/dev/null | grep "avc: denied" || true)
printf "avc_total_lines=%s\n" "$(printf "%s\n" "$avc_all" | grep -c "avc: denied" || true)"
printf "avc_non_untrusted_app_unique:\n"
printf "%s\n" "$avc_all" | grep -v "scontext=u:r:untrusted_app:" | sed -E "s/^.*avc: denied/avc: denied/; s/pid=[0-9]+ //g; s/ino=[0-9]+ //g" | sort | uniq -c | sort -rn | head -n 25 || true
printf "avc_untrusted_app_unique_count=%s\n" "$(printf "%s\n" "$avc_all" | grep "scontext=u:r:untrusted_app:" | sed -E "s/^.*avc: denied/avc: denied/; s/pid=[0-9]+ //g; s/ino=[0-9]+ //g; s/path=\"socket:\[[0-9]+\]\"/path=\"socket\"/g" | sort -u | wc -l | tr -d " ")"

echo "=== BATTERY & DEEP SLEEP ==="
dumpsys batterystats 2>/dev/null | grep -E "Time on battery|Screen off|Deep Doze|Total run time" | head -n 10
'

    echo "=== CONNECTIVITY ==="
    adb -d shell dumpsys connectivity | python3 -c '
import re, sys
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

    if [[ "$RUN_PI" -eq 1 ]]; then
        echo "=== PLAY INTEGRITY (SPIC) ==="
        adb -d shell '
am force-stop com.henrikherzig.playintegritychecker
monkey -p com.henrikherzig.playintegritychecker -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 3
input tap 720 951
sleep 7
uiautomator dump /data/local/tmp/ui_spic_reg.xml >/dev/null 2>&1
'
        adb -d shell cat /data/local/tmp/ui_spic_reg.xml | python3 -c '
import sys, xml.etree.ElementTree as ET
tree = ET.fromstring(sys.stdin.read())
texts = [n.attrib.get("text", "") for n in tree.iter("node") if n.attrib.get("text", "")]
for i, t in enumerate(texts):
    if any(k in t for k in ("Device recognition", "App recognition", "App licensing", "MEETS_", "NO_INTEGRITY", "UNEVALUATED", "Error")):
        nxt = texts[i + 1] if i + 1 < len(texts) else ""
        print(f"PI: {t} | {nxt}")
'
    fi
}

if [[ -n "$OUT_FILE" ]]; then
    mkdir -p "$(dirname "$OUT_FILE")"
    run_snapshot | tee "$OUT_FILE"
else
    run_snapshot
fi
