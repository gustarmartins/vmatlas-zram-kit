# Profiles

| Profile | Intended use | ZRAM shape | Preconditions |
| --- | --- | --- | --- |
| `android-dev-safe` | Default Android development workstation | zstd level 3, no writeback | systemd + zram-generator |
| `android-dev-tiered` | Manual cold-page recompression experiments | zstd level 3 + zstd level 12 secondary | live multi-compressor proof after a safe boot |
| `android-dev-tiered-writeback` | Explicitly provisioned NVMe last tier | tiered ZRAM + raw writeback partition | empty dedicated partition and explicit confirmation |

All profiles retain any pre-existing ordinary disk swap. They do not claim that one machine's swap pressure, storage latency, or compression ratio will transfer to another.

## Host-scaled settings

`install.sh` renders the default as follows:

| Host RAM | `min_free_kbytes` | dirty background / foreground | MGLRU TTL |
| --- | ---: | ---: | ---: |
| <= 8 GiB | 64 MiB | 32 / 128 MiB | 1000 ms |
| 9–32 GiB | 128 MiB | 64 / 256 MiB | 2000 ms |
| > 32 GiB | 128 MiB | 128 / 512 MiB | 2000 ms |

The ZRAM virtual device is `min(ram * 2, 32 GiB)` with a resident limit of `ram / 2`; these values mirror the source machine at 16 GiB without creating an unbounded virtual device on high-RAM workstations.

MGLRU is applied only if `/sys/kernel/mm/lru_gen/{enabled,min_ttl_ms}` exists. The source's untracked 3000 ms live TTL is intentionally not exported: upstream warns that 3000 ms can produce premature OOM kills.
