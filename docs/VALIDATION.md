# After reboot

```bash
vmatlas-zram preflight
vmatlas-zram status
swapon --show
zramctl
systemctl --no-pager status systemd-zram-setup@zram0.service vmatlas-zram-mglru.service
```

Check that `/dev/zram0` is active, zstd is selected, the expected VM values appear in `vmatlas-zram status`, and existing disk swap remains present.

For tiered ZRAM, confirm the secondary compressor before running recompression. For writeback, confirm the expected backing device and locked allowance before one manual cold pass. Inspect the `bd_stat` delta afterward.

Then use the machine normally: clean/assemble builds, emulator, browser load, and idle. Watch PSI, compression ratio, responsiveness, writeback deltas, and OOM records. Those results matter more than matching another machine's settings.
