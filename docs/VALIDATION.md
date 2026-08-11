# Validation after reboot

Run these after the explicit reboot:

```bash
vmatlas-zram preflight
vmatlas-zram status
swapon --show
zramctl
systemctl --no-pager status systemd-zram-setup@zram0.service vmatlas-zram-mglru.service
```

For the safe profile, confirm that `/dev/zram0` is active, zstd is selected, the expected sysctls appear in `vmatlas-zram status`, and no unexpected disk swap was removed.

For tiered ZRAM, the status output must show a secondary compressor before you use a manual recompression action. For writeback, first confirm the expected backing device and that writeback is `locked`; then run one manual cold pass while the machine is genuinely idle and inspect the `bd_stat` delta.

Evaluate with a normal Android workflow: clean/assemble builds, the emulator, your browser load, and a return to idle. PSI, actual compression ratio, interactive latency, writeback deltas, and OOM records are more informative than an assumed universal setting.
