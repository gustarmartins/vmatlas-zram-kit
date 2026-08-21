# FAQ

## Will this make my PC slower?

Sometimes. It is a trade, not free memory.

When RAM is available and little is swapping, ZRAM has little to do. When memory gets tight, ZRAM spends CPU compressing and decompressing pages. Tiered recompression costs more CPU, and writeback adds storage I/O. On a slower CPU or SSD, or during a workload that keeps faulting the same pages back in, that can be noticeable.

The reason to use it is that the alternative is often worse: closing useful work, heavy reclaim stalls, or an OOM kill. For a desktop that stays busy all day—IDE, Gradle, emulators, browsers, terminals, and agents—a controlled compressed tier can keep more of that working set alive. It does not make a machine with unlimited RAM; it changes the failure mode when the workload outgrows physical RAM.

On the machine this profile came from, the extra memory tiers have not stopped normal gaming; Switch emulation has remained smooth at 72 fps during the author's usual long-running desktop workload. Treat that as an anecdote from one Zen/Linux/NVMe machine, not a result this project promises for yours.

If gaming or another latency-sensitive task is your priority, close heavyweight development workloads first and do not manually run `recompress all` or forced writeback while playing. Start with `android-dev-safe` (no writeback), then measure with your own work and games before enabling tiered compression or a backing partition.

## Is this meant for a laptop?

Not as the primary target. The source setup is a cooled, wall-powered desktop that can spend a sustained amount of CPU on active Android work. ZRAM compression and decompression add CPU work; tiered zstd recompression adds more; writeback adds storage I/O. On battery, that means more heat, more fan time, and less battery life exactly when the machine is already busy.

A laptop can still try `android-dev-safe`, but treat it as an experiment: stay plugged in, watch temperature and responsiveness, leave writeback off, and do not run manual recompression during a build or on battery. The tiered and writeback variants are desktop features unless you have measured your own laptop and accept their power and thermal cost.

## Is ZRAM just more RAM?

No. ZRAM stores swapped pages in compressed physical memory. It can fit some data into less RAM, but the compression ratio depends on the data and uses CPU when pages move in or out. See [REAL-WORLD-SNAPSHOT.md](REAL-WORLD-SNAPSHOT.md) for the source machine's measured 3.17x result and its limits.

## Should I enable writeback?

Only if you have an empty dedicated partition you are willing to reserve for it. Writeback can keep very old ZRAM pages out of RAM, but it creates storage traffic. The default profile leaves it off. Read [WRITEBACK.md](WRITEBACK.md) before deciding.

## Is this useful on 8 GiB, 16 GiB, or 64 GiB of RAM?

The default scales several RAM-sensitive values, so it is not limited to one capacity. That does not mean every machine should enable every feature. Smaller machines should begin with the safe profile and verify responsiveness; high-RAM machines may never need writeback. CPU speed, storage latency, and workload matter as much as the RAM number.

## Can I keep all my apps open forever?

You can keep more cold work around, not remove resource limits. A browser tab, emulator, or agent that wakes constantly is not cold and can still compete for CPU, RAM, and I/O. Use the status and PSI readings, and reduce the workload if the machine is repeatedly under pressure.

## Does it change my current swap setup immediately?

No. Installation stages files for the next boot. It does not reset the live ZRAM device, call `swapoff`, or remove existing disk swap.
