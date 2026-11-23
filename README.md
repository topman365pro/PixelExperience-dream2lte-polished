# PixelExperience 13 Plus (Polished) — Samsung Galaxy S8+ (`dream2lte`)

An optimized, SELinux-enforcing daily-driver build (`20261123-POLISHED`), kernel (`4.4.302-dream2lte-polished-p3`), device/SELinux patches, and reproducible packaging tooling for the **Samsung Galaxy S8+ (`SM-G955F`, `dream2lte`, Exynos 8895)**, built on top of **PawiX25**'s PixelExperience 13 Plus release (`20231020-1541`) and **Ivan Meler / 8890q**'s Exynos 8895 kernel and device trees.

> [!IMPORTANT]
> ## Credits & Attribution
> All foundational ROM, kernel, HAL, and device-tree work belongs to the original authors and maintainers:
> - **Original ROM Author — [PawiX25](https://xdaforums.com/t/rom-13-unofficial-pixelexperience-for-s8-s8-and-note-8-19-10-2023.4637152/)**: Built and released the base `[ROM][13][UNOFFICIAL] PixelExperience for S8/S8+ and Note 8 [19/10/2023]` (`PixelExperience_Plus_dream2lte-13.0-20231020-1541`) that this release is built directly on top of.
>   - Original XDA Thread: <https://xdaforums.com/t/rom-13-unofficial-pixelexperience-for-s8-s8-and-note-8-19-10-2023.4637152/> ([Wayback Archive](https://web.archive.org/web/20251114020632/https://xdaforums.com/t/rom-13-unofficial-pixelexperience-for-s8-s8-and-note-8-19-10-2023.4637152/))
>   - Original ROM Folder (Google Drive): <https://drive.google.com/drive/folders/1ixZg5rAybvtYD47A-xn4svEoLKE6-u3Q>
> - **Kernel, Device Trees & Exynos 8895 Platform — Ivan Meler (`ivanmeler`) & `8890q` contributors**: Maintainer of the Exynos 8895 Linux `4.4.302` kernel (`android_kernel_samsung_universal8895`), `dream2lte` / `universal8895-common` device trees, vendor blobs, SLSI-Linaro HALs, and [ivanmeler/local_manifests](https://github.com/ivanmeler/local_manifests).
> - **PixelExperience ROM Source — `jhenrique09` & the PixelExperience Team**: [github.com/PixelExperience](https://github.com/PixelExperience).
> - **LineageOS**: `android_hardware_samsung` and `android_device_samsung_slsi_sepolicy`.

---

## Download (`v20261123-polished`)

Download the flashable TWRP ROM ZIP directly from **[GitHub Releases (`v20261123-polished`)](https://github.com/topman365pro/PixelExperience-dream2lte-polished/releases/latest)**:

| Artifact | Size | SHA-256 | Purpose |
|---|---:|---|---|
| **`PixelExperience_Plus_dream2lte-13.0-20261123-POLISHED.zip`** | `1,403,935,228` B (`1.31 GiB`) | `f8a2503965cdffd4e3611e2ea7b9ca7098cee6c6e1093a0827bddd14286d872b` | Full signed TWRP-flashable ROM (`SYSTEM` + `BOOT`; preserves `/data` & TWRP) |
| **`boot-dream2lte-pass3.img`** *(optional)* | `32,219,152` B (`30.7 MiB`) | `5490973f2cd2012d7a65fb0c77985b938d1a2f528f8beed7851707379c848b44` | Standalone kernel boot image (`4.4.302-dream2lte-polished-p3`), already included inside the ZIP |
| **`SHA256SUMS.txt`** | `203` B | — | Checksums for the release ZIP and `CHANGELOG.md` |

Verify checksums after downloading:
```bash
shasum -a 256 -c SHA256SUMS.txt
```

---

## What Changed

Hardens, speeds up, and stabilizes the base PixelExperience 13 Plus build without wiping user data. See [`CHANGELOG.md`](CHANGELOG.md) for per-release notes and [`patches/`](patches/) for the exact diffs.

### 1. Kernel & Stability (`4.4.302-dream2lte-polished-p3`, `clang-14`, 0 modpost warnings)
- **SELinux Enforcing**: Removed the forced permissive override in `security/selinux/selinuxfs.c` (`new_value = 0;`), unset `CONFIG_ALWAYS_PERMISSIVE`, and enabled `CONFIG_AUDIT=y` with `CONFIG_AUDITSYSCALL=n` (preserves SELinux AVC reporting without per-syscall audit overhead).
- **Fixed Phantom Idle Load Average (`~7.8` -> `< 1.0`)**: Fixed 7 permanently uninterruptible (`D`-state) kernel threads (`5x [simpleinteracti]` in `drivers/devfreq/governor_simpleinteractive.c` and `[tee_irq_bh]` / `[tee_scheduler]` in Trustonic `MobiCoreDriver/{nq.c,scheduler.c}`).
- **Core Kernel Fixes**: Fixed `cgroup`/`cpuset` `allow_attach()` stack `cset->mg_node` corruption, `pidfd` `fdinfo` `seq_put_decimal_ull()` bug, `crypto/testmgr.c` `__init` section mismatch, and backported the arm64 VDSO `$(LD)` linking fix (`75a0685708`).
- **Debug Overhead Removal**: Disabled `SCSI_UFS_CMD_LOGGING`, `F2FS_CHECK_FS`, `MALI_KUTF`, `MALI_GATOR_SUPPORT`, `MALI_SYSTRACE_SUPPORT`, `ARM_EXYNOS_DEVFREQ_DEBUG`, and `BT_DEBUGFS`.

### 2. CPU, GPU, HMP & PowerHAL
- **Interactive Governor & Exynos 8895 OPPs**: Replaced mismatched Exynos 8890 frequencies in `init.samsungexynos8895.rc` with valid Exynos 8895 OPPs, tuned `timer_rate=16000` and big-cluster `above_hispeed_delay`, elevated `[cfinteractive]` to unbound `SCHED_FIFO` RT priority `99` (`PRI=139`, `RTPRIO=99`), and added a zero-value guard in `store_boostpulse()`.
- **Mali-G71 GPU**: Fixed the `min_lock` DVFS upward-scaling bug in `gpu_dvfs_api.c` and clamped DT `polling_speed` from `30 ms` to `<= 20 ms` in `mali_kbase_platform.c`.
- **PowerHAL & HMP**: Fixed invalid `powerhint.json` OPP (`1794000` -> `1807000`), added missing `DefaultIndex` entries, fixed `CPUBoostPulse` (`ResetOnInit: false`), trimmed `LAUNCH` duration (`5000 -> 2000 ms`) while unlocking `2314 MHz` big-cluster boost, added `LOW_POWER` caps (`1937 MHz` big / `1456 MHz` little / `455 MHz` GPU), enabled `CONFIG_WQ_POWER_EFFICIENT_DEFAULT=y` and `hmp/wakeup_to_idle_cpu=1`, and expanded cpusets.

### 3. Battery, Wi-Fi, Bluetooth & Background Overhead
- **Wi-Fi (`bcmdhd4361` + `wpa_supplicant`)**: Halved `DHD_PACKET_TIMEOUT_MS` and `OOB_WAKE_LOCK_TIMEOUT` (`500 -> 250 ms`), lowered `CUSTOM_PNO_EVENT_LOCK_xTIME` (`10 -> 4`), stripped 7 heavy driver debug/dump compile flags (keeping `-DBCMDBG`), removed `-dd` verbose debug logging from `wpa_supplicant`, and set `/data/vendor/conn/.logtrace.info` to `0`.
- **Bluetooth (`bcm43xx`) & Audio**: Downgraded repetitive host-wake `pr_err`/`pr_info` spam to `pr_debug` and removed `ro.config.systemaudiodebug=abox&codecdsp`.
- **Tracing & Init Cleanup**: Disabled Perfetto background tracing (`persist.traced.enable=0`, keeping `traced`/`traced_probes` stopped), updated `surfaceflinger.rc` to `task_profiles HighPerformance ProcessCapacityHigh`, removed dead `/dev/cpuset/surfaceflinger/*` writes and dead legacy Samsung triggers (`ro.crypto.fuse_sdcard`, `security.semdaemonfinish`, `sem_daemon`) from `init.samsungexynos8895.rc`, fixed `vendor.sys.mobicoredaemon.enable`, and replaced slow shell `restorecon` execs with built-in `restorecon_recursive`.

### 4. Storage, Memory & Networking
- **UFS Flash**: Enabled `CONFIG_IOSCHED_DEADLINE=y` and switched default scheduler for `sda` to `deadline` with `rq_affinity=2`, `iostats=0`, `read_ahead_kb=128`, and `nr_requests=256`.
- **Memory & ART**: Enabled 2 GiB `lz4` ZRAM (`vm.swappiness=100`, removed unsupported writeback options), enabled `ro.lmk.kill_heaviest_task=true`, tuned VM (`page-cluster=0`, `stat_interval=10`, `dirty_*`) and Dalvik heap (`heapgrowthlimit=256m`, `heapmaxfree=32m`), and disabled broken `dalvik.vm.appimageformat=lz4` to eliminate 32-bit `dex2oat64` `SIGABRT` crashes (e.g., Google App `speed-profile` compilation).
- **Networking**: Enabled `CONFIG_NET_SCH_FQ_CODEL=y` (`net.core.default_qdisc=fq_codel`), `tcp_fastopen=3`, and `westwood` default TCP congestion control.

### 5. SELinux, Cellular, Hardware & Play Integrity
- **SELinux Policy (`secilc -m -M true -G -c 30`, 0 errors / 0 `neverallow`)**: Fixed audio HAL (`hal_audio_default_exec`) execution domain, restored Dual-SIM DSDS LTE (`secril_config_svc` EFS access + `ro.vendor.multisim.simslotcount` baseband triggers), labeled `/sys/devices/virtual/sec/switch/afc_disable` as `sysfs_sec_switch_writable` and `/efs/FactoryApp/mag_cal_param` as `sensor_factoryapp_efs_file`, and cleaned up noisy denials.
- **Play Integrity & Release Props**: Switched props to `user` / `release-keys` / `OFFICIAL` (`2023-09-01` patch prop) and upgraded `PixelPropsUtils` in `framework.jar` (natively re-preopted on-device) with dynamic `debug.pihooks.*` -> `persist.vendor.pihooks.*` -> `ro.vendor.pihooks.*` hooks, improving SPIC verdicts from `NO_INTEGRITY` to `MEETS_BASIC_INTEGRITY`, `PLAY_RECOGNIZED`, and `LICENSED`.
  - *Note*: `MEETS_DEVICE_INTEGRITY` and `MEETS_STRONG_INTEGRITY` still require a locked bootloader and an unrevoked hardware TEE keybox.
- **Bixby Button**: Remapped scancode `703` to `ASSIST` in `gpio_keys.kl` and patched `PhoneWindowManager.shouldDisableKey(int)` in `services.jar` so the Bixby button (and pressure-sensitive Home key) remain active with gesture/navbar navigation enabled.

### 6. Graphics Driver (Pass 4 — Mali-G71 `r16p0-01rel0` Vulkan Fix)
- **Vulkan Per-Stage Sampled-Image Limit (`vendor/lib{64,}/egl/libGLES_mali.so`)**: Patched `VkPhysicalDeviceLimits` in both 64-bit (`0x1d9d540`) and 32-bit (`0x1160f0`) Mali drivers via [`tools/patch-mali-vulkan-limits.py`](tools/patch-mali-vulkan-limits.py) to raise `maxPerStageDescriptorSampledImages` from `16` to `64` and `maxPerStageResources` from `79` to `127` (preserving `maxDescriptorSetSampledImages = 96`), labeled `u:object_r:same_process_hal_file:s0`. Fixes Unity `2022.3` / lilToon shader rejection (e.g., *Chill With You* `Hidden/ltspass_*` requiring `23–26` sampled-image slots per stage) while keeping `vkLoadingFailureCount = 0` and `SELinux Enforcing`.

---

| Check | Result |
|---|---|
| **Kernel** | `4.4.302-dream2lte-polished-p3` |
| **SELinux** | `Enforcing` |
| **`[cfinteractive]`** | `PRI=139`, `RTPRIO=99` (`SCHED_FIFO`, unbound) |
| **Settled D-State Threads** | `0` (`loadavg` `1.86` decaying after boot burst vs `~7.8` stock idle) |
| **Crashes (`logcat -b crash`) / PowerHAL Errors** | `0` / `0` |
| **Perfetto / Wi-Fi Debug** | `traced` & `traced_probes` stopped (`persist.traced.enable=0`); `wpa_supplicant` without `-dd` |
| **UFS / Network** | `sda/scheduler=noop [deadline] cfq` (`rq_affinity=2`); `fq_codel`, `tcp_fastopen=3`, `westwood` |
| **Cellular / Wi-Fi / Bluetooth** | DSDS LTE (`IRadio@1.4/slot1` & `slot2`), Wi-Fi validated (`8.8.8.8` 0% loss, `30.3 ms` avg), BT `ON` (`0` crashes), all 12 HAL groups registered |
| **Vulkan Driver (Pass 4)** | `vkLoadingFailureCount = 0`, `maxPerStageDescriptorSampledImages = 64` (Unity/lilToon shaders render cleanly) |
| **Play Integrity (`SPIC`)** | `MEETS_BASIC_INTEGRITY`, `PLAY_RECOGNIZED`, `LICENSED` |

---

## Flashing Instructions

1. **Back up first**: Take a TWRP backup of `Boot`, `System`, `Data`, and `EFS` before flashing.
2. **Flash in TWRP**:
   - Dirty-flash safe over base `PixelExperience_Plus_dream2lte-13.0-20231020-1541` (`SYSTEM` and `BOOT` are updated; `/data` and TWRP are preserved).
   - Boot into TWRP -> **Install** -> select `PixelExperience_Plus_dream2lte-13.0-20261123-POLISHED.zip` (or use `adb sideload`).
3. *(Optional, for magnetometer calibration EFS label on existing `/efs`)* In TWRP with `/efs` mounted `rw`:
   ```sh
   chcon u:object_r:sensor_factoryapp_efs_file:s0 /efs/FactoryApp/mag_cal_param
   ```
4. **Reboot to System**.

### Runtime Play Integrity Fingerprint Override (No Root Required)
If Google rotates spoof targets in the future, you can override `PixelPropsUtils` fields on the fly until reboot via ADB:
```bash
adb shell setprop debug.pihooks.fingerprint "<fingerprint>"
adb shell setprop debug.pihooks.security_patch "<YYYY-MM-DD>"
adb shell "pm clear com.android.vending && am force-stop com.google.android.gms"
```
*(Never run `pm clear com.google.android.gms` when testing Play Integrity.)*

### Optional: Persistent System-Wide 1080p Scaling (No Root Required)
To reduce GPU fill-rate load by `43.75%` (`+51%` FPS in GPU-bound apps) while preserving the `18.5:9` aspect ratio and native `480 dp` UI width across reboots:
```bash
adb shell 'wm size 1080x2220 && wm density 360'
```
Revert to native `1440x2960` @ `480 dpi` anytime:
```bash
adb shell 'wm size reset && wm density reset'
```

---

## Disclaimer
Custom ROMs and kernel modifications carry inherent risk. Always keep a working TWRP and EFS backup before flashing.
