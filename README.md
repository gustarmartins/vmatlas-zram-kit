# vmatlas-zram-kit

An evidence-led, conservative ZRAM profile kit for Linux desktops used for Android development: Gradle builds, emulators, browsers, IDEs, and everything else that shares the machine.

It is based on a long-running Linux Zen workstation profile, but is deliberately **not** a blind hardware clone. The default adapts its RAM reserve and dirty-write caps to the host, never assumes a particular SSD, and stages ZRAM changes for the next boot rather than resetting live swap.

## Why an Android developer would use this

Android workstations are unusually good at making memory pressure feel random: a Gradle daemon, IDE indexes, an emulator, browser tabs, Logcat, and a build can all be useful at once. This kit gives Linux a deliberate, inspectable place to keep colder anonymous pages before the only alternative is killing work or relying on an unexamined swap setup.

- A portable, next-boot ZRAM baseline that scales its RAM-sensitive settings instead of copying one 16 GiB workstation verbatim.
- Live status that separates logical data in ZRAM, compressed payload, allocator RAM use, and optional backing-store accounting.
- Optional, explicit maintenance actions: recompress cold ZRAM data, write back cold pages to a dedicated raw partition, or page out/warm one of **your own** processes. Nothing runs automatically by default.
- A safety model that refuses active local ZRAM configuration, live ZRAM resets, generic disks, global `swapoff`, unattended writeback, and cross-user process targeting.

The source machine's actual two-day-uptime snapshot is published as a reproducible measurement, not a benchmark: [real-world snapshot](docs/REAL-WORLD-SNAPSHOT.md). It stored 13.87 GiB of logical swap data using 4.38 GiB of ZRAM allocator memory (3.17x effective footprint reduction), while 3.79 GiB of cold pages were on an explicitly provisioned backing device.

## What it installs

```
vmatlas-zram-kit/
├── profiles/                 # Documented profile definitions
├── bin/vmatlas-zram          # Status, preflight, manual recompression/writeback
├── libexec/                  # Boot-time MGLRU + target-scoped process helpers
├── systemd/                  # Optional boot/timer units
├── docs/                     # Evidence, safety model, operations, profiles, validation
├── tests/                    # Offline shell checks
├── install.sh                # Stages one profile for the next boot
└── uninstall.sh              # Removes only files owned by this kit
```

The normal install creates only these managed paths:

```
/etc/systemd/zram-generator.conf.d/90-vmatlas-zram.conf
/etc/sysctl.d/90-vmatlas-zram.conf
/etc/vmatlas-zram/
/etc/systemd/system/vmatlas-zram-mglru.service
/usr/local/bin/vmatlas-zram
/usr/local/libexec/vmatlas-zram-mglru
/usr/local/libexec/vmatlas-zram-process
```

No daemon is enabled for the default profile. The optional cold-page writeback timer is separately requested and remains bounded.

## Quick start

This kit targets systemd-based distributions with `zram-generator`. Install that distribution package first if it is absent, then clone and run the staged installer:

```bash
git clone https://github.com/gustarmartins/vmatlas-zram-kit.git
cd vmatlas-zram-kit
./install.sh
sudo reboot
```

The installer prints the exact next-boot configuration and does **not** reset, resize, `swapoff`, or otherwise change live ZRAM. Rebooting is intentionally your decision.

Before installing, or after reboot:

```bash
./bin/vmatlas-zram preflight
vmatlas-zram status
```

For the dependency names and conflict policy, see [docs/SAFETY.md](docs/SAFETY.md). For a dry run that changes nothing, use `./install.sh --dry-run`.

## Default: Android development, safely adapted

`android-dev-safe` carries over the tested profile's intent:

| Area | Default behavior |
| --- | --- |
| ZRAM | zstd level 3, virtual size up to 2× RAM and capped at 32 GiB, resident cap of 50% RAM |
| Swap | ZRAM priority 90; existing disk swap is not removed or reprioritized |
| Reclaim | swappiness 120, VFS cache pressure 60, swap read-ahead disabled |
| Build I/O | scaled 32/128, 64/256, or 128/512 MiB background/foreground dirty caps |
| Latency | no proactive compaction, 1% kswapd watermark distance, 64–128 MiB RAM reserve |
| MGLRU | enabled only when the kernel exposes its stable ABI; TTL is 1000 ms on <=8 GiB RAM and 2000 ms otherwise |

The settings which used to be fixed at 16 GiB are calculated per host during install. This keeps the profile useful on 8, 16, 32, or 64 GiB systems without pretending memory frequency, CPU speed, and storage latency are interchangeable.

## Advanced features are opt-in

The source workstation also uses a second zstd compressor and a dedicated raw-NVMe writeback partition. Those features are included, but neither is a default:

```bash
# After the safe profile has booted and preflight proves multi-compressor support.
./install.sh --tiered

# Only for a dedicated, empty, unmounted partition that you chose yourself.
./install.sh --writeback-device /dev/disk/by-partuuid/REPLACE-ME \
  --confirm-writeback-device

# Explicitly enable the hourly, 24h-idle, 256 MiB writeback pass.
./install.sh --writeback-device /dev/disk/by-partuuid/REPLACE-ME \
  --confirm-writeback-device --enable-cold-writeback-timer
```

Writeback never receives a generic disk path, a loop file, a mounted filesystem, or an active swap device. It is locked at zero budget between passes. Read [docs/WRITEBACK.md](docs/WRITEBACK.md) before enabling it.

Manual recompression remains available where the kernel supports it:

```bash
sudo vmatlas-zram recompress idle
sudo vmatlas-zram recompress huge-idle
sudo vmatlas-zram recompress huge
sudo vmatlas-zram recompress all

# Explicitly bypass the quiet-PSI gate only after status/PSI review.
sudo vmatlas-zram recompress idle --force CONFIRM-FORCE-RECOMPRESS
```

## Optional manual residency controls

For the times you know exactly which of *your* processes should yield memory or become warm again, the kit has target-scoped helpers. They are not global swap controls and do not replace a normal kernel reclaim policy.

```bash
# Inspect first. Both commands below are read-only previews.
vmatlas-zram process inspect PID
vmatlas-zram process pageout PID --dry-run
vmatlas-zram process warm PID --dry-run

# Run only after checking the preview. The helper requests sudo itself.
vmatlas-zram process pageout PID
vmatlas-zram process warm PID
```

`pageout` uses the kernel's `process_madvise(MADV_PAGEOUT)` for that one process's anonymous mappings; `warm` reads only pages that pagemap reports as swapped. Default safeguards require active swap, memory headroom, low memory PSI, a bounded target, and the same caller UID. The explicit bypass syntax, limitations, and all writeback/recompression controls are in [docs/OPERATIONS.md](docs/OPERATIONS.md).

## Project principles

- No live swap reset or automatic reboot.
- No deletion, partitioning, formatting, or disk-swap removal.
- Existing local ZRAM configuration is a stop condition, not something silently overridden.
- Kernel capabilities are probed; unavailable features fail closed.
- Writeback is a dedicated-partition feature, budgeted in 4 KiB pages and relocked after every pass.
- Process pageout/warm is single-PID, caller-owned, previewable, and deliberately never a whole-machine `swapoff` substitute.
- Profiles are data and documentation first, so future variants can add no-writeback, disk-swap, compression, or recompression combinations without rewriting the safety model.

## Why this is not a universal performance claim

ZRAM is compressed RAM, not extra physical memory. Its useful size, compression ratio, CPU cost, and the point where swap becomes unpleasant depend on the workload and machine. A 16 GiB payload taking 1 GiB of ZRAM memory would need at least a 16:1 effective ratio; that is not this project's claim and must be measured on the workload in question. Treat this as a reproducible starting point for Android development, validate it with your normal builds, and keep the rollback command handy:

```bash
sudo ./uninstall.sh
# Then reboot when convenient; the current live ZRAM is intentionally untouched.
```

## License

MIT. See [LICENSE](LICENSE).
