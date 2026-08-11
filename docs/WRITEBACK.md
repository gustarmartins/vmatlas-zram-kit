# Optional ZRAM writeback

Writeback is not ordinary disk swap. ZRAM writes selected pages to a block-device backing store while keeping ZRAM as the primary swap device. It is useful only when you deliberately reserve a raw partition for it and understand that writes consume flash endurance and can add I/O latency.

## Provisioning rule

Pass a stable `/dev/disk/by-*` path to an **empty, unmounted partition used for nothing else**. The installer read-checks partition type, signatures, mounts, and active swap, but it never creates, formats, wipes, shrinks, or chooses a partition.

```bash
./install.sh --writeback-device /dev/disk/by-partuuid/REPLACE-ME \
  --confirm-writeback-device
```

The partition reference is recorded only in the local `/etc/vmatlas-zram/writeback.env`; it is never part of this repository.

## Budget model

Kernel `writeback_limit` is a remaining count of 4 KiB write-I/O pages, not a data-capacity measure. The kit uses a 256 MiB cold-page allowance per manual/timer pass and a 4 GiB aggregate cap based on `bd_stat` writes since the current ZRAM reset. It then immediately sets the allowance back to zero while keeping enforcement enabled.

The optional timer only considers pages idle for 24 hours, runs no more than hourly, and starts disabled. Enable it only after observing manual runs:

```bash
sudo vmatlas-zram writeback cold
vmatlas-zram status
sudo systemctl enable --now vmatlas-zram-writeback.timer
```

An emergency command is deliberately capped at 1 GiB and requires a literal confirmation token. It is not a global `swapoff`, not a full backing-store drain, and does not bypass the dedicated-partition requirement.

## Rollback

Run `sudo ./uninstall.sh` and reboot when ready. Do not remove or repurpose the backing partition while the current boot still uses it. The uninstaller does not reset live ZRAM or alter active swap.
