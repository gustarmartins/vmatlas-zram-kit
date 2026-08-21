# vmatlas-zram-kit

High-performance, multi-tier ZRAM and Linux VM policy kit tailored for heavy development workstations (Android Studio, Gradle daemons, emulators, compilers, Chromium, LLVM builds, and intensive multitasking).

## Architecture: 5-Stage Adaptive Memory Hierarchy

Modern memory management on high-throughput Linux systems requires both instant swap-out latency and high compression density over time. `vmatlas-zram-kit` constructs a verified 5-stage memory progression:

```text
RAM  ──►  [Primary] LZ4  ──►  [Tier 1] ZSTD:3  ──►  [Tier 2] ZSTD:9  ──►  [Tier 3] ZSTD:15  ──►  [Backing] NVMe Writeback
           (Burst latency)    (Idle ~30 mins)      (Idle ~3 hours)      (Idle ~12 hours)        (Resident limit guard)
```

| Stage | Algorithm / Target | Policy & Timing | Purpose |
|---|---|---|---|
| **Primary** | `lz4` (or `zstd:3`) | Immediate swap-out path | Nanosecond-level latency for bursty memory spikes |
| **Tier 1 (#1)** | `zstd` level 3 | Pages idle >= 30 mins, max 256 MiB/pass | Fast secondary compaction for dormant allocations |
| **Tier 2 (#2)** | `zstd` level 9 | Pages idle >= 3 hours, max 128 MiB/pass | High-ratio compaction for sustained background heaps |
| **Tier 3 (#3)** | `zstd` level 15 | Pages idle >= 12 hours, max 64 MiB/pass | Deep cold-page compression for maximum RAM density |
| **Writeback** | Dedicated raw NVMe partition | Resident ratio >= 70-85%, guarded 256 MiB | Relieves physical RAM pressure while wear-capped |

### Kernel ABI Compatibility & Pre-Initialization

`zram-generator 1.2.1` does not program secondary compression levels correctly (it passes supplemental arguments to `recompress`, triggering kernel `EINVAL`). `vmatlas-zram-kit` resolves this by writing secondary algorithm parameters directly to `/sys/block/zram0/algorithm_params` before initialization (`initstate=0`) via a systemd pre-setup hook, verifying the device post-initialization and publishing `/run/vmatlas-tier/levels`.

---

## Interactive Installation & Setup

Inspired by modern terminal setup tools (such as `dots-hyprland` and `osu-wine`), the installer provides both a guided interactive TUI and fully scriptable CLI flags.

```bash
git clone https://github.com/gustarmartins/vmatlas-zram-kit.git
cd vmatlas-zram-kit
./install.sh
```

### Key Installer Features:

1. **Interactive Sizing Picker**:
   - **Workstation & Dev Baseline (Recommended for 16GB)**: `ram * 2.25` virtual ZRAM (~36 GiB on 16GB RAM), resident limit `ram / 1.6` (~10 GiB RAM cap), swap priority 90.
   - **Aggressive / Build Storm**: `ram * 2.50` virtual ZRAM (~40 GiB), resident limit `ram / 1.5` (~10.6 GiB cap).
   - **Balanced Standard**: `ram * 2.00` virtual ZRAM (~32 GiB), resident limit `ram / 2.0` (~8.0 GiB cap).
   - **Safe Conservative**: `min(ram * 2, 32 GiB)`, resident limit `ram / 2`.
   - **Custom Expression**: Specify your own formulas.

2. **Compression Pipeline Selection**:
   - 4-Stage Hierarchy (LZ4 -> ZSTD:3 -> ZSTD:9 -> ZSTD:15)
   - 3-Stage Hierarchy (LZ4 -> ZSTD:3 -> ZSTD:9)
   - Single-Stage ZSTD (ZSTD:3)
   - Custom parameters

3. **Best-Effort Guided NVMe Writeback Wizard**:
   - Automatically scans partitions and discovers candidate SSD/NVMe partitions.
   - **GPT Partition Type Correction**: Warns if the partition is typed as Linux Swap (which causes `systemd-gpt-auto-generator` to hijack it as conflicting raw swap) and safely retypes it to **Generic Linux Data** (`0fc63daf-8483-4772-8e79-3d69d8477de4`) leaving boundaries and partition layout intact.
   - Checks for filesystem signatures and safely wipes them upon confirmation.
   - Uses stable `/dev/disk/by-partuuid/...` identifiers.

4. **16GB Workstation Baseline VM Knobs**:
   - `vm.swappiness = 142`
   - `vm.vfs_cache_pressure = 68`
   - `vm.min_free_kbytes = 131072` (128 MiB)
   - `vm.watermark_scale_factor = 92`
   - `vm.watermark_boost_factor = 16155`
   - `vm.page-cluster = 0` (Zero disk readahead latency for ZRAM)
   - `vm.compaction_proactiveness = 0` (Prevents background compaction micro-stutters)
   - `vm.compact_unevictable_allowed = 1`
   - `vm.zone_reclaim_mode = 0`
   - `vm.dirty_bytes = 1342177280` (~1.25 GiB foreground buffer)
   - `vm.dirty_background_bytes = 78643200` (~75 MiB background flush threshold)
   - `vm.dirty_writeback_centisecs = 150` (1.5s background interval)
   - `vm.dirty_expire_centisecs = 1000` (10s expire interval)
   - `vm.extfrag_threshold = 250`
   - `vm.max_map_count = 1048576`
   - `mglru_enabled = 0x0007`, `mglru_min_ttl_ms = 2000`

5. **Live Restart & Verification**:
   - Rebuilds and verifies the live ZRAM device, secondary tiers, writeback locks, and VM sysctls without rebooting.

---

## CLI Management & Telemetry (`vmatlas-zram`)

The kit includes a unified command-line tool `vmatlas-zram` for operational control, health verification, and diagnostics:

```bash
# Check live memory hierarchy, compression ratios, and writeback state
vmatlas-zram status

# Run system diagnostic and preflight integrity check
vmatlas-zram doctor

# Trigger manual tier recompression
sudo vmatlas-zram recompress tier1
sudo vmatlas-zram recompress tier2
sudo vmatlas-zram recompress tier3
sudo vmatlas-zram recompress all

# Trigger guarded NVMe writeback pass
sudo vmatlas-zram writeback cold
sudo vmatlas-zram writeback emergency

# Live restart & rebuild the stack without rebooting
sudo vmatlas-zram restart
sudo vmatlas-zram restart --force

# Compact physical memory and ZRAM allocator pools
sudo vmatlas-zram compact

# Drop clean caches safely
sudo vmatlas-zram drop-caches

# Scoped memory inspection or pageout for a specific target process
vmatlas-zram process inspect <PID>
vmatlas-zram process pageout <PID> --dry-run
```

---

## Unattended / Scriptable Installation

For automated deployment, pass arguments directly:

```bash
./install.sh --non-interactive \
  --size "ram * 2.25" \
  --resident-limit "ram / 1.6" \
  --tiers 4 \
  --writeback-device "/dev/disk/by-partuuid/01767f33-8e7e-4ef7-ac65-0e63f34836e5" \
  --confirm-writeback-device \
  --retype-swap-partition \
  --live-restart
```

---

## Uninstallation

To cleanly remove all kit drop-ins, services, and configuration files:

```bash
sudo ./uninstall.sh
```

---

## Documentation

- [Profiles and Scaled Knobs](docs/PROFILES.md)
- [Operational Controls & Process Helper](docs/OPERATIONS.md)
- [Writeback Architecture & Wear Budgets](docs/WRITEBACK.md)
- [Safety Boundaries & Design Rules](docs/SAFETY.md)
- [Validation & Verification](docs/VALIDATION.md)
- [Real-World Workstation Snapshot](docs/REAL-WORLD-SNAPSHOT.md)
- [Frequently Asked Questions (FAQ)](docs/FAQ.md)
- [Kernel & Generator References](docs/REFERENCES.md)

## License

MIT License. See [LICENSE](LICENSE).
