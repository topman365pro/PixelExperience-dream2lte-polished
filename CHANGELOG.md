# PixelExperience 13 Plus (`dream2lte`) — 20261121-POLISHED Release Changelog

- **Target Device**: Samsung Galaxy S8+ (`SM-G955F`, `dream2lte`, Exynos 8895)
- **Base ROM**: `PixelExperience_Plus_dream2lte-13.0-20231020-1541` (`TQ3A.230901.001.B1`, Android 13)
- **Android Security Patch Level**: `2023-09-01` (`org.pixelexperience.build_security_patch=2023-09-01`)
- **Vendor Security Patch Level**: `2021-04-01`
- **Flash Method**: Dirty-flash safe over base PixelExperience 13 Plus (`SYSTEM` + `BOOT` updated; `/data` untouched; TWRP preserved)

---

## Pass 3 Polish, Efficiency & Stability (`20261121-POLISHED`)

### Kernel (`4.4.302-dream2lte-polished-p3`, `clang-14`, 0 modpost/section warnings)
- **`cpufreq_interactive` responsiveness**: Elevated `cfinteractive` kthread to `SCHED_FIFO` RT priority 99 (`MAX_RT_PRIO - 1`), removed `kthread_bind(speedchange_task, 0)` so DVFS scale updates are not bottlenecked on CPU 0, added clean `get_task_struct`/`wake_up_process` + teardown in `exit()`, and added zero-value guard in `store_boostpulse()`.
- **I/O & Network Scheduling**: Enabled `CONFIG_IOSCHED_DEADLINE=y` / `CONFIG_DEFAULT_DEADLINE=y` (`default_iosched="deadline"`) for UFS flash (reducing CFQ overhead) and `CONFIG_NET_SCH_FQ_CODEL=y` for low-latency bufferbloat-free packet scheduling.
- **Audit & Debug Overhead Reduction**: Kept `CONFIG_AUDIT=y` with `CONFIG_AUDITSYSCALL=n` (zero per-syscall audit overhead while preserving SELinux netlink AVC reporting); disabled `SCSI_UFS_CMD_LOGGING`, `F2FS_CHECK_FS`, `MALI_KUTF`, `MALI_GATOR_SUPPORT`, `MALI_SYSTRACE_SUPPORT`, `ARM_EXYNOS_DEVFREQ_DEBUG`, and `BT_DEBUGFS`.
- **Wi-Fi (`bcmdhd4361`)**: Halved `DHD_PACKET_TIMEOUT_MS` and `OOB_WAKE_LOCK_TIMEOUT` (`500 -> 250 ms`), reduced `CUSTOM_PNO_EVENT_LOCK_xTIME` (`10 -> 4`) to curb idle battery drain, and stripped 7 heavy debug/dump compile flags (`DHD_PKTID_AUDIT_ENABLED`, `DHD_KERNEL_SCHED_DEBUG`, `DHD_TRACE_WAKE_LOCK`, `DHD_ENABLE_BIGDATA_LOGGING`, `DHD_8021X_DUMP`, `DHD_DHCP_DUMP`, `DHD_ICMP_DUMP`) while preserving `-DBCMDBG`.
- **Bluetooth (`bcm43xx`) & GPU (`mali_kbase_platform`)**: Downgraded repetitive `set_wake_locked` / `update_host_wake_locked` wake logs to `pr_debug`; clamped DT `polling_speed` from `30 ms` to `<= 20 ms` for tighter GPU DVFS reactivity.
- **ARM64 VDSO**: Backported upstream `8890q` commit `75a0685708` (`$(LD)` linking).

### Userspace, Init, PowerHAL & Properties
- **`surfaceflinger.rc`**: Switched to `task_profiles HighPerformance ProcessCapacityHigh`, eliminating failed writes to non-existent `/dev/cpuset/surfaceflinger/*`.
- **Perfetto & Radio/Wi-Fi Log Reduction**: Set `persist.traced.enable=0` to stop background `traced`/`traced_probes` daemons, removed `-dd` verbose debug logging from `wpa_supplicant` service startup, wrote `/data/vendor/conn/.logtrace.info` `0`, and removed `ro.config.systemaudiodebug=abox&codecdsp` from `/vendor/build.prop`.
- **`init.samsungexynos8895.rc`**: Removed dead `/dev/cpuset/surfaceflinger/*` and dead legacy Samsung triggers (`ro.crypto.fuse_sdcard`, `security.semdaemonfinish`, `sem_daemon`), fixed `vendor.sys.mobicoredaemon.enable`, tuned `interactive` (`timer_rate=16000`, `cpu4` `above_hispeed_delay="19000 1469000:39000 1703000:19000"`), configured `deadline` scheduler with `rq_affinity=2`, VM tuning (`page-cluster=0`, `stat_interval=10`, `dirty_*`), `net.core.default_qdisc=fq_codel`, and `tcp_fastopen=3`.
- **`powerhint.json` & Props**: Fixed `CPUBoostPulse` `ResetOnInit: false`, trimmed `LAUNCH` boost (`5000 -> 2000 ms` with `PMQoSCpuDmaLatency=1500`), lowered `LOW_POWER` little-cluster max frequency to `1456000 kHz`, tuned Dalvik heap (`dalvik.vm.heapgrowthlimit=256m`, `dalvik.vm.heapmaxfree=32m`), and set `org.pixelexperience.version.display=PixelExperience_Plus_dream2lte-13.0-20261121-POLISHED-OFFICIAL`.

### SELinux (`secilc -m -M true -G -c 30`, 0 errors / 0 `neverallow`)
- Fixed `/sys/devices/virtual/sec/switch/afc_disable` labeling (`sysfs_sec_switch_writable`) in `vendor_file_contexts`.
- Labeled `/efs/FactoryApp/mag_cal_param` as `sensor_factoryapp_efs_file` with `kernel` and `hal_sensors_default` rw permissions for persistent magnetometer calibration without AVC spam.
- Granted `vendor_init` write permission on `proc_dirty` / `proc` and added targeted `dontaudit` cleanup (`bootanim`, `hal_camera_default`, `hal_fingerprint_default`, `rild`, `audioserver`, `secril_config_svc`).

---

## Pass 2 Additions & Fixes (`20261120-POLISHED`)

### Kernel (`4.4.302-dream2lte-polished`)
- **Fixed phantom idle load average (~7.8 -> < 1.0)**:
  - `drivers/devfreq/governor_simpleinteractive.c`: Wake `simpleinteractive` kthreads immediately after creation (`wake_up_process`) so idle devfreq instances enter `TASK_INTERRUPTIBLE` rather than remaining parked in `TASK_UNINTERRUPTIBLE` (D-state).
  - `drivers/gud/gud-exynos8895_kinibi400/MobiCoreDriver/{nq.c,scheduler.c}`: Use `wait_for_completion_interruptible()` in `irq_bh_worker` (paired with `complete(&l_ctx.irq_bh_complete)` in `nq_stop()`) and `wait_for_completion_interruptible_timeout()` in `tee_scheduler` so idle Trustonic TEE worker threads do not count toward kernel load average.

### Play Integrity (`framework.jar` `PixelPropsUtils` + Native Re-Preopt)
- Replaced hardcoded `walleye` / Android 8.1 / `DEVICE_INITIAL_SDK_INT=26` spoofing with dynamic property-backed Play Integrity hooks (`debug.pihooks.*` -> `persist.vendor.pihooks.*` -> `ro.vendor.pihooks.*` -> built-in defaults) covering `BRAND`, `MANUFACTURER`, `PRODUCT`, `DEVICE`, `MODEL`, `FINGERPRINT`, `ID`, `RELEASE`, `INCREMENTAL`, `SECURITY_PATCH`, and `DEVICE_INITIAL_SDK_INT`.
- Added configurable Play Store (`com.android.vending`) `SDK_INT=32` / fingerprint / attestation-block hooks for Android 13+ Play Integrity compatibility without root.
- Broadened DroidGuard stack trace matching (case-insensitive) and configurable GMS attestation blocking.
- Re-preopted `framework.jar` boot image extensions natively on-device for both `arm64` and `arm` (`boot-framework.{art,oat,vdex}` and chained framework extensions).

### Hardware & Input
- **Bixby Button**:
  - Mapped scancode `703` to `ASSIST` in `/system/usr/keylayout/gpio_keys.kl` (preserving `key 172 HOME` for the pressure-sensitive home key), launching Google Assistant by default and allowing remapping via Key Mapper.
  - Patched `PhoneWindowManager.shouldDisableKey(int)` in `/system/framework/services.jar` (plus native `arm64` re-preopt of `/system/framework/oat/arm64/services.{art,odex,vdex}`) so `KEYCODE_ASSIST` (`219`) and physical `KEYCODE_HOME` (`3`) are no longer dropped when navigation bar / gesture navigation is enabled.

### Runtime, Memory, ART & SELinux Polish
- **ART `dex2oat64` crash fix**: Disabled app-image generation (`#dalvik.vm.appimageformat=lz4` in `/system/build.prop`) to prevent `art::linker::ImageWriter::GetNativeRelocation` `SIGABRT` crashes during 32-bit `speed-profile` compilation (e.g., Google App) while preserving full AOT `.odex`/`.vdex` compilation.
- **LMKD tuning**: Enabled `ro.lmk.kill_heaviest_task=true` (honored under `ro.lmk.use_minfree_levels=true` on kernel 4.4) to reclaim memory more cleanly under 4 GB RAM pressure.
- **SELinux**: Added `vendor_pihooks_prop` (`persist.vendor.pihooks.`, `ro.vendor.pihooks.`) with strict domain permissions and cleared residual `gmscore_app` (`sysfs_virtual`) and `system_app` (`sysfs_zram`) denials, compiled with `secilc -m -M true -G -c 30` (0 `neverallow` violations). Also synchronized `/sepolicy` with `/vendor/etc/selinux/precompiled_sepolicy`.

---

## Included Pass 1 Foundation
- **SELinux Enforcing**: Removed `selinuxfs.c` `new_value = 0` permissive override, unset `CONFIG_ALWAYS_PERMISSIVE`, enabled `CONFIG_AUDIT=y`, labeled `hal_audio_default_exec` on `android.hardware.audio.service.universal8895`, fixed `restorecon_recursive` and `sysfs_virtual` overrides.
- **CPU, GPU, HMP & I/O**: Retuned Exynos 8895 `interactive` OPP parameters, fixed `powerhint.json` OPPs + `LAUNCH`/`LOW_POWER` profiles, fixed Mali-G71 `min_lock` DVFS scaling bug, enabled `CONFIG_WQ_POWER_EFFICIENT_DEFAULT=y`, `hmp/wakeup_to_idle_cpu=1`, expanded cpusets, `lz4` 2 GiB ZRAM (`vm.swappiness=100`), CFQ/UFS queue tuning, `westwood` default TCP congestion control.
- **Kernel Stability Fixes**: Fixed `cgroup`/`cpuset` `allow_attach` stack `cset->mg_node` corruption, `pidfd` `fdinfo` `seq_put_decimal_ull` bug, and `crypto/testmgr.c` `__init` section mismatch.
- **Connectivity & Official Release Props**: Fixed Dual-SIM `ro.vendor.multisim.simslotcount` baseband triggers and `secril_config_svc` EFS access; set `user` / `release-keys` / `OFFICIAL` properties.
