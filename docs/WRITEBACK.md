# ZRAM NVMe Writeback Architecture & Requirements

Writeback in `vmatlas-zram-kit` is an advanced memory demotion mechanism. Rather than exposing an SSD partition as raw system swap (which suffers from high latency and disk fragmentation), ZRAM retains total control of swap allocations in RAM, selectively writing compressed, ancient, or uncompressible pages to a dedicated block device only when resident memory limits are approached.

---

## 1. Modern Kernel & GPT Partition Requirements

To prevent system stability issues, the backing partition must adhere to strict Linux storage architecture requirements:

### A. Partition Type GUID: Generic Linux Data (NOT Linux Swap)
* **Crucial Rule**: The backing partition MUST be typed with the GPT GUID `0fc63daf-8483-4772-8e79-3d69d8477de4` (**Generic Linux Data** / Partition type `8300` in fdisk/sgdisk).
* **Why**: If the partition is typed as `Linux Swap` (`0657fd6d-a4ab-43c4-84e5-0933c84b4f4f`), the systemd boot generator (`systemd-gpt-auto-generator`) will automatically detect it and create a raw swap unit (e.g. `dev-nvme0n1p1.swap`), activating it directly at priority -1 or -2. This bypasses ZRAM, fights its allocator, and leads to severe swap conflicts.
* **Installer Automation**: The `install.sh` wizard detects if a selected partition is typed as Linux Swap and provides a safe, automatic option to retype it via `sgdisk` without altering partition boundaries or touching other partitions.

### B. Raw Block Device (No Filesystem or Swap Signatures)
* The partition must not contain an active filesystem (ext4, btrfs, ntfs) or swap signature.
* Signatures can be cleared with `wipefs -a /dev/nvme0n1pX`.

### C. Persistent `/dev/disk/by-partuuid/...` Identifier
* The backing device must always be declared using its persistent PARTUUID path (e.g., `/dev/disk/by-partuuid/01767f33-8e7e-4ef7-ac65-0e63f34836e5`) rather than volatile device names (`/dev/nvme0n1p1` or `/dev/sda1`).

---

## 2. Guarded Writeback & Wear Cap Model

ZRAM writeback writes are strictly bounded by policy to protect SSD flash endurance and avoid I/O stalls:

1. **Compressed Writeback**:
   Where supported by the kernel (`/sys/block/zram0/compressed_writeback`), pages written to SSD are preserved in compressed form, saving up to 60-70% of write I/O.

2. **Inter-Pass Zero Lock**:
   Between writeback triggers, `writeback_limit` is explicitly locked to `0` pages with `writeback_limit_enable = 1`. This prevents unsolicited background writes from wearing out flash storage.

3. **Guarded 256 MiB Pass**:
   When triggered (either manually or adaptively by `vmatlas-zram-tier-manager`), the limit is armed for at most **256 MiB** (65,536 pages). Once the burst completes, the limit is immediately returned to 0 in an exit trap.

4. **Persistent 4 GiB Boot Wear Cap**:
   A cumulative session counter is maintained in `/run/vmatlas-tier/writeback_pages` that persists across same-boot ZRAM resets, ensuring the device never exceeds the 4 GiB write budget per boot without explicit administrator intervention (`emergency` / `force`).

---

## 3. Automation via Adaptive Tier Manager

`vmatlas-zram-tier-manager` (run every 30 minutes by `vmatlas-zram-tier-manager.timer`) evaluates writeback criteria automatically:

* **GPU Idle Gate**: Only proceeds if GPU busy <= 10%.
* **I/O Pressure Gate**: Only proceeds if I/O Full PSI `avg10` < 2%.
* **Resident Ratio Trigger**:
  * If ZRAM resident memory usage exceeds **85%** of `zram-resident-limit`, a 256 MiB writeback pass is executed.
  * If ZRAM resident memory usage exceeds **70%** and writeback has been idle for >= 4 hours, a 256 MiB maintenance pass is executed.

---

## 4. Manual Writeback Commands

```bash
# Run standard guarded 256 MiB cold pass
sudo vmatlas-zram writeback cold

# Writeback huge (uncompressible) pages
sudo vmatlas-zram writeback huge

# Emergency burst (1024 MiB cap)
sudo vmatlas-zram writeback emergency

# Inspect live writeback accounting
vmatlas-zram status
```
