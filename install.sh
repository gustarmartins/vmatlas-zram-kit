#!/usr/bin/env bash
# ==============================================================================
# vmatlas-zram-kit: Interactive installer and configuration engine
# Multi-tier ZRAM, kernel algorithm_params pre-initialization, and guarded NVMe writeback
# ==============================================================================
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

# Terminal styling & colors
if [ -t 1 ]; then
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    BLUE=$'\033[34m'
    CYAN=$'\033[36m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    RED=$'\033[31m'
    RST=$'\033[0m'
else
    BOLD='' DIM='' BLUE='' CYAN='' GREEN='' YELLOW='' RED='' RST=''
fi

# Global defaults
INTERACTIVE=0
[ -t 0 ] && [ -t 1 ] && INTERACTIVE=1
DRY_RUN=0
ADOPT_LOCAL_CONFIG=0
LIVE_RESTART=0
FORCE_RESTART=0
RETYPE_SWAP=0
EXPLICIT_INTERACTIVE=0

# Host memory info
RAM_TOTAL_KIB=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo || echo 16777216)
RAM_MIB=$((RAM_TOTAL_KIB / 1024))
RAM_GIB_CALC=$(awk -v k="$RAM_TOTAL_KIB" 'BEGIN{printf "%.1f", k / 1024 / 1024}')

# ZRAM parameters default (Preset 1: Workstation 16GB Baseline)
ZRAM_SIZE_EXPR="ram * 2.25"
ZRAM_RESIDENT_LIMIT_EXPR="ram / 1.6"
SWAP_PRIORITY=90

# Compression Tiering default (4-tier hierarchy)
TIER_MODE=4 # 4=4-tier (LZ4 -> ZSTD3/9/15), 3=3-tier (LZ4 -> ZSTD3/9), 1=single (ZSTD:3)
PRIMARY_ALGO="lz4"
PRIMARY_LEVEL=""
TIER1_ALGO="zstd"
TIER1_LEVEL="3"
TIER2_ALGO="zstd"
TIER2_LEVEL="9"
TIER3_ALGO="zstd"
TIER3_LEVEL="15"

# Writeback defaults
WRITEBACK_DEVICE=""
COLD_PASS_MIB=256
BOOT_CAP_MIB=4096
EMERGENCY_CAP_MIB=1024
IDLE_AGE_SECONDS=1800

# VM Sysctl default knobs (16GB baseline)
SWAPPINESS=142
VFS_CACHE_PRESSURE=68
MIN_FREE_KIB=131072
WATERMARK_SCALE=92
WATERMARK_BOOST=16155
PAGE_CLUSTER=0
COMPACTION_PROACTIVE=0
COMPACT_UNEVIC=1
ZONE_RECLAIM=0
DIRTY_BYTES=1342177280
DIRTY_BG_BYTES=78643200
DIRTY_WRITEBACK_CS=150
DIRTY_EXPIRE_CS=1000
EXTFRAG_THRESHOLD=250
MAX_MAP_COUNT=1048576
MGLRU_TTL=2000

# Helper functions
info()    { printf "%b[*] %s%b\n" "$CYAN" "$*" "$RST"; }
success() { printf "%b[+] %s%b\n" "$GREEN" "$*" "$RST"; }
warn()    { printf "%b[!] WARNING: %s%b\n" "$YELLOW" "$*" "$RST"; }
err()     { printf "%b[-] ERROR: %s%b\n" "$RED" "$*" "$RST"; }
die()     { err "$*"; exit 1; }
step()    { printf "\n%b>>> %s%b\n" "$BOLD$BLUE" "$*" "$RST"; }

print_banner() {
    cat <<EOF
${BOLD}${CYAN}
================================================================================
          __     ____  ___ _____ _        _    ____     _____ ____  _     
          \ \   / /  \/  |_   _/ \      / \  / ___|   |__  /  _ \| \    
           \ \ / /| |\/| | | |/ _ \    / _ \ \___ \     / /| |_) | |    
            \ V / | |  | | | / ___ \  / ___ \ ___) |   / /_|  _ <| |___ 
             \_/  |_|  |_| |/_/   \_\/_/   \_\____/   /____|_| \_\_____|
================================================================================
${RST}${DIM}  High-Performance Multi-Tier ZRAM & Linux VM Policy Kit for Modern Workstations${RST}
EOF
}

usage() {
    cat <<EOF
${BOLD}Usage:${RST} ./install.sh [options]

${BOLD}Installation Modes:${RST}
  --interactive                  Run full interactive wizard (default in TTY)
  --non-interactive, -y          Run without interactive prompts using selected options
  --dry-run                      Print configuration plan without modifying the system
  --live-restart                 Apply and live-restart ZRAM and VM stack immediately
  --force-restart                Bypass memory headroom safety check during live restart

${BOLD}ZRAM Sizing Options:${RST}
  --size <expr>                  ZRAM device size formula (default: "ram * 2.25")
  --resident-limit <expr>        ZRAM resident memory limit formula (default: "ram / 1.6")
  --swap-priority <num>          Swap priority in zram-generator (default: 90)

${BOLD}Compression Tiering Options:${RST}
  --tiers <4|3|1>                Compression pipeline (4=LZ4+ZSTD 3/9/15, 3=LZ4+ZSTD 3/9, 1=ZSTD:3)
  --primary-algo <algo>          Primary fast swap algorithm (default: lz4)
  --primary-level <level>        Primary algorithm level (default: empty)

${BOLD}NVMe Writeback Options:${RST}
  --writeback-device <path>      Dedicated empty raw partition (/dev/disk/by-partuuid/...)
  --confirm-writeback-device     Explicit confirmation for raw partition usage
  --retype-swap-partition        Retype partition from Linux Swap to Generic Linux Data

${BOLD}Profile & System Options:${RST}
  --swappiness <val>             vm.swappiness (default: 142)
  --vfs-cache-pressure <val>     vm.vfs_cache_pressure (default: 68)
  --adopt-local-zram-config      Overwrite existing local zram-generator config
  -h, --help                     Show this help message

EOF
}

# Parse CLI arguments
while [ "$#" -gt 0 ]; do
    case "$1" in
        --interactive) INTERACTIVE=1; EXPLICIT_INTERACTIVE=1; shift ;;
        --non-interactive|-y|--yes) INTERACTIVE=0; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --live-restart) LIVE_RESTART=1; shift ;;
        --force-restart) LIVE_RESTART=1; FORCE_RESTART=1; shift ;;
        --size) ZRAM_SIZE_EXPR="${2:-}"; shift 2 ;;
        --resident-limit) ZRAM_RESIDENT_LIMIT_EXPR="${2:-}"; shift 2 ;;
        --swap-priority) SWAP_PRIORITY="${2:-90}"; shift 2 ;;
        --tiers) TIER_MODE="${2:-4}"; shift 2 ;;
        --primary-algo) PRIMARY_ALGO="${2:-lz4}"; shift 2 ;;
        --primary-level) PRIMARY_LEVEL="${2:-}"; shift 2 ;;
        --writeback-device) WRITEBACK_DEVICE="${2:-}"; shift 2 ;;
        --confirm-writeback-device) shift ;;
        --retype-swap-partition) RETYPE_SWAP=1; shift ;;
        --swappiness) SWAPPINESS="${2:-142}"; shift 2 ;;
        --vfs-cache-pressure) VFS_CACHE_PRESSURE="${2:-68}"; shift 2 ;;
        --adopt-local-zram-config) ADOPT_LOCAL_CONFIG=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
done

if [ "$DRY_RUN" -eq 1 ] && [ "$EXPLICIT_INTERACTIVE" -eq 0 ]; then
    INTERACTIVE=0
fi

# Detect Linux Distribution
detect_distro() {
    DISTRO="unknown"
    if [ -f /etc/arch-release ] || grep -qi "arch" /etc/os-release 2>/dev/null; then
        DISTRO="arch"
    elif [ -f /etc/fedora-release ] || grep -qi "fedora" /etc/os-release 2>/dev/null; then
        DISTRO="fedora"
    elif [ -f /etc/debian_version ] || grep -qi "debian\|ubuntu" /etc/os-release 2>/dev/null; then
        DISTRO="debian"
    fi
}

# Check and install dependencies
check_dependencies() {
    step "Checking System Prerequisites & Package Dependencies"
    
    [ -d /run/systemd/system ] || die "systemd is not PID 1. This kit requires a systemd-based Linux system."
    command -v systemctl >/dev/null 2>&1 || die "systemctl command not found."

    local missing=()
    command -v awk >/dev/null 2>&1 || missing+=("gawk")
    command -v lsblk >/dev/null 2>&1 || missing+=("util-linux")
    command -v sysctl >/dev/null 2>&1 || missing+=("procps-ng")
    
    # Check zram-generator
    local gen_found=0
    for cand in /usr/lib/systemd/system-generators/zram-generator /usr/libexec/systemd/system-generators/zram-generator; do
        if [ -x "$cand" ]; then
            gen_found=1
            break
        fi
    done
    if [ "$gen_found" -eq 0 ] && ! command -v zram-generator >/dev/null 2>&1; then
        missing+=("zram-generator")
    fi

    if [ "${#missing[@]}" -gt 0 ]; then
        warn "Missing required packages: ${missing[*]}"
        if [ "$DISTRO" = "arch" ]; then
            if [ "$INTERACTIVE" -eq 1 ]; then
                printf '%s' "${BOLD}Install missing packages using pacman now? [Y/n]: ${RST}"
                read -r reply
                if [[ ! "$reply" =~ ^[Nn] ]]; then
                    sudo pacman -S --needed --noconfirm "${missing[@]}" || die "failed to install dependencies with pacman"
                else
                    die "required dependencies missing: ${missing[*]}"
                fi
            else
                die "missing dependencies: ${missing[*]}. Please install them first: pacman -S ${missing[*]}"
            fi
        else
            die "please install missing dependencies: ${missing[*]}"
        fi
    fi
    success "All prerequisite packages are installed."
}

# Check existing local config unless adopting
check_existing_config() {
    if [ "$ADOPT_LOCAL_CONFIG" -eq 0 ]; then
        if [ -f /etc/systemd/zram-generator.conf ] && ! grep -Fqs "vmatlas-zram" /etc/systemd/zram-generator.conf; then
            warn "Local configuration exists at /etc/systemd/zram-generator.conf (pass --adopt-local-zram-config to adopt)."
        fi
    fi
}

# Inspect kernel capabilities
check_kernel_capabilities() {
    step "Inspecting Kernel Multi-Compressor & ZRAM Capabilities"
    local z=/sys/block/zram0

    # If zram module not loaded, attempt to modprobe it
    if [ ! -d "$z" ]; then
        info "Loading zram kernel module for capability probe..."
        sudo modprobe zram num_devices=1 2>/dev/null || true
    fi

    if [ -d "$z" ]; then
        if [ -e "$z/recomp_algorithm" ] && [ -e "$z/recompress" ] && [ -e "$z/algorithm_params" ]; then
            success "Kernel multi-compressor recompression ABI verified (recomp_algorithm, algorithm_params, recompress)."
        else
            warn "Running kernel lacks multi-compressor ABI (algorithm_params or recomp_algorithm missing)."
        fi

        if [ -e "$z/compressed_writeback" ]; then
            success "Kernel compressed writeback ABI verified."
        fi
    else
        info "zram device sysfs not active yet; kernel capabilities will be initialized at boot."
    fi

    if [ -e /sys/kernel/mm/lru_gen/enabled ]; then
        success "Multi-Gen LRU (MGLRU) verified."
    fi
}

# Auto-scale VM knobs based on host RAM
autoscale_vm_knobs() {
    if [ "$RAM_MIB" -le 8192 ]; then
        MIN_FREE_KIB=65536
        DIRTY_BG_BYTES=33554432
        DIRTY_BYTES=268435456
        MGLRU_TTL=1000
        SWAPPINESS=140
    elif [ "$RAM_MIB" -le 24576 ]; then
        # 16GB Baseline Profile
        MIN_FREE_KIB=131072
        DIRTY_BG_BYTES=78643200
        DIRTY_BYTES=1342177280
        MGLRU_TTL=2000
        SWAPPINESS=142
    elif [ "$RAM_MIB" -le 49152 ]; then
        # 32GB Profile
        MIN_FREE_KIB=262144
        DIRTY_BG_BYTES=134217728
        DIRTY_BYTES=2684354560
        MGLRU_TTL=2000
        SWAPPINESS=140
    else
        # 64GB+ Profile
        MIN_FREE_KIB=524288
        DIRTY_BG_BYTES=268435456
        DIRTY_BYTES=5368709120
        MGLRU_TTL=3000
        SWAPPINESS=133
    fi
}

# Wizard: Sizing Selection
wizard_sizing() {
    step "Step 1: ZRAM Sizing & Allocation Strategy"
    printf "Detected Host RAM: %b%s GiB%b (%s MiB)\n\n" "$BOLD$GREEN" "$RAM_GIB_CALC" "$RST" "$RAM_MIB"
    
    local s1_size="ram * 2.25"
    local s1_res="ram / 1.6"
    local s1_calc_size
    s1_calc_size=$(awk -v r="$RAM_GIB_CALC" 'BEGIN{printf "%.1f", r * 2.25}')
    local s1_calc_res
    s1_calc_res=$(awk -v r="$RAM_GIB_CALC" 'BEGIN{printf "%.1f", r / 1.6}')

    local s2_calc_size
    s2_calc_size=$(awk -v r="$RAM_GIB_CALC" 'BEGIN{printf "%.1f", r * 2.5}')
    local s2_calc_res
    s2_calc_res=$(awk -v r="$RAM_GIB_CALC" 'BEGIN{printf "%.1f", r / 1.5}')

    local s3_calc_size
    s3_calc_size=$(awk -v r="$RAM_GIB_CALC" 'BEGIN{printf "%.1f", r * 2.0}')
    local s3_calc_res
    s3_calc_res=$(awk -v r="$RAM_GIB_CALC" 'BEGIN{printf "%.1f", r / 2.0}')

    cat <<EOF
Select your ZRAM Sizing Preset:
  ${BOLD}1) Workstation & Dev Baseline (Recommended for 16GB)${RST}
     -> ZRAM Size: ${BOLD}${s1_size}${RST} (~${s1_calc_size} GiB virtual) | Resident Limit: ${BOLD}${s1_res}${RST} (~${s1_calc_res} GiB RAM cap)
  ${BOLD}2) Aggressive / Build Storm (Android / Chromium compiles)${RST}
     -> ZRAM Size: ${BOLD}ram * 2.50${RST} (~${s2_calc_size} GiB virtual) | Resident Limit: ${BOLD}ram / 1.5${RST} (~${s2_calc_res} GiB RAM cap)
  ${BOLD}3) Balanced Standard${RST}
     -> ZRAM Size: ${BOLD}ram * 2.00${RST} (~${s3_calc_size} GiB virtual) | Resident Limit: ${BOLD}ram / 2.0${RST} (~${s3_calc_res} GiB RAM cap)
  ${BOLD}4) Safe Conservative${RST}
     -> ZRAM Size: ${BOLD}min(ram * 2, 32 GiB)${RST} | Resident Limit: ${BOLD}ram / 2${RST}
  ${BOLD}5) Custom Expression${RST}
     -> Enter custom sizing and resident limit formulas
EOF

    printf '\n%s' "${BOLD}Select option [1-5, Default 1]: ${RST}"
    read -r choice
    case "${choice:-1}" in
        1)
            ZRAM_SIZE_EXPR="ram * 2.25"
            ZRAM_RESIDENT_LIMIT_EXPR="ram / 1.6"
            ;;
        2)
            ZRAM_SIZE_EXPR="ram * 2.50"
            ZRAM_RESIDENT_LIMIT_EXPR="ram / 1.5"
            ;;
        3)
            ZRAM_SIZE_EXPR="ram * 2.00"
            ZRAM_RESIDENT_LIMIT_EXPR="ram / 2.0"
            ;;
        4)
            ZRAM_SIZE_EXPR="min(ram * 2, 32 * 1024)"
            ZRAM_RESIDENT_LIMIT_EXPR="ram / 2"
            ;;
        5)
            printf "Enter zram-size formula (e.g. 'ram * 2.25' or '32G'): "
            read -r ZRAM_SIZE_EXPR
            printf "Enter zram-resident-limit formula (e.g. 'ram / 1.6' or '10G'): "
            read -r ZRAM_RESIDENT_LIMIT_EXPR
            ;;
        *)
            ZRAM_SIZE_EXPR="ram * 2.25"
            ZRAM_RESIDENT_LIMIT_EXPR="ram / 1.6"
            ;;
    esac
    success "Selected ZRAM Sizing: size = '$ZRAM_SIZE_EXPR', resident limit = '$ZRAM_RESIDENT_LIMIT_EXPR'"
}

# Wizard: Compression Tiering Selection
wizard_tiering() {
    step "Step 2: Compression Pipeline & Recompression Tiering"
    cat <<'EOF'
Select your Compression Tiering Architecture:
  1) 4-Stage Progressive Hierarchy (Recommended)
     -> Primary: LZ4 (instant swap-out latency)
     -> Tier 1:  ZSTD level 3  (idle ~30 mins, 256 MiB pass)
     -> Tier 2:  ZSTD level 9  (idle ~3 hours, 128 MiB pass)
     -> Tier 3:  ZSTD level 15 (idle ~12 hours, 64 MiB pass)
  2) 3-Stage High-Throughput
     -> Primary: LZ4
     -> Tier 1:  ZSTD level 3
     -> Tier 2:  ZSTD level 9
  3) Single-Stage ZSTD
     -> Primary: ZSTD (level 3)
  4) Custom Tiering Parameters
EOF

    printf "\nSelect option [1-4, Default 1]: "
    read -r choice
    case "${choice:-1}" in
        1)
            TIER_MODE=4
            PRIMARY_ALGO="lz4"
            PRIMARY_LEVEL=""
            TIER1_ALGO="zstd"; TIER1_LEVEL="3"
            TIER2_ALGO="zstd"; TIER2_LEVEL="9"
            TIER3_ALGO="zstd"; TIER3_LEVEL="15"
            ;;
        2)
            TIER_MODE=3
            PRIMARY_ALGO="lz4"
            PRIMARY_LEVEL=""
            TIER1_ALGO="zstd"; TIER1_LEVEL="3"
            TIER2_ALGO="zstd"; TIER2_LEVEL="9"
            TIER3_ALGO=""; TIER3_LEVEL=""
            ;;
        3)
            TIER_MODE=1
            PRIMARY_ALGO="zstd"
            PRIMARY_LEVEL="3"
            TIER1_ALGO=""; TIER1_LEVEL=""
            TIER2_ALGO=""; TIER2_LEVEL=""
            TIER3_ALGO=""; TIER3_LEVEL=""
            ;;
        4)
            printf "Enter primary algorithm (e.g. lz4, zstd): "
            read -r PRIMARY_ALGO
            printf "Enter primary level (optional, leave empty for default): "
            read -r PRIMARY_LEVEL
            printf "Enter Tier 1 algorithm: "
            read -r TIER1_ALGO
            printf "Enter Tier 1 level: "
            read -r TIER1_LEVEL
            printf "Enter Tier 2 algorithm (or empty): "
            read -r TIER2_ALGO
            printf "Enter Tier 2 level (or empty): "
            read -r TIER2_LEVEL
            printf "Enter Tier 3 algorithm (or empty): "
            read -r TIER3_ALGO
            printf "Enter Tier 3 level (or empty): "
            read -r TIER3_LEVEL
            ;;
        *)
            TIER_MODE=4
            PRIMARY_ALGO="lz4"
            PRIMARY_LEVEL=""
            TIER1_ALGO="zstd"; TIER1_LEVEL="3"
            TIER2_ALGO="zstd"; TIER2_LEVEL="9"
            TIER3_ALGO="zstd"; TIER3_LEVEL="15"
            ;;
    esac
    success "Configured Pipeline: Primary $PRIMARY_ALGO -> Tiers [${TIER1_ALGO:+$TIER1_ALGO:$TIER1_LEVEL} ${TIER2_ALGO:+$TIER2_ALGO:$TIER2_LEVEL} ${TIER3_ALGO:+$TIER3_ALGO:$TIER3_LEVEL}]"
}

# Wizard: Writeback Partition Configuration
wizard_writeback() {
    step "Step 3: NVMe / SSD Writeback Backing Partition"
    cat <<'EOF'
ZRAM Writeback allows idle/cold compressed pages to be safely demoted to a dedicated
raw SSD partition during periods of high resident RAM pressure.

Requirements:
  - Must be a dedicated RAW partition on an NVMe/SSD.
  - Must NOT be mounted, active swap, or used for filesystem storage.
  - MUST have GPT partition type "Generic Linux Data" (0fc63daf-8483-4772-8e79-3d69d8477de4).
    (If typed as Linux Swap, systemd-gpt-auto-generator will hijack it as ordinary disk swap).
EOF

    printf '\n%s' "${BOLD}Do you want to configure an SSD/NVMe writeback backing partition? [y/N]: ${RST}"
    read -r enable_wb
    if [[ ! "$enable_wb" =~ ^[Yy] ]]; then
        WRITEBACK_DEVICE=""
        info "Writeback disabled."
        return 0
    fi

    printf '\n%s\n' "${CYAN}Scanning available block partitions...${RST}"
    local part_uuids=()
    local part_paths=()
    local part_types=()
    local i=1

    while IFS=$'\t' read -r path size type fstype mount partuuid model; do
        [ "$type" = "part" ] || continue
        # Filter root / boot
        [ "$mount" != "/" ] && [ "$mount" != "/boot" ] && [ "$mount" != "/efi" ] || continue
        [ -n "$partuuid" ] || continue

        local stable_path="/dev/disk/by-partuuid/$partuuid"
        part_paths+=("$stable_path")
        part_uuids+=("$partuuid")
        part_types+=("${fstype:-none}")

        printf "  %2d) %-15s %-8s %-10s mount:%-10s uuid:%s (%s)\n" \
            "$i" "$path" "$size" "${fstype:-raw}" "${mount:-none}" "$partuuid" "${model:-unknown}"
        i=$((i + 1))
    done < <(lsblk -r -n -o PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS,PARTUUID,MODEL 2>/dev/null || true)

    if [ "${#part_paths[@]}" -eq 0 ]; then
        warn "No candidate partitions detected automatically."
        printf "Enter custom persistent path (e.g. /dev/disk/by-partuuid/...) or press Enter to skip: "
        read -r custom_path
        if [ -n "$custom_path" ]; then
            WRITEBACK_DEVICE="$custom_path"
        fi
        return 0
    fi

    printf "   0) Enter custom path manually\n"
    printf "   s) Skip writeback setup\n"
    printf "\nSelect partition [1-%d, or 0/s]: " "$((i - 1))"
    read -r sel
    case "$sel" in
        [Ss]|"")
            WRITEBACK_DEVICE=""
            info "Skipping writeback configuration."
            return 0
            ;;
        0)
            printf "Enter full /dev/disk/by-* path: "
            read -r WRITEBACK_DEVICE
            ;;
        *)
            if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#part_paths[@]}" ]; then
                local idx=$((sel - 1))
                WRITEBACK_DEVICE="${part_paths[$idx]}"
            else
                warn "Invalid selection. Skipping writeback."
                WRITEBACK_DEVICE=""
                return 0
            fi
            ;;
    esac

    # Validate and check GPT partition type
    if [ -n "$WRITEBACK_DEVICE" ]; then
        local resolved
        resolved=$(readlink -f -- "$WRITEBACK_DEVICE" 2>/dev/null || echo "$WRITEBACK_DEVICE")
        
        # Check active swap
        if grep -Fq "$resolved" /proc/swaps 2>/dev/null; then
            err "$WRITEBACK_DEVICE is currently active as system swap!"
            printf "Disable active swap on this partition and re-run, or select another partition.\n"
            WRITEBACK_DEVICE=""
            return 0
        fi

        # Check GPT type GUID using sgdisk / lsblk if available
        local gpt_type=""
        if command -v sgdisk >/dev/null 2>&1; then
            local disk_dev
            disk_dev=$(lsblk -ndo PKNAME "$resolved" 2>/dev/null || true)
            local part_num
            part_num=$(lsblk -ndo PARTN "$resolved" 2>/dev/null || true)
            if [ -n "$disk_dev" ] && [ -n "$part_num" ]; then
                gpt_type=$(sgdisk -i "$part_num" "/dev/$disk_dev" 2>/dev/null | grep -i "Partition GUID code" | awk '{print $4}' || true)
            fi
        fi

        # If typed as Linux swap (0657fd6d-a4ab-43c4-84e5-0933c84b4f4f)
        if [[ "$gpt_type" =~ ^[0-9a-fA-F-]*0657FD6D ]] || [[ "$gpt_type" =~ ^0657fd6d ]]; then
            warn "Partition is currently typed as 'Linux swap' ($gpt_type)."
            printf "systemd-gpt-auto-generator will claim this as ordinary swap at boot, conflicting with ZRAM!\n"
            printf '%s' "${BOLD}Would you like the installer to safely retype it to 'Generic Linux Data' (0fc63daf-8483-4772-8e79-3d69d8477de4)? [Y/n]: ${RST}"
            read -r retype_ans
            if [[ ! "$retype_ans" =~ ^[Nn] ]]; then
                RETYPE_SWAP=1
            fi
        fi

        # Check filesystem signatures
        local sigs
        sigs=$(wipefs -n --noheadings "$resolved" 2>/dev/null || true)
        if [ -n "$sigs" ]; then
            warn "Filesystem signatures detected on $WRITEBACK_DEVICE ($sigs)."
            printf '%s' "${BOLD}Wipe signatures now to prepare as dedicated raw backing store? [y/N]: ${RST}"
            read -r wipe_ans
            if [[ "$wipe_ans" =~ ^[Yy] ]]; then
                sudo wipefs -a "$resolved" || warn "wipefs returned non-zero"
            else
                die "cannot use partition with active filesystem signatures."
            fi
        fi
        success "Selected writeback device: $WRITEBACK_DEVICE"
    fi
}

# Wizard: VM Profile Knobs Selection
wizard_vm_knobs() {
    step "Step 4: Linux VM Kernel Tunables (sysctl & MGLRU)"
    autoscale_vm_knobs
    cat <<EOF
Select VM Tunables Baseline:
  ${BOLD}1) Workstation & Dev Baseline (Codex/AGY default for 16GB)${RST}
     -> swappiness: ${BOLD}142${RST}, vfs_cache_pressure: ${BOLD}68${RST}, min_free_kbytes: ${BOLD}131072${RST}
     -> watermarks: scale=${BOLD}92${RST}, boost=${BOLD}16155${RST}, page-cluster: ${BOLD}0${RST} (ZRAM optimized)
     -> dirty bytes: foreground=${BOLD}1.25 GiB${RST}, background=${BOLD}75 MiB${RST}, MGLRU TTL: ${BOLD}2000ms${RST}
  ${BOLD}2) Auto-scaled for Host RAM (${RAM_GIB_CALC} GiB)${RST}
     -> Scaled min_free, dirty ratios, and cache pressure
  ${BOLD}3) Conservative Default${RST}
     -> swappiness: 100, vfs_cache_pressure: 100, page-cluster: 0
EOF

    printf "\nSelect option [1-3, Default 1]: "
    read -r vm_choice
    case "${vm_choice:-1}" in
        1)
            SWAPPINESS=142
            VFS_CACHE_PRESSURE=68
            MIN_FREE_KIB=131072
            WATERMARK_SCALE=92
            WATERMARK_BOOST=16155
            DIRTY_BYTES=1342177280
            DIRTY_BG_BYTES=78643200
            MGLRU_TTL=2000
            ;;
        2)
            autoscale_vm_knobs
            ;;
        3)
            SWAPPINESS=100
            VFS_CACHE_PRESSURE=100
            PAGE_CLUSTER=0
            ;;
        *)
            SWAPPINESS=142
            VFS_CACHE_PRESSURE=68
            ;;
    esac
    success "Configured VM Knobs: swappiness=$SWAPPINESS, vfs_cache_pressure=$VFS_CACHE_PRESSURE, page-cluster=0"
}

# Review Plan and Summary
show_summary() {
    step "Configuration Plan & Review"
    cat <<EOF
================================================================================
  Target System:          Linux (${DISTRO}) | ${RAM_GIB_CALC} GiB Total RAM
--------------------------------------------------------------------------------
  ZRAM Device (/dev/zram0):
    Size Expression:      ${BOLD}${ZRAM_SIZE_EXPR}${RST}
    Resident RAM Limit:   ${BOLD}${ZRAM_RESIDENT_LIMIT_EXPR}${RST}
    Swap Priority:        ${BOLD}${SWAP_PRIORITY}${RST}

  Compression Hierarchy:
    Primary Fast Path:    ${BOLD}${PRIMARY_ALGO}${PRIMARY_LEVEL:+ (level $PRIMARY_LEVEL)}${RST}
    Tier 1 (Priority 1):  ${TIER1_ALGO:+${BOLD}$TIER1_ALGO:$TIER1_LEVEL${RST} (idle ~30m, max 256 MiB)}
    Tier 2 (Priority 2):  ${TIER2_ALGO:+${BOLD}$TIER2_ALGO:$TIER2_LEVEL${RST} (idle ~3h, max 128 MiB)}
    Tier 3 (Priority 3):  ${TIER3_ALGO:+${BOLD}$TIER3_ALGO:$TIER3_LEVEL${RST} (idle ~12h, max 64 MiB)}

  NVMe Writeback Backing Store:
    Backing Device:       ${BOLD}${WRITEBACK_DEVICE:-DISABLED}${RST}
    Guarded Cold Pass:    ${COLD_PASS_MIB} MiB per burst (auto-relocked to 0 pages)
    Boot Wear Cap:        ${BOOT_CAP_MIB} MiB persistent budget

  Kernel VM Tunables:
    vm.swappiness:        ${BOLD}${SWAPPINESS}${RST}
    vm.vfs_cache_pressure:${BOLD}${VFS_CACHE_PRESSURE}${RST}
    vm.min_free_kbytes:   ${BOLD}${MIN_FREE_KIB}${RST}
    vm.page-cluster:      ${BOLD}0${RST} (Zero disk readahead latency)
    MGLRU TTL:            ${BOLD}${MGLRU_TTL} ms${RST}
================================================================================
EOF
}

# Perform Installation & Staging
stage_and_install() {
    step "Staging Configuration Files & Installing System Services"

    # Backup existing configurations
    local backup_dir
    backup_dir="/var/backups/vmatlas-zram-$(date +%Y%m%d-%H%M%S)"
    sudo install -d -m 0755 "$backup_dir"
    for f in /etc/systemd/zram-generator.conf \
             /etc/systemd/zram-generator.conf.d/90-vmatlas-zram.conf \
             /etc/sysctl.d/90-vmatlas-zram.conf \
             /etc/vmatlas-zram/tiers.conf \
             /etc/vmatlas/zram-tiers.conf; do
        if [ -f "$f" ]; then
            sudo cp -p "$f" "$backup_dir/" 2>/dev/null || true
        fi
    done
    info "Backed up existing configuration to $backup_dir"

    # If partition retyping requested, execute sgdisk
    if [ "$RETYPE_SWAP" -eq 1 ] && [ -n "$WRITEBACK_DEVICE" ]; then
        local resolved
        resolved=$(readlink -f -- "$WRITEBACK_DEVICE")
        local disk_dev part_num
        disk_dev=$(lsblk -ndo PKNAME "$resolved" 2>/dev/null || true)
        part_num=$(lsblk -ndo PARTN "$resolved" 2>/dev/null || true)
        if [ -n "$disk_dev" ] && [ -n "$part_num" ] && command -v sgdisk >/dev/null 2>&1; then
            info "Retyping partition $part_num on /dev/$disk_dev to Generic Linux Data..."
            sudo sgdisk -t "${part_num}:0fc63daf-8483-4772-8e79-3d69d8477de4" "/dev/$disk_dev" || warn "sgdisk retype failed"
            sudo partprobe "/dev/$disk_dev" 2>/dev/null || true
        fi
    fi

    # Create target directories
    sudo install -d -m 0755 /etc/systemd/zram-generator.conf.d \
                            /etc/sysctl.d \
                            /etc/vmatlas-zram \
                            /etc/vmatlas \
                            /etc/systemd/system/systemd-zram-setup@zram0.service.d \
                            /usr/local/bin \
                            /usr/local/libexec \
                            /run/vmatlas-tier

    # 1. Stage /etc/systemd/zram-generator.conf.d/90-vmatlas-zram.conf
    local zgen_algos="$PRIMARY_ALGO"
    [ -n "$TIER1_ALGO" ] && zgen_algos="$zgen_algos $TIER1_ALGO"
    [ -n "$TIER2_ALGO" ] && zgen_algos="$zgen_algos $TIER2_ALGO"
    [ -n "$TIER3_ALGO" ] && zgen_algos="$zgen_algos $TIER3_ALGO"

    sudo tee /etc/systemd/zram-generator.conf.d/90-vmatlas-zram.conf >/dev/null <<EOF
# Managed by vmatlas-zram-kit.
[zram0]
zram-size = $ZRAM_SIZE_EXPR
zram-resident-limit = $ZRAM_RESIDENT_LIMIT_EXPR
compression-algorithm = $zgen_algos
swap-priority = $SWAP_PRIORITY
${WRITEBACK_DEVICE:+writeback-device = $WRITEBACK_DEVICE}
EOF
    sudo chmod 0644 /etc/systemd/zram-generator.conf.d/90-vmatlas-zram.conf

    # 2. Stage /etc/vmatlas-zram/tiers.conf and /etc/vmatlas/zram-tiers.conf
    sudo tee /etc/vmatlas-zram/tiers.conf >/dev/null <<EOF
# Managed by vmatlas-zram-kit.
PRIMARY_ALGO=$PRIMARY_ALGO
PRIMARY_LEVEL=$PRIMARY_LEVEL
TIER1_ALGO=$TIER1_ALGO
TIER1_LEVEL=$TIER1_LEVEL
TIER2_ALGO=$TIER2_ALGO
TIER2_LEVEL=$TIER2_LEVEL
TIER3_ALGO=$TIER3_ALGO
TIER3_LEVEL=$TIER3_LEVEL
WRITEBACK_ENABLED=$([ -n "$WRITEBACK_DEVICE" ] && echo 1 || echo 0)
EOF
    sudo chmod 0644 /etc/vmatlas-zram/tiers.conf
    sudo cp -f /etc/vmatlas-zram/tiers.conf /etc/vmatlas/zram-tiers.conf 2>/dev/null || true

    # 3. Stage /etc/vmatlas-zram/profile.env & writeback.env
    sudo tee /etc/vmatlas-zram/profile.env >/dev/null <<EOF
# Managed by vmatlas-zram-kit.
PROFILE=workstation-tiered
TIER_MODE=$TIER_MODE
MGLRU_TTL_MS=$MGLRU_TTL
EOF
    sudo chmod 0644 /etc/vmatlas-zram/profile.env

    if [ -n "$WRITEBACK_DEVICE" ]; then
        sudo tee /etc/vmatlas-zram/writeback.env >/dev/null <<EOF
# Managed by vmatlas-zram-kit.
WRITEBACK_DEVICE=$WRITEBACK_DEVICE
COLD_PASS_MIB=$COLD_PASS_MIB
BOOT_CAP_MIB=$BOOT_CAP_MIB
EMERGENCY_CAP_MIB=$EMERGENCY_CAP_MIB
IDLE_AGE_SECONDS=$IDLE_AGE_SECONDS
EOF
        sudo chmod 0644 /etc/vmatlas-zram/writeback.env
    fi

    # 4. Stage /etc/sysctl.d/90-vmatlas-zram.conf
    sudo tee /etc/sysctl.d/90-vmatlas-zram.conf >/dev/null <<EOF
# Managed by vmatlas-zram-kit. Host VM Tunables.
vm.swappiness = $SWAPPINESS
vm.vfs_cache_pressure = $VFS_CACHE_PRESSURE
vm.page-cluster = $PAGE_CLUSTER
vm.min_free_kbytes = $MIN_FREE_KIB
vm.watermark_scale_factor = $WATERMARK_SCALE
vm.watermark_boost_factor = $WATERMARK_BOOST
vm.zone_reclaim_mode = $ZONE_RECLAIM
vm.dirty_background_ratio = 0
vm.dirty_ratio = 0
vm.dirty_background_bytes = $DIRTY_BG_BYTES
vm.dirty_bytes = $DIRTY_BYTES
vm.dirty_expire_centisecs = $DIRTY_EXPIRE_CS
vm.dirty_writeback_centisecs = $DIRTY_WRITEBACK_CS
vm.compaction_proactiveness = $COMPACTION_PROACTIVE
vm.compact_unevictable_allowed = $COMPACT_UNEVIC
vm.extfrag_threshold = $EXTFRAG_THRESHOLD
vm.max_map_count = $MAX_MAP_COUNT
EOF
    sudo chmod 0644 /etc/sysctl.d/90-vmatlas-zram.conf

    # 5. Install systemd drop-in
    sudo cp -f "$SCRIPT_DIR/systemd/systemd-zram-setup@zram0.service.d/10-vmatlas-tier.conf" \
        /etc/systemd/system/systemd-zram-setup@zram0.service.d/10-vmatlas-tier.conf
    sudo chmod 0644 /etc/systemd/system/systemd-zram-setup@zram0.service.d/10-vmatlas-tier.conf

    # 6. Install binaries and libexec helpers
    sudo install -D -o root -g root -m 0755 "$SCRIPT_DIR/bin/vmatlas-zram" /usr/local/bin/vmatlas-zram
    sudo install -D -o root -g root -m 0755 "$SCRIPT_DIR/libexec/vmatlas-zram-tier-init" /usr/local/libexec/vmatlas-zram-tier-init
    sudo install -D -o root -g root -m 0755 "$SCRIPT_DIR/libexec/vmatlas-zram-tier-manager" /usr/local/libexec/vmatlas-zram-tier-manager
    sudo install -D -o root -g root -m 0755 "$SCRIPT_DIR/libexec/vmatlas-zram-mglru" /usr/local/libexec/vmatlas-zram-mglru
    sudo install -D -o root -g root -m 0755 "$SCRIPT_DIR/libexec/vmatlas-zram-process" /usr/local/libexec/vmatlas-zram-process

    # 7. Install systemd unit files
    sudo install -D -o root -g root -m 0644 "$SCRIPT_DIR/systemd/vmatlas-zram-mglru.service" /etc/systemd/system/vmatlas-zram-mglru.service
    sudo install -D -o root -g root -m 0644 "$SCRIPT_DIR/systemd/vmatlas-zram-tier-manager.service" /etc/systemd/system/vmatlas-zram-tier-manager.service
    sudo install -D -o root -g root -m 0644 "$SCRIPT_DIR/systemd/vmatlas-zram-tier-manager.timer" /etc/systemd/system/vmatlas-zram-tier-manager.timer

    # 8. Reload systemd daemon & enable services
    sudo systemctl daemon-reload
    sudo systemctl enable vmatlas-zram-mglru.service 2>/dev/null || true
    sudo systemctl enable vmatlas-zram-tier-manager.timer 2>/dev/null || true

    success "Installation and staging completed successfully!"
}

# Main Execution Flow
print_banner
detect_distro
check_dependencies
check_existing_config
check_kernel_capabilities

if [ "$INTERACTIVE" -eq 1 ]; then
    wizard_sizing
    wizard_tiering
    wizard_writeback
    wizard_vm_knobs
else
    autoscale_vm_knobs
fi

show_summary

if [ "$DRY_RUN" -eq 1 ]; then
    info "Dry run complete. No modifications were written to disk."
    exit 0
fi

if [ "$INTERACTIVE" -eq 1 ]; then
    printf '\n%s' "${BOLD}Proceed with installation to system? [Y/n]: ${RST}"
    read -r proceed_ans
    if [[ "$proceed_ans" =~ ^[Nn] ]]; then
        info "Installation cancelled by user."
        exit 0
    fi
fi

stage_and_install

# Live restart option
if [ "$LIVE_RESTART" -eq 1 ] || [ "$INTERACTIVE" -eq 1 ]; then
    if [ "$LIVE_RESTART" -eq 1 ]; then
        do_restart=1
    else
        printf '\n%s' "${BOLD}Would you like to live-rebuild and verify the ZRAM stack immediately without rebooting? [y/N]: ${RST}"
        read -r restart_ans
        [[ "$restart_ans" =~ ^[Yy] ]] && do_restart=1 || do_restart=0
    fi

    if [ "${do_restart:-0}" -eq 1 ]; then
        info "Executing live restart via 'vmatlas-zram restart'..."
        if [ "$FORCE_RESTART" -eq 1 ]; then
            sudo /usr/local/bin/vmatlas-zram restart --force
        else
            sudo /usr/local/bin/vmatlas-zram restart
        fi
        success "Live restart and verification complete!"
        sudo /usr/local/bin/vmatlas-zram status
        exit 0
    fi
fi

printf '\n%s\n' "${GREEN}${BOLD}Setup completed successfully!${RST}"
printf "Configuration will automatically take effect on the next boot.\n"
printf "To inspect or manage your ZRAM stack at any time, run:\n"
printf '  %s\n' "${BOLD}vmatlas-zram status${RST}"
printf '  %s\n' "${BOLD}vmatlas-zram doctor${RST}"
printf '  %s\n\n' "${BOLD}sudo vmatlas-zram restart${RST} (for live rebuild)"
