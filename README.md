# vmatlas-zram-kit

A ZRAM profile kit for Linux desktops running Android development workloads: Gradle, emulators, browsers, IDEs — everything fighting for RAM at once.

## What you get

| Feature | What it does |
| --- | --- |
| ZRAM swap | zstd-compressed RAM swap, scaled to your host |
| VM tuning | swappiness, dirty-write caps, cache pressure — tuned for build I/O |
| MGLRU | Multi-gen LRU for smarter page reclaim (if your kernel supports it) |
| Tiered recompression | Cold ZRAM pages re-compressed with deeper zstd for better ratios |
| Writeback | Cold pages offloaded to a dedicated raw partition on your NVMe |

Each feature is **individually opt-in** during install. The installer shows your current system state and asks Y/N for every step.

## Quick start

Requires: systemd, `zram-generator` (install via your package manager first).

```bash
git clone https://github.com/gustarmartins/vmatlas-zram-kit.git
cd vmatlas-zram-kit
./install.sh
```

The installer walks you through each step interactively. To auto-accept defaults:

```bash
./install.sh -y
```

To apply immediately without rebooting:

```bash
./install.sh --apply-now
```

## Full profile: tiered compression + writeback

This is the end-goal for maximum benefit on Android builds — deeper ZRAM compression for cold pages and NVMe-backed writeback for the coldest ones.

### Step 1: Install the base profile

```bash
./install.sh
```

Reboot (or use `--apply-now`), then verify:

```bash
vmatlas-zram status
vmatlas-zram preflight
```

### Step 2: Enable tiered compression

After one successful boot, the installer can verify your kernel supports multi-compressor ZRAM:

```bash
./install.sh --tiered
```

This adds a zstd level 12 secondary compressor for idle-page recompression.

### Step 3: Enable writeback

You need a **dedicated, empty, unmounted raw partition** (typically on your NVMe). Find it:

```bash
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS,TYPE
```

Pick a partition that shows no FSTYPE and no MOUNTPOINTS. Use its stable path:

```bash
ls -la /dev/disk/by-partuuid/
```

Then install with writeback:

```bash
./install.sh --tiered \
  --writeback-device /dev/disk/by-partuuid/YOUR-PARTUUID \
  --confirm-writeback-device
```

The installer validates the device is safe (empty, unmounted, not active swap, no filesystem). It will reject anything risky.

### Step 4 (optional): Enable automatic cold-page writeback timer

By default writeback is manual. To enable hourly automated passes for pages idle > 24 hours:

```bash
./install.sh --tiered \
  --writeback-device /dev/disk/by-partuuid/YOUR-PARTUUID \
  --confirm-writeback-device \
  --enable-cold-writeback-timer
```

### Using recompression and writeback after install

```bash
# Check status anytime
vmatlas-zram status

# Manual recompression (requires tiered profile)
sudo vmatlas-zram recompress idle

# Manual cold-page writeback (requires writeback device)
sudo vmatlas-zram writeback cold
```

## Profiles

| Profile | Compression | Writeback | Use case |
| --- | --- | --- | --- |
| `android-dev-safe` | zstd level 3 | off | Default baseline |
| `android-dev-tiered` | zstd 3 + zstd 12 | off | + idle recompression |
| `android-dev-tiered-writeback` | zstd 3 + zstd 12 | dedicated partition | Full profile |

All profiles scale automatically to your host RAM:

| Host RAM | RAM reserve | Dirty bg/fg | MGLRU TTL |
| --- | ---: | ---: | ---: |
| ≤ 8 GiB | 64 MiB | 32 / 128 MiB | 1000 ms |
| 9–32 GiB | 128 MiB | 64 / 256 MiB | 2000 ms |
| > 32 GiB | 128 MiB | 128 / 512 MiB | 2000 ms |

ZRAM virtual size is `min(ram × 2, 32 GiB)` with a resident cap of `ram / 2`.

## Uninstall

```bash
sudo ./uninstall.sh
# Reboot when convenient
```

Removes only kit-owned files. Does not touch live ZRAM or active swap.

---

## Additional topics

### What it installs

```
/etc/systemd/zram-generator.conf.d/90-vmatlas-zram.conf
/etc/sysctl.d/90-vmatlas-zram.conf
/etc/vmatlas-zram/
/etc/systemd/system/vmatlas-zram-mglru.service
/usr/local/bin/vmatlas-zram
/usr/local/libexec/vmatlas-zram-mglru
/usr/local/libexec/vmatlas-zram-process
```

### Process memory controls

Target-scoped helpers to page out or warm individual processes you own:

```bash
vmatlas-zram process inspect PID
vmatlas-zram process pageout PID --dry-run
vmatlas-zram process pageout PID
vmatlas-zram process warm PID --dry-run
vmatlas-zram process warm PID
```

These are single-PID, caller-owned operations — not global swap controls. See [docs/OPERATIONS.md](docs/OPERATIONS.md).

### Safety model

The installer refuses unsafe conditions: missing systemd, missing zram-generator, existing unrecognized ZRAM configs, writeback to non-dedicated partitions, live ZRAM resets. It never runs `swapoff`, removes disk swap, or reboots automatically. Full details in [docs/SAFETY.md](docs/SAFETY.md).

### Dry run

Preview everything without changing your system:

```bash
./install.sh --dry-run
./install.sh --tiered --dry-run
```

### Real-world data

The source machine's two-day snapshot: 13.87 GiB stored in ZRAM using 4.38 GiB RAM (3.17× reduction), with 3.79 GiB on a dedicated NVMe backing device. See [docs/REAL-WORLD-SNAPSHOT.md](docs/REAL-WORLD-SNAPSHOT.md).

### Why ZRAM is not magic

ZRAM is compressed RAM, not extra physical memory. Compression ratios, CPU cost, and the point where swap becomes painful depend on your workload and machine. Treat this as a tested starting point, validate with your builds, and keep the rollback command handy.

## License

MIT. See [LICENSE](LICENSE).
