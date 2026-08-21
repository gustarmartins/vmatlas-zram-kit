# Operational Controls & CLI Reference

`vmatlas-zram-kit` provides comprehensive diagnostic, maintenance, and fine-grained memory management commands via `vmatlas-zram`.

---

## 1. System Telemetry & Diagnostics

```bash
# Check complete multi-tier memory state, compression density, and writeback status
vmatlas-zram status

# Run system diagnostic and preflight integrity checks
vmatlas-zram doctor
```

---

## 2. Recompression Controls

The multi-tier engine supports manual passes across each priority layer. Operations run with an advisory mutex lock (`/run/lock/vmatlas-zram-tier.lock`). When system PSI pressure is elevated, the tool issues an informative warning and continues execution as requested.

```bash
# Recompress Tier 1 (Priority 1: ZSTD level 3, pages idle >= 30m)
sudo vmatlas-zram recompress tier1

# Recompress Tier 2 (Priority 2: ZSTD level 9, pages idle >= 3h)
sudo vmatlas-zram recompress tier2

# Recompress Tier 3 (Priority 3: ZSTD level 15, pages idle >= 12h)
sudo vmatlas-zram recompress tier3

# Recompress all eligible pages across the secondary compressor
sudo vmatlas-zram recompress all

# Recompress uncompressible / huge pages
sudo vmatlas-zram recompress huge
```

---

## 3. NVMe Writeback Controls

```bash
# Execute guarded cold writeback pass (256 MiB burst, automatically relocked to 0)
sudo vmatlas-zram writeback cold

# Execute writeback on huge (uncompressible) objects
sudo vmatlas-zram writeback huge

# Execute emergency writeback burst (1024 MiB cap)
sudo vmatlas-zram writeback emergency
```

---

## 4. Live Stack Rebuild & Teardown

If you modify sysctls, tier levels, or sizing and wish to apply changes immediately without a machine reboot:

```bash
# Live teardown, recreate ZRAM, re-apply algorithm_params, and verify stack
sudo vmatlas-zram restart

# Bypass memory headroom check (SwapUsed vs MemAvailable) during high memory usage
sudo vmatlas-zram restart --force
```

---

## 5. Memory Compaction & Cache Management

```bash
# Compact physical RAM and ZRAM allocator pools
sudo vmatlas-zram compact

# Safely drop clean page caches, dentries, and inodes
sudo vmatlas-zram drop-caches
```

---

## 6. Process-Scoped Residency Helper

Fine-grained memory control for individual processes (e.g. idle Android emulator, heavy browser tabs):

```bash
PID=12345

# Inspect memory footprint and swap residency for a PID
vmatlas-zram process inspect "$PID"

# Dry-run pageout
vmatlas-zram process pageout "$PID" --dry-run

# Request MADV_PAGEOUT for anonymous memory of caller-owned PID
vmatlas-zram process pageout "$PID"

# Fault in swapped pages for a caller-owned PID
vmatlas-zram process warm "$PID"
```
