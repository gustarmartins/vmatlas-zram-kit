#!/usr/bin/env bash
# Stage a portable ZRAM profile for the next boot. It deliberately never resets
# or swaps off the live zram device.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
SELF="$SCRIPT_DIR/install.sh"
PROFILE=android-dev-safe
TIERED=0
WRITEBACK_DEVICE=
CONFIRM_WRITEBACK=0
ENABLE_COLD_TIMER=0
ADOPT_LOCAL_CONFIG=0
DRY_RUN=0
ORIGINAL_ARGS=("$@")

die() { printf 'install.sh: %s\n' "$*" >&2; exit 2; }
note() { printf '%s\n' "$*"; }

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
  --dry-run                        Print the plan; do not use sudo or write files.
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
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

[ "$PROFILE" = android-dev-safe ] || die "only android-dev-safe is currently installable"
[ "$ENABLE_COLD_TIMER" -eq 0 ] || [ -n "$WRITEBACK_DEVICE" ] || \
    die "--enable-cold-writeback-timer requires --writeback-device"
[ -z "$WRITEBACK_DEVICE" ] || [ "$CONFIRM_WRITEBACK" -eq 1 ] || \
    die "writeback requires --confirm-writeback-device"

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
    [ -e "$z/recomp_algorithm" ] && [ -e "$z/recompress" ] && [ -e "$z/algorithm_params" ] ||
        die "this running kernel does not prove multi-compressor ZRAM support"
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

show_plan() {
    if [ "$TIERED" -eq 1 ]; then
        note "Profile: $PROFILE + tiered zstd"
    else
        note "Profile: $PROFILE"
    fi
    note "Host RAM: ${RAM_MIB} MiB"
    note "Next-boot ZRAM: min(ram * 2, 32 GiB), resident cap ram / 2, zstd level 3"
    note "Next-boot VM: swappiness=120 vfs_cache_pressure=60 page-cluster=0"
    note "Scaled VM: min_free_kbytes=$MIN_FREE_KIB dirty_background_bytes=$DIRTY_BG dirty_bytes=$DIRTY MGLRU TTL=${MGLRU_TTL}ms"
    if [ -n "$WRITEBACK_DEVICE" ]; then
        note "Writeback: dedicated raw partition $WRITEBACK_DEVICE; 256 MiB cold passes, 4 GiB boot cap"
        note "Cold timer: $([ "$ENABLE_COLD_TIMER" -eq 1 ] && echo enabled-next-boot || echo disabled)"
    else
        note "Writeback: disabled"
    fi
    note "Live zram is untouched. Reboot is required to apply the generated configuration."
}

require_baseline
check_local_config
[ "$TIERED" -eq 0 ] || require_tiered_capability
host_values

if [ "$DRY_RUN" -eq 1 ]; then
    [ -z "$WRITEBACK_DEVICE" ] || note "Dry-run skips destructive-target validation; actual install will re-check the partition."
    show_plan
    exit 0
fi

if [ "${EUID}" -ne 0 ]; then
    exec sudo -- "$SELF" "${ORIGINAL_ARGS[@]}"
fi

validate_writeback_device
show_plan

zram_lines=(
    '# Managed by vmatlas-zram-kit. Changes apply on the next boot.'
    '[zram0]'
    'zram-size = min(ram * 2, 32 * 1024)'
    'zram-resident-limit = ram / 2'
    'swap-priority = 90'
)
if [ "$TIERED" -eq 1 ]; then
    zram_lines+=('compression-algorithm = zstd (level=3) zstd (level=12)')
else
    zram_lines+=('compression-algorithm = zstd (level=3)')
fi
[ -z "$WRITEBACK_DEVICE" ] || zram_lines+=("writeback-device = $WRITEBACK_DEVICE")

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

stage_lines /etc/systemd/zram-generator.conf.d/90-vmatlas-zram.conf 0644 "${zram_lines[@]}"
stage_lines /etc/sysctl.d/90-vmatlas-zram.conf 0644 "${sysctl_lines[@]}"
stage_lines /etc/vmatlas-zram/profile.env 0644 \
    '# Managed by vmatlas-zram-kit.' \
    "PROFILE=$PROFILE" \
    "TIERED=$TIERED" \
    "MGLRU_TTL_MS=$MGLRU_TTL"
install -D -o root -g root -m 0755 "$SCRIPT_DIR/bin/vmatlas-zram" /usr/local/bin/vmatlas-zram
install -D -o root -g root -m 0755 "$SCRIPT_DIR/libexec/vmatlas-zram-mglru" /usr/local/libexec/vmatlas-zram-mglru
install -D -o root -g root -m 0644 "$SCRIPT_DIR/systemd/vmatlas-zram-mglru.service" /etc/systemd/system/vmatlas-zram-mglru.service

if [ -n "$WRITEBACK_DEVICE" ]; then
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
fi

systemctl daemon-reload
systemctl enable vmatlas-zram-mglru.service >/dev/null
if [ "$ENABLE_COLD_TIMER" -eq 1 ]; then
    systemctl enable vmatlas-zram-writeback.timer >/dev/null
fi

note
note 'Staged successfully. Nothing reset live ZRAM and no reboot was requested.'
note 'Reboot when you are ready, then run: vmatlas-zram status'
