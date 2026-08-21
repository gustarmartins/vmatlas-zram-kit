# Safety and support

## Supported setup

This kit needs systemd as PID 1 and `zram-generator`. On Arch, install `zram-generator`. On another systemd distribution, install the package that provides `zram-generator` and `systemd-zram-setup@.service`.

The installer does not run a package manager.

## What the installer refuses

- No systemd or no `zram-generator`.
- Existing local ZRAM-generator configuration, unless you pass `--adopt-local-zram-config`.
- `--tiered` before the running kernel exposes `recomp_algorithm`, `recompress`, and `algorithm_params`.
- A writeback device outside `/dev/disk/by-*`, a whole disk, a mounted partition, a filesystem/signature, or active swap.
- Writeback without `--confirm-writeback-device`.

`--adopt-local-zram-config` is deliberate. Read the existing configuration first; this kit cannot know whether it is safe to replace.

## What install and uninstall change

`install.sh` writes `/etc` drop-ins and enables the MGLRU unit for the next boot. It does not start the generated ZRAM service, reset the current device, or call `swapoff`.

`uninstall.sh` removes only files marked as owned by this kit. It does not touch the current ZRAM device, active swap, or the backing partition. Reboot when you are ready to switch configurations.

## Writeback and process actions

Writeback is off by default. When configured, it uses one dedicated raw partition, a capped allowance, and relocks the allowance to zero after every pass. The forced command skips only page-age and PSI checks.

The process helper works on one process owned by the invoking user. Its force form skips the RAM, PSI, and target-size checks only. It still checks identity and ownership. Global `swapoff`, all-process pageout, and all-process warm are intentionally not part of the project.
