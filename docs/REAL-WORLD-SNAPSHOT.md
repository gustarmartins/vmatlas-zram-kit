# A real source-workstation snapshot

This is the evidence behind the project's first public pitch. It is a **single live operating snapshot** from the source Linux Zen workstation on 2026-08-12, after 2 days and 2 minutes of uptime. It is not a synthetic compression test, a performance benchmark, or an installation promise for another machine.

The host had 15.53 GiB of RAM. At capture time, memory and I/O PSI `avg10` were both 0.00% for `some` and `full`.

| What was measured | Live value | Kernel source | What it means | What it does **not** mean |
| --- | ---: | --- | --- | --- |
| ZRAM virtual addressable size | 31.06 GiB | `disksize` | Maximum ZRAM swap space configured | Physical RAM allocated now |
| Logical swap data stored in ZRAM | 13.87 GiB | `mm_stat` `orig_data_size` | Uncompressed data represented in ZRAM | Total system memory use or a guaranteed compressibility level |
| Compressed payload | 4.28 GiB | `mm_stat` `compr_data_size` | Payload after compression, before allocator overhead | The whole physical ZRAM footprint |
| ZRAM allocator memory in use | 4.38 GiB | `mm_stat` `mem_used_total` | The physical memory backing this ZRAM device, including allocator metadata | One GiB, nor all RAM consumed by applications |
| Effective logical-data / ZRAM-memory ratio | **3.17x** | `orig_data_size / mem_used_total` | 13.87 GiB represented using 4.38 GiB of ZRAM memory in this workload | A universal ratio or a latency benchmark |
| Cold pages currently on backing storage | 3.79 GiB | `bd_stat` `bd_count × 4096` | Pages currently written out by ZRAM to its dedicated raw backing device | A backing-device capacity reservation or total historical writes |
| Backing write I/O since this ZRAM reset | 40.72 GiB | `bd_stat` `bd_writes × 4096` | Cumulative 4 KiB write I/O accounting | Data currently resident on disk or flash wear prediction |

## The “16 GiB into 1 GiB” check

That phrase would be a **16:1** effective footprint ratio. It is possible for exceptionally repetitive data, but it is not what this live workstation snapshot observed and should not be used as a promise in a public post.

At the observed 3.17x ratio, 16 GiB of similarly compressible logical data would use approximately **5.05 GiB** of ZRAM allocator memory. Reaching one GiB for the same 16 GiB would require a materially different workload and a measured 16x ratio. In practice, code, browser content, native heaps, emulator images, and build artifacts vary dramatically in compressibility.

The more useful result is the whole topology: RAM kept a 13.87 GiB logical ZRAM working set in a 4.38 GiB allocator footprint, and a deliberately budgeted raw backing device held 3.79 GiB of much older pages. That can preserve room for active Android-development work, but it trades CPU time and, when writeback is enabled, storage I/O for that headroom.

## Reproduce the numbers on a host

Run this while the system is in a representative state. Do not compare `disksize` with physical RAM: it is a virtual capacity.

```bash
zramctl --bytes /dev/zram0
cat /sys/block/zram0/mm_stat
cat /sys/block/zram0/bd_stat
cat /proc/pressure/memory
cat /proc/pressure/io
```

The first three `mm_stat` fields are `orig_data_size`, `compr_data_size`, and `mem_used_total`. When writeback is configured, the first `bd_stat` field is the current number of 4 KiB backing pages; its third field is cumulative backing writes. Check the [kernel ZRAM documentation](https://docs.kernel.org/admin-guide/blockdev/zram.html) for the ABI of the running kernel.

## Honest wording for public sharing

> On my 16 GiB-class Linux Zen Android workstation, after two days of uptime, ZRAM was representing 13.87 GiB of logical data in 4.38 GiB of allocator memory (3.17x), while 3.79 GiB of colder pages sat on a dedicated, budgeted backing partition. Your ratio and latency will depend on your actual workload, CPU, RAM, and storage.

This wording is specific, reproducible, and avoids conflating compression ratio, virtual swap size, RAM use, backing capacity, and write I/O.
