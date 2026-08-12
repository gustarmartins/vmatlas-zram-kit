# Optional manual operations

These are intentional, operator-run actions for a machine that has already booted the safe profile and passed `vmatlas-zram preflight`. They are not background tuning, a replacement for normal Linux reclaim, or a way to force a machine through active thrash.

Start every session with a read-only check:

```bash
vmatlas-zram status
vmatlas-zram preflight
```

## What each action is allowed to do

| Action | Normal command | Built-in boundary | Force/bypass syntax | Important limit |
| --- | --- | --- | --- | --- |
| Inspect one process | `vmatlas-zram process inspect PID` | Read-only; only accepts a caller-owned live PID | None | Mapping RSS/Swap is an estimate, not page-level proof |
| Page out one process | `vmatlas-zram process pageout PID` | One caller-owned PID; active swap; at least `max(1 GiB, RAM/8)` available; memory PSI below 15% `some` and 2% `full`; target RSS at most `min(2 GiB, max(512 MiB, RAM/4))` | `--force --confirm-pid PID` | `MADV_PAGEOUT` is advice. Accepted virtual bytes do not prove ZRAM writes or reclaimed RAM. |
| Warm one process | `vmatlas-zram process warm PID` | Same gates; additionally requires available RAM for target swap plus reserve; reads only PTEs reported as swapped | `--force --confirm-pid PID` | Can increase RSS and cause I/O; it is never an all-process unswap. |
| Recompress ZRAM data | `sudo vmatlas-zram recompress idle` | Requires kernel recompression ABI, configured secondary compressor, and quiet memory/I/O PSI | `--force CONFIRM-FORCE-RECOMPRESS` | Can consume CPU; use `idle` first and do not run `all` in the middle of a latency-sensitive build. |
| Cold-page writeback | `sudo vmatlas-zram writeback cold` | Exact provisioned raw partition; 24-hour idle marking; memory PSI below 5%/2% and I/O PSI below 10%/2%; 256 MiB pass; 4 GiB boot write-I/O cap; relocks budget afterward | None | Backing I/O wears storage and can add latency. |
| Forced writeback | `sudo vmatlas-zram writeback force CONFIRM-FORCE-WRITEBACK` | Same exact raw-partition verification, aggregate boot cap, and automatic relock | Confirmation only bypasses the quiet-PSI check and cold-age marking | Still capped to 1 GiB per run and cannot target a generic disk, file, mounted filesystem, or active swap. |

All changing process actions prompt for `sudo` themselves when needed. Use the same commands with `--dry-run` first:

```bash
vmatlas-zram process pageout PID --dry-run
vmatlas-zram process warm PID --dry-run
```

## Target-scoped pageout (the safe replacement for “force swap”)

Use this only when a process you own is intentionally backgrounded and you have inspected it first. Typical examples are an idle emulator or an IDE instance you deliberately want to make cold before a one-off build.

```bash
PID=12345                         # replace with a live PID that you own
vmatlas-zram process inspect "$PID"
vmatlas-zram process pageout "$PID" --dry-run
vmatlas-zram process pageout "$PID"
```

The helper records the PID start time, UID, and command name, then checks again before every advice batch. It limits the advice to anonymous mappings, refuses PID 1, itself, a PID that has been reused, and a process that belongs to another user. The kernel interface is `process_madvise(..., MADV_PAGEOUT)`, so individual mappings can be ignored or partially accepted by the kernel.

### Deliberate safety-gate bypass

Only use this after the dry run and only for the same PID you just inspected:

```bash
vmatlas-zram process pageout "$PID" --force --confirm-pid "$PID"
```

`--force` skips the RAM-headroom, PSI, and per-target-size gates. It does **not** skip live-PID identity validation, the caller-UID boundary, or the single-PID scope. It can make an already pressured desktop less responsive; it is an escape hatch, not an Android-build default.

## Target-scoped warm (the safe replacement for “unswap”)

Warming faults in only virtual pages whose pagemap entry is marked swapped. It does not read every mapped byte and it never executes `swapoff`.

```bash
PID=12345                         # replace with a live PID that you own
vmatlas-zram process warm "$PID" --dry-run
vmatlas-zram process warm "$PID"
```

If you explicitly override the guardrails, repeat the exact PID:

```bash
vmatlas-zram process warm "$PID" --force --confirm-pid "$PID"
```

Force mode can fault in far more memory than is currently available. It may immediately trigger reclaim, refaults, or an OOM event. Stop and recover normally if PSI rises; do not respond by escalating to a global swap drain.

## Recompression

The source profile's optional tiered configuration adds a slower zstd compressor. After the running kernel proves multi-compressor support and you install with `--tiered`, choose the smallest useful action:

```bash
sudo vmatlas-zram recompress idle       # pages idle for at least one hour
sudo vmatlas-zram recompress huge-idle  # idle huge ZRAM objects
sudo vmatlas-zram recompress huge       # huge ZRAM objects
sudo vmatlas-zram recompress all        # entire current ZRAM population
```

Recompression changes compressed storage format; it does not unswap a process or create a promise of lower RAM use. Normal operation requires memory PSI below 5%/2% and I/O PSI below 10%/2%. Prefer `idle`, compare `vmatlas-zram status` before and after, and reserve `all` for a quiet, observed machine.

If you deliberately override the quiet-PSI gate, use the literal confirmation after inspecting status:

```bash
sudo vmatlas-zram recompress idle --force CONFIRM-FORCE-RECOMPRESS
```

This bypass only skips the PSI check; it does not make an unsupported kernel ABI or absent second compressor usable.

## Cold and forced writeback

Writeback exists only if a dedicated, empty, unmounted raw partition was deliberately supplied at install time. It remains unavailable on a standard safe-profile install.

```bash
# Lowest-risk writeback: only after 24 hours of page idleness and low PSI.
sudo vmatlas-zram writeback cold

# Emergency only: ignores current pressure and writes all pages marked idle,
# but preserves device checks, a 1 GiB per-run cap, the 4 GiB boot cap, and relocking.
sudo vmatlas-zram writeback force CONFIRM-FORCE-WRITEBACK
```

The legacy spelling `writeback emergency CONFIRM-EMERGENCY-WRITEBACK` is equivalent to `force` and kept for clarity with earlier documentation. Neither command formats, repartitions, wipes, or mounts the device. See [WRITEBACK.md](WRITEBACK.md) for provisioning and accounting semantics.

## Intentionally absent: global `swapoff` and all-process “unswap”

This kit never runs `swapoff`, does not page out every process, and does not include a bypass to do either. Moving all swapped pages into RAM at once is exactly the operation most likely to worsen active memory pressure or produce an OOM. If a machine is thrashing, reduce the workload, allow normal reclaim, or reboot at a safe time; do not turn an optional maintenance tool into a whole-machine memory migration.
