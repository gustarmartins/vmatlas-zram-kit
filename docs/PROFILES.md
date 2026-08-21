# Memory Profiles and Host-Scaled Tunables

`vmatlas-zram-kit` provides presets and host-scaled tunables designed for heavy development workloads.

## Profile Matrix

| Profile | Pipeline Architecture | Sizing & Resident Cap | Target Workload |
|---|---|---|---|
| `workstation-16gb-tiered-writeback` | LZ4 primary -> ZSTD:3 (#1) -> ZSTD:9 (#2) -> ZSTD:15 (#3) -> NVMe Writeback | `ram * 2.25` virtual size, `ram / 1.6` resident cap | 16GB Workstations, Android Studio, Emulators, Long-uptime Dev |
| `workstation-16gb-tiered` | LZ4 primary -> ZSTD:3 (#1) -> ZSTD:9 (#2) -> ZSTD:15 (#3) | `ram * 2.25` virtual size, `ram / 1.6` resident cap | Multi-tier RAM recompression without SSD writeback |
| `aggressive-build` | LZ4 primary -> ZSTD:3 (#1) -> ZSTD:9 (#2) -> ZSTD:15 (#3) -> NVMe | `ram * 2.50` virtual size, `ram / 1.5` resident cap | Large parallel compilation tasks (AOSP, Chromium, LLVM) |
| `balanced-standard` | LZ4 primary -> ZSTD:3 (#1) -> ZSTD:9 (#2) | `ram * 2.00` virtual size, `ram / 2.0` resident cap | General high-performance desktop multitasking |
| `android-dev-safe` | ZSTD:3 single primary | `min(ram * 2, 32 GiB)`, `ram / 2.0` resident cap | Conservative single-compressor baseline |

---

## 16GB Baseline Tunables (Validated Reference)

```ini
[vm]
vm.swappiness = 142
vm.vfs_cache_pressure = 68
vm.min_free_kbytes = 131072
vm.watermark_scale_factor = 92
vm.watermark_boost_factor = 16155
vm.page-cluster = 0
vm.compaction_proactiveness = 0
vm.compact_unevictable_allowed = 1
vm.zone_reclaim_mode = 0
vm.dirty_bytes = 1342177280
vm.dirty_background_bytes = 78643200
vm.dirty_writeback_centisecs = 150
vm.dirty_expire_centisecs = 1000
vm.extfrag_threshold = 250
vm.max_map_count = 1048576

[mglru]
mglru_enabled = 0x0007
mglru_min_ttl_ms = 2000
```

---

## Host-Scaled Values by RAM Class

When installing on systems with differing amounts of RAM, the installer scales buffer sizes accordingly:

| Host RAM Class | `min_free_kbytes` | Dirty Background / Foreground | MGLRU TTL | Swappiness |
|---|---|---|---|---|
| **<= 8 GiB** | 64 MiB (`65536`) | 32 MiB / 256 MiB | 1000 ms | 140 |
| **16 GiB (Reference)** | 128 MiB (`131072`) | 75 MiB / 1.25 GiB | 2000 ms | 142 |
| **32–48 GiB** | 256 MiB (`262144`) | 128 MiB / 2.50 GiB | 2000 ms | 140 |
| **>= 64 GiB** | 512 MiB (`524288`) | 256 MiB / 5.00 GiB | 3000 ms | 133 |
