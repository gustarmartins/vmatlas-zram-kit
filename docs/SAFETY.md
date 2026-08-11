# Safety model

## Supported baseline

The supported baseline is Linux with systemd as PID 1 and the upstream `zram-generator` installed. Arch packages it as `zram-generator`; Fedora includes the same generator (and may also provide distribution defaults). On other distributions, install the package that provides `zram-generator` and its `systemd-zram-setup@.service` before running this kit.

The kit intentionally does not run a package manager: installing or changing repositories is a distribution-administration decision, not a hidden side effect of a memory profile.

## What `install.sh` will refuse

- A non-systemd host or a missing `zram-generator`.
- A local `/etc` or `/run` ZRAM-generator configuration that is not already owned by this kit, unless `--adopt-local-zram-config` is supplied deliberately.
- The tiered profile until the running kernel proves `recomp_algorithm`, `recompress`, and `algorithm_params` support.
- A writeback path that is not a dedicated partition, has a filesystem/signature, is mounted, or is active swap.
- Writeback without `--confirm-writeback-device`.

Vendor defaults under `/usr/lib` are expected and can be overridden by the kit's late `/etc/.../90-vmatlas-zram.conf` drop-in. The installer refuses administrator-owned local configuration because its intent cannot be inferred safely.

## Staging instead of live reset

ZRAM compression algorithms, device size, and backing devices belong to its initialization sequence. Resetting an active swap device would require `swapoff`, a reset, formatting, and reactivation—unsafe under memory pressure. This kit only writes next-boot configuration and enables boot units. It never starts the generated ZRAM unit itself.

`systemctl daemon-reload` only reloads unit metadata needed for the installed MGLRU/timer units; it does not start or reset ZRAM. Reboot remains explicit.

## Portable derivative of the source profile

The source machine has 16 GiB RAM, a Zen kernel, a dedicated raw NVMe partition, and iterative local experiments. Its saved `retained-stability` profile is the baseline, not every live experimental adjustment. The public defaults retain the defensible parts—zstd-first swap, bounded dirty writes, cache retention, and no proactive compaction—then scale RAM-sensitive reservations and dirty caps.

This is why the default does not assume a disk model, a RAM frequency, a GPU, Btrfs, a loop device, or a separate disk swap file.
