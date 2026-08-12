# References and design inputs

- [Linux kernel: ZRAM](https://docs.kernel.org/admin-guide/blockdev/zram.html) documents ZRAM initialization, multi-compressor recompression, idle-page tracking, `writeback_limit`, and `bd_stat` accounting.
- [zram-generator configuration](https://github.com/systemd/zram-generator/blob/main/man/zram-generator.conf.md) documents generator precedence, RAM expressions, multiple compression algorithms, resident limits, and block-device writeback configuration.
- [Linux VM sysctls](https://docs.kernel.org/admin-guide/sysctl/vm.html) explains swappiness values over 100 for in-memory swap, paired dirty-byte/ratio controls, swap read-ahead, cache pressure, and watermark behavior.
- [Linux MGLRU](https://docs.kernel.org/admin-guide/mm/multigen_lru.html) documents `enabled` and `min_ttl_ms`, including the increased premature-OOM risk around a 3000 ms TTL.
- [`madvise(2)`](https://man7.org/linux/man-pages/man2/madvise.2.html) documents `MADV_PAGEOUT`: it can reclaim anonymous pages through swap, may write dirty file-backed pages, and remains advice that the kernel may ignore.
- [`process_madvise(2)`](https://man7.org/linux/man-pages/man2/process_madvise.2.html) documents PID-file-descriptor-based advice for a target process, including the permission and capability requirements for another process.
- [Linux pagemap](https://docs.kernel.org/admin-guide/mm/pagemap.html) documents the per-page swapped/present flags used by the target-scoped warm action.
- [Fedora's zram design](https://fedoraproject.org/wiki/Changes/SwapOnZRAM) is a useful conservative reference: ZRAM memory is allocated on demand, compression does not create free physical memory, and distribution defaults stay much smaller than the source workstation profile.

The kit uses these interfaces directly and avoids copied scripts that hard-code one workstation's partition UUID, GPU path, Btrfs layout, or desktop notification user.
