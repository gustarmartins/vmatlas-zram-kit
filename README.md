# vmatlas-zram-kit

A conservative, inspectable ZRAM profile kit for Linux desktops used for Android development: Gradle builds, emulators, browsers, IDEs, and everything else that shares the machine.

It is based on a long-running Linux Zen workstation profile, but is deliberately **not** a blind hardware clone. The default adapts its RAM reserve and dirty-write caps to the host, never assumes a particular SSD, and stages ZRAM changes for the next boot rather than resetting live swap.

## What it installs

```
vmatlas-zram-kit/
├── profiles/                 # Documented profile definitions
├── bin/vmatlas-zram          # Status, preflight, manual recompression/writeback
├── libexec/                  # Small boot-time MGLRU helper
├── systemd/                  # Optional boot/timer units
├── docs/                     # Safety model, profiles, writeback, validation
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
```

## Project principles

- No live swap reset or automatic reboot.
- No deletion, partitioning, formatting, or disk-swap removal.
- Existing local ZRAM configuration is a stop condition, not something silently overridden.
- Kernel capabilities are probed; unavailable features fail closed.
- Writeback is a dedicated-partition feature, budgeted in 4 KiB pages and relocked after every pass.
- Profiles are data and documentation first, so future variants can add no-writeback, disk-swap, compression, or recompression combinations without rewriting the safety model.

## Why this is not a universal performance claim

ZRAM is compressed RAM, not extra physical memory. Its useful size, compression ratio, CPU cost, and the point where swap becomes unpleasant depend on the workload and machine. Treat this as a reproducible starting point for Android development, validate it with your normal builds, and keep the rollback command handy:

```bash
sudo ./uninstall.sh
# Then reboot when convenient; the current live ZRAM is intentionally untouched.
```

## License

MIT. See [LICENSE](LICENSE).
