#!/usr/bin/env bash
# Stage a portable ZRAM profile for the next boot. It deliberately never resets
# or swaps off the live zram device.
set -Eeuo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

header() { printf "\n${BLUE}=== %s ===${NC}\n" "$*"; }
info() { printf "${CYAN}%s${NC}\n" "$*"; }
success() { printf "${GREEN}✓ %s${NC}\n" "$*"; }
warn() { printf "${YELLOW}⚠ %s${NC}\n" "$*"; }
error() { printf "${RED}✗ %s${NC}\n" "$*"; }
die() { printf "${RED}install.sh: %s${NC}\n" "$*" >&2; exit 2; }
note() { printf '%s\n' "$*"; }

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
SELF="$SCRIPT_DIR/install.sh"
PROFILE=android-dev-safe
TIERED=0
WRITEBACK_DEVICE=
CONFIRM_WRITEBACK=0
ENABLE_COLD_TIMER=0
ADOPT_LOCAL_CONFIG=0
APPLY_NOW=0
DRY_RUN=0
YES_TO_ALL=0
ORIGINAL_ARGS=("$@")

usage() {
    cat <<'EOF'
usage: ./install.sh [options]

Options:
  --profile android-dev-safe       The default and only baseline profile.
  --tiered                         Stage zstd level 12 as a secondary compressor.
  --writeback-device PATH          Dedicated empty raw partition, never a file.
  --confirm-writeback-device       Required with --writeback-device.
  --enable-cold-writeback-timer    Enable the optional hourly cold-page timer.
  --adopt-local-zram-config        Explicitly permit override of local /etc ZRAM config.
  --apply-now                      Apply the profile immediately instead of waiting for reboot.
  --dry-run                        Print the plan; do not use sudo or write files.
  -y, --yes                        Skip prompts (auto-accept).
  -h, --help                       Show this help.

The resulting ZRAM configuration applies on the next reboot only.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --profile) PROFILE=${2:-}; shift 2 ;;
        --tiered) TIERED=1; shift ;;
        --writeback-device) WRITEBACK_DEVICE=${2:-}; shift 2 ;;
        --confirm-writeback-device) CONFIRM_WRITEBACK=1; shift ;;
        --enable-cold-writeback-timer) ENABLE_COLD_TIMER=1; shift ;;
        --adopt-local-zram-config) ADOPT_LOCAL_CONFIG=1; shift ;;
        --apply-now) APPLY_NOW=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -y|--yes) YES_TO_ALL=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

[ "$PROFILE" = android-dev-safe ] || die "only android-dev-safe is currently installable"
[ "$ENABLE_COLD_TIMER" -eq 0 ] || [ -n "$WRITEBACK_DEVICE" ] || \
    die "--enable-cold-writeback-timer requires --writeback-device"
[ -z "$WRITEBACK_DEVICE" ] || [ "$CONFIRM_WRITEBACK" -eq 1 ] || \
    die "writeback requires --confirm-writeback-device"

ask() {
    local prompt="$1"
    local default="${2:-Y}"
    local ans

    if [ "$DRY_RUN" -eq 1 ]; then
        return 0
    fi

    if [ "$YES_TO_ALL" -eq 1 ]; then
        if [ "$default" = "Y" ]; then
            success "auto-accepted"
        else
            warn "auto-skipped (default N)"
        fi
        [ "$default" = "Y" ] && return 0 || return 1
    fi

    if [ "$default" = "Y" ]; then
        prompt="${prompt} [Y/n] "
    else
        prompt="${prompt} [y/N] "
    fi

    printf "${YELLOW}%s${NC}" "$prompt"
    read -rp "" ans
    ans=${ans:-$default}

    case "$ans" in
        [Yy]* ) return 0 ;;
        * ) return 1 ;;
    esac
}

generator_path() {
    local candidate
    for candidate in \
        /usr/lib/systemd/system-generators/zram-generator \
        /usr/libexec/systemd/system-generators/zram-generator; do
        [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
    done
    command -v zram-generator 2>/dev/null || return 1
}

require_baseline() {
    [ -d /run/systemd/system ] || die "systemd is not PID 1; this kit needs systemd"
    command -v systemctl >/dev/null 2>&1 || die "systemctl is required"
    GENERATOR=$(generator_path) || die "zram-generator is missing; install the distribution package first"
    [ -x "$GENERATOR" ] || die "zram-generator is not executable"
}

is_owned_config() {
    [ -f "$1" ] && grep -Fqs 'Managed by vmatlas-zram-kit' "$1"
}

check_local_config() {
    local path
    [ "$ADOPT_LOCAL_CONFIG" -eq 1 ] && return 0
    for path in /etc/systemd/zram-generator.conf /run/systemd/zram-generator.conf; do
        [ ! -e "$path" ] || is_owned_config "$path" ||
            die "local ZRAM configuration exists at $path; inspect it or rerun with --adopt-local-zram-config"
    done
    shopt -s nullglob
    for path in /etc/systemd/zram-generator.conf.d/*.conf /run/systemd/zram-generator.conf.d/*.conf; do
        [ "${path##*/}" = 90-vmatlas-zram.conf ] && continue
        is_owned_config "$path" ||
            die "local ZRAM configuration exists at $path; inspect it or rerun with --adopt-local-zram-config"
    done
    shopt -u nullglob
}

require_tiered_capability() {
    local z=/sys/block/zram0
    [ -d "$z" ] || die "--tiered needs one safe-profile boot first so its kernel support can be proven"
    if ! { [ -e "$z/recomp_algorithm" ] && [ -e "$z/recompress" ] && [ -e "$z/algorithm_params" ]; }; then
        die "this running kernel does not prove multi-compressor ZRAM support"
    fi
    grep -qw zstd "$z/comp_algorithm" 2>/dev/null ||
        die "the running zram device does not advertise zstd"
}

validate_writeback_device() {
    local resolved type fstype mounts signatures
    [ -n "$WRITEBACK_DEVICE" ] || return 0
    resolved=$(readlink -f -- "$WRITEBACK_DEVICE") || die "cannot resolve writeback device: $WRITEBACK_DEVICE"
    [ -b "$resolved" ] || die "writeback target is not a block device: $WRITEBACK_DEVICE"
    type=$(lsblk -ndo TYPE "$resolved" 2>/dev/null | head -n1)
    [ "$type" = part ] || die "writeback target must be a dedicated partition, not $type"
    fstype=$(lsblk -ndo FSTYPE "$resolved" 2>/dev/null | head -n1 || true)
    [ -z "$fstype" ] || die "writeback target has filesystem type '$fstype'"
    mounts=$(lsblk -ndo MOUNTPOINTS "$resolved" 2>/dev/null | tr -d '[:space:]')
    [ -z "$mounts" ] || die "writeback target is mounted: $mounts"
    grep -Fq -- "$resolved" /proc/swaps && die "writeback target is active swap"
    signatures=$(wipefs -n --noheadings "$resolved" 2>/dev/null || true)
    [ -z "$signatures" ] || die "writeback target has an on-disk signature; do not reuse it"
    WRITEBACK_DEVICE=$resolved
}

host_values() {
    local ram_kib
    ram_kib=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)
    [ -n "$ram_kib" ] || die "cannot read host RAM"
    if [ "$ram_kib" -le $((8 * 1024 * 1024)) ]; then
        MIN_FREE_KIB=65536
        DIRTY_BG=33554432
        DIRTY=134217728
        MGLRU_TTL=1000
    elif [ "$ram_kib" -le $((32 * 1024 * 1024)) ]; then
        MIN_FREE_KIB=131072
        DIRTY_BG=67108864
        DIRTY=268435456
        MGLRU_TTL=2000
    else
        MIN_FREE_KIB=131072
        DIRTY_BG=134217728
        DIRTY=536870912
        MGLRU_TTL=2000
    fi
    RAM_MIB=$((ram_kib / 1024))
}

stage_lines() {
    local target=$1 mode=$2 temp
    shift 2
    temp=$(mktemp)
    printf '%s\n' "$@" >"$temp"
    install -D -o root -g root -m "$mode" "$temp" "$target"
    rm -f -- "$temp"
}

get_sysctl() {
    sysctl -n "$1" 2>/dev/null || echo "not set"
}

# --- Initialization & pre-flight ---
header "vmatlas-zram-kit installer"

require_baseline
check_local_config
[ "$TIERED" -eq 0 ] || require_tiered_capability
host_values

# Elevate to root before interactive prompts (dry-run stays unprivileged)
if [ "${EUID}" -ne 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    info "Requesting root access..."
    exec sudo -- "$SELF" "${ORIGINAL_ARGS[@]}"
fi

[ "$DRY_RUN" -eq 1 ] || validate_writeback_device

kernel_ver=$(uname -r)
info "Host RAM: ${RAM_MIB} MiB"
info "Kernel: $kernel_ver"

# --- Phase 1: Profile selection ---
header "Phase 1: Profile Information"
info "Selected profile: ${BOLD}$PROFILE${NC}"
info "Computed Host-Scaled Values:"
info "  min_free_kbytes: $MIN_FREE_KIB"
info "  dirty_bytes:     $DIRTY"
info "  MGLRU TTL:       ${MGLRU_TTL}ms"

# --- Variables to track what we will do ---
DO_ZRAM=0
DO_SYSCTL=0
DO_MGLRU=0
DO_TIERED=0
DO_WRITEBACK=0
DO_COLD_TIMER=0
DO_CLI=0

# --- Phase 2: Step-by-step confirmation ---

header "1. ZRAM Configuration (zram-generator drop-in)"
current_zram_size=$(zramctl zram0 --output SIZE --noheadings 2>/dev/null || echo "not created")
current_zram_comp=$(zramctl zram0 --output ALGORITHM --noheadings 2>/dev/null || echo "unknown")
echo -e "Current state: size=${BOLD}${current_zram_size}${NC} comp=${BOLD}${current_zram_comp}${NC}"
echo -e "Will set: zram-size=min(ram*2, 32G), cap=ram/2, comp=zstd(3), prio=90"
if ask "Install ZRAM configuration?" "Y"; then
    DO_ZRAM=1
fi

header "2. VM / sysctl tuning"
current_swappiness=$(get_sysctl vm.swappiness)
current_vfs=$(get_sysctl vm.vfs_cache_pressure)
current_page=$(get_sysctl vm.page-cluster)
echo -e "Current state: swappiness=${BOLD}${current_swappiness}${NC}, vfs_cache_pressure=${BOLD}${current_vfs}${NC}, page-cluster=${BOLD}${current_page}${NC}"
echo -e "Will set: swappiness=120, vfs_cache_pressure=60, page-cluster=0 + host-scaled dirty/min_free values"
if ask "Install sysctl tuning?" "Y"; then
    DO_SYSCTL=1
fi

header "3. MGLRU (boot service)"
if [ -f /sys/kernel/mm/lru_gen/enabled ]; then
    current_mglru=$(cat /sys/kernel/mm/lru_gen/enabled)
    current_mglru_ttl=$(cat /sys/kernel/mm/lru_gen/min_ttl_ms 2>/dev/null || echo "0")
    echo -e "Current state: enabled=${BOLD}${current_mglru}${NC}, min_ttl_ms=${BOLD}${current_mglru_ttl}${NC}"
else
    echo -e "Current state: ${BOLD}MGLRU not supported by kernel${NC}"
fi
echo -e "Will set: enable MGLRU with TTL of ${BOLD}${MGLRU_TTL}ms${NC} on boot"
if ask "Install MGLRU boot service?" "Y"; then
    DO_MGLRU=1
fi

if [ "$TIERED" -eq 1 ]; then
    header "4. Tiered compression"
    current_recomp=$(cat /sys/block/zram0/recomp_algorithm 2>/dev/null || echo "not supported/enabled")
    echo -e "Current state: recomp_algorithm=${BOLD}${current_recomp}${NC}"
    echo -e "Will set: zstd level 12 secondary compressor"
    if ask "Install tiered compression?" "Y"; then
        DO_TIERED=1
    fi
fi

if [ -n "$WRITEBACK_DEVICE" ]; then
    header "5. Writeback device"
    current_backing=$(cat /sys/block/zram0/backing_dev 2>/dev/null || echo "none")
    echo -e "Current state: backing_dev=${BOLD}${current_backing}${NC}"
    echo -e "Will set: Dedicated writeback to ${BOLD}$WRITEBACK_DEVICE${NC}"
    if ask "Install writeback configuration?" "Y"; then
        DO_WRITEBACK=1
    fi

    if [ "$ENABLE_COLD_TIMER" -eq 1 ]; then
        header "6. Cold writeback timer"
        echo -e "Current state: N/A"
        echo -e "Will set: Hourly timer, 24h idle age, 256 MiB passes"
        if ask "Enable cold writeback timer?" "N"; then
            DO_COLD_TIMER=1
        fi
    fi
fi

header "7. Install CLI tools"
echo -e "Will install:"
echo "  - /usr/local/bin/vmatlas-zram"
echo "  - /usr/local/libexec/vmatlas-zram-mglru"
echo "  - /usr/local/libexec/vmatlas-zram-process"
if ask "Install CLI tools and helpers?" "Y"; then
    DO_CLI=1
fi

if [ "$DRY_RUN" -eq 1 ]; then
    header "Dry Run Completed"
    note "Exiting without applying changes."
    exit 0
fi

# --- Phase 3: Execution ---
header "Phase 3: Execution"

if [ "$DO_ZRAM" -eq 1 ] || [ "$DO_TIERED" -eq 1 ] || [ "$DO_WRITEBACK" -eq 1 ]; then
    zram_lines=(
        '# Managed by vmatlas-zram-kit. Changes apply on the next boot.'
        '[zram0]'
        'zram-size = min(ram * 2, 32 * 1024)'
        'zram-resident-limit = ram / 2'
        'swap-priority = 90'
    )
    if [ "$DO_TIERED" -eq 1 ]; then
        zram_lines+=('compression-algorithm = zstd (level=3) zstd (level=12)')
    else
        zram_lines+=('compression-algorithm = zstd (level=3)')
    fi
    [ "$DO_WRITEBACK" -eq 0 ] || zram_lines+=("writeback-device = $WRITEBACK_DEVICE")
    stage_lines /etc/systemd/zram-generator.conf.d/90-vmatlas-zram.conf 0644 "${zram_lines[@]}"
    success "Staged ZRAM generator configuration"
else
    warn "Skipped ZRAM generator configuration"
fi

if [ "$DO_SYSCTL" -eq 1 ]; then
    sysctl_lines=(
        '# Managed by vmatlas-zram-kit. Host-scaled Android build profile.'
        'vm.swappiness = 120'
        'vm.vfs_cache_pressure = 60'
        'vm.page-cluster = 0'
        "vm.min_free_kbytes = $MIN_FREE_KIB"
        'vm.watermark_scale_factor = 100'
        'vm.watermark_boost_factor = 15000'
        'vm.zone_reclaim_mode = 0'
        'vm.dirty_background_ratio = 0'
        'vm.dirty_ratio = 0'
        "vm.dirty_background_bytes = $DIRTY_BG"
        "vm.dirty_bytes = $DIRTY"
        'vm.dirty_expire_centisecs = 3000'
        'vm.dirty_writeback_centisecs = 1500'
        'vm.compaction_proactiveness = 0'
        'vm.compact_unevictable_allowed = 1'
        'vm.defrag_mode = 0'
        'vm.extfrag_threshold = 750'
        'vm.max_map_count = 1048576'
    )
    stage_lines /etc/sysctl.d/90-vmatlas-zram.conf 0644 "${sysctl_lines[@]}"
    success "Staged sysctl tuning"
else
    warn "Skipped sysctl tuning"
fi

# Always write profile.env since it tracks global state for tools
if [ "$DO_CLI" -eq 1 ] || [ "$DO_MGLRU" -eq 1 ]; then
    stage_lines /etc/vmatlas-zram/profile.env 0644 \
        '# Managed by vmatlas-zram-kit.' \
        "PROFILE=$PROFILE" \
        "TIERED=$DO_TIERED" \
        "MGLRU_TTL_MS=$MGLRU_TTL"
fi

if [ "$DO_CLI" -eq 1 ]; then
    install -D -o root -g root -m 0755 "$SCRIPT_DIR/bin/vmatlas-zram" /usr/local/bin/vmatlas-zram
    install -D -o root -g root -m 0755 "$SCRIPT_DIR/libexec/vmatlas-zram-process" /usr/local/libexec/vmatlas-zram-process
    success "Installed CLI tools"
else
    warn "Skipped CLI tools"
fi

if [ "$DO_MGLRU" -eq 1 ]; then
    install -D -o root -g root -m 0755 "$SCRIPT_DIR/libexec/vmatlas-zram-mglru" /usr/local/libexec/vmatlas-zram-mglru
    install -D -o root -g root -m 0644 "$SCRIPT_DIR/systemd/vmatlas-zram-mglru.service" /etc/systemd/system/vmatlas-zram-mglru.service
    success "Installed MGLRU boot service"
else
    warn "Skipped MGLRU service"
fi

if [ "$DO_WRITEBACK" -eq 1 ]; then
    stage_lines /etc/vmatlas-zram/writeback.env 0644 \
        '# Managed by vmatlas-zram-kit.' \
        "WRITEBACK_DEVICE=$WRITEBACK_DEVICE" \
        'COLD_PASS_MIB=256' \
        'BOOT_CAP_MIB=4096' \
        'EMERGENCY_CAP_MIB=1024' \
        'IDLE_AGE_SECONDS=86400'
    stage_lines /etc/systemd/system/systemd-zram-setup@zram0.service.d/90-vmatlas-zram-writeback.conf 0644 \
        '[Service]' \
        "ExecStartPost=/usr/bin/bash -c 'if [ -e /sys/block/%i/compressed_writeback ]; then echo yes > /sys/block/%i/compressed_writeback; fi'" \
        "ExecStartPost=/usr/bin/bash -c 'if [ -e /sys/block/%i/writeback_limit ]; then echo 0 > /sys/block/%i/writeback_limit; echo 1 > /sys/block/%i/writeback_limit_enable; fi'"
    install -D -o root -g root -m 0644 "$SCRIPT_DIR/systemd/vmatlas-zram-writeback.service" /etc/systemd/system/vmatlas-zram-writeback.service
    install -D -o root -g root -m 0644 "$SCRIPT_DIR/systemd/vmatlas-zram-writeback.timer" /etc/systemd/system/vmatlas-zram-writeback.timer
    success "Installed writeback configuration"
else
    if [ -n "$WRITEBACK_DEVICE" ]; then
        warn "Skipped writeback configuration"
    fi
fi

if [ "$DO_COLD_TIMER" -eq 1 ]; then
    success "Enabled cold writeback timer"
else
    if [ -n "$WRITEBACK_DEVICE" ] && [ "$ENABLE_COLD_TIMER" -eq 1 ]; then
        warn "Skipped cold writeback timer"
    fi
fi

# Consolidate daemon-reload and service enablement
systemctl daemon-reload
[ "$DO_MGLRU" -eq 0 ] || systemctl enable vmatlas-zram-mglru.service >/dev/null
[ "$DO_COLD_TIMER" -eq 0 ] || systemctl enable vmatlas-zram-writeback.timer >/dev/null

# --- Phase 4: Apply or stage ---
header "Summary"

if [ "$APPLY_NOW" -eq 1 ]; then
    info 'Applying changes live...'
    [ "$DO_SYSCTL" -eq 0 ] || sysctl --system >/dev/null 2>&1 || warn 'sysctl apply failed'
    [ "$DO_MGLRU" -eq 0 ] || systemctl start vmatlas-zram-mglru.service 2>/dev/null || true
    if [ "$DO_ZRAM" -eq 1 ] || [ "$DO_TIERED" -eq 1 ] || [ "$DO_WRITEBACK" -eq 1 ]; then
        if systemctl list-unit-files 'systemd-zram-setup@.service' >/dev/null 2>&1; then
            systemctl restart systemd-zram-setup@zram0.service 2>/dev/null || true
        fi
    fi
    success 'Profile applied live. Run: vmatlas-zram status'
else
    success 'Staged for next reboot. Live ZRAM untouched.'
    info 'Reboot when ready, then run: vmatlas-zram status'
fi
