# Measured ZRAM snapshot

Captured on the Linux Zen machine that supplied this profile: 2026-08-12, 2 days 2 minutes uptime, 15.53 GiB RAM. Memory and I/O PSI `avg10` were 0.00% at capture.

| Metric | Value | Read from |
| --- | ---: | --- |
| ZRAM virtual size | 31.06 GiB | `disksize` |
| Logical data in ZRAM | 13.87 GiB | `mm_stat` `orig_data_size` |
| Compressed payload | 4.28 GiB | `mm_stat` `compr_data_size` |
| ZRAM allocator memory | 4.38 GiB | `mm_stat` `mem_used_total` |
| Logical-data / allocator-memory ratio | **3.17x** | `orig_data_size / mem_used_total` |
| Pages currently on the backing device | 3.79 GiB | `bd_stat` `bd_count × 4096` |
| Backing writes since the ZRAM reset | 40.72 GiB | `bd_stat` `bd_writes × 4096` |

`disksize` is virtual capacity, not RAM allocated by ZRAM. `compr_data_size` is the compressed payload. `mem_used_total` is the ZRAM allocator footprint and is the useful number for the 3.17x calculation.

This is not “16 GiB compressed into 1 GiB.” That would need a 16x result. At the observed ratio, 16 GiB of similarly compressible data would take about 5.05 GiB of ZRAM allocator memory. Browser content, emulator memory, native heaps, and build data do not compress the same way.

The backing-device figures also measure different things: `bd_count` is currently backed pages; `bd_writes` is cumulative 4 KiB write I/O. Neither is the capacity of the backing partition or a flash-wear forecast.

## Check your machine

```bash
zramctl --bytes /dev/zram0
cat /sys/block/zram0/mm_stat
cat /sys/block/zram0/bd_stat
cat /proc/pressure/memory
cat /proc/pressure/io
```

See the [kernel ZRAM documentation](https://docs.kernel.org/admin-guide/blockdev/zram.html) for the ABI exposed by your kernel.
