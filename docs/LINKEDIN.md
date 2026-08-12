# LinkedIn post draft

I open-sourced the ZRAM profile kit from my Linux Android-dev workstation: **vmatlas-zram-kit**.

It is for the familiar “everything is active” workload: Android Studio, Gradle daemons, one or more emulators, browsers, Logcat, terminals, and whatever else is open while a build lands.

The project is not a magic-memory script. It is a portable, next-boot profile with visible safety boundaries: it scales RAM-sensitive settings per host, keeps existing disk swap alone, refuses to reset live ZRAM, and makes raw-partition writeback and expensive maintenance actions explicitly opt-in.

On my 16 GiB-class Linux Zen source workstation, at a two-day uptime snapshot, ZRAM was representing **13.87 GiB** of logical data in **4.38 GiB** of ZRAM allocator memory: a **3.17x** effective footprint reduction. At the same point, **3.79 GiB** of much colder pages were on a dedicated, budgeted backing partition. That is a real measurement from one workload—not a universal benchmark or a “16 GiB into 1 GiB” claim.

The repository also includes optional, inspect-first controls for recompression, bounded cold-page writeback, and single-process pageout/warm. A bypass needs an exact repeated PID or a literal confirmation token; there is intentionally no global `swapoff` or “unswap everything” button.

If you develop Android on Linux and regularly ride the edge of RAM without wanting an opaque tuning script, I would love feedback from machines with different CPU, DDR4/DDR5, SSD, and RAM sizes.

Repository: https://github.com/gustarmartins/vmatlas-zram-kit

Measurement and safety notes: `docs/REAL-WORLD-SNAPSHOT.md` and `docs/OPERATIONS.md`
