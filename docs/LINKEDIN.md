# LinkedIn post

I put the ZRAM setup from my Linux Android-dev workstation on GitHub: **vmatlas-zram-kit**.

It is for the days when Android Studio, Gradle, an emulator, Chrome, Logcat, terminals, and a build all decide they need RAM at the same time.

On my 16 GiB-class Linux Zen machine, after two days of uptime, ZRAM was holding 13.87 GiB of logical data in 4.38 GiB of allocator memory. That is 3.17x for that workload. Another 3.79 GiB of older pages sat on a dedicated backing partition.

That is not a “16 GiB in 1 GiB” claim. It is one measured machine under one real workload. Compression depends on the data; latency depends on CPU, RAM, and storage.

The repo stages its changes for the next boot, scales the RAM-dependent values, keeps existing disk swap alone, and makes the expensive stuff optional: tiered recompression, raw-partition writeback, and per-process pageout/warm controls. No live ZRAM reset. No global `swapoff`.

I would love results from other Linux Android-dev machines, especially different RAM sizes, CPUs, and SSDs.

https://github.com/gustarmartins/vmatlas-zram-kit
