#!/usr/bin/env bash
# Remove only files installed by this kit. Live ZRAM and active swap stay intact.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
SELF="$SCRIPT_DIR/uninstall.sh"
DRY_RUN=0
ORIGINAL_ARGS=("$@")

die() { printf 'uninstall.sh: %s\n' "$*" >&2; exit 2; }
note() { printf '%s\n' "$*"; }

usage() {
    cat <<'EOF'
usage: sudo ./uninstall.sh [--dry-run]

Removes only vmatlas-zram-kit files. It does not reset /dev/zram0, call
swapoff, delete a backing partition, or reboot. Reboot later to use the
previous next-boot configuration.
EOF
}

case "${1:-}" in
    '') ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
esac

owned() { [ -f "$1" ] && grep -Fqs 'Managed by vmatlas-zram-kit' "$1"; }

targets=(
    /etc/systemd/zram-generator.conf.d/90-vmatlas-zram.conf
    /etc/sysctl.d/90-vmatlas-zram.conf
    /etc/systemd/system/systemd-zram-setup@zram0.service.d/90-vmatlas-zram-writeback.conf
)

note 'The current live ZRAM device will not be reset or changed.'
for target in "${targets[@]}"; do
    if owned "$target"; then
        note "remove: $target"
    elif [ -e "$target" ]; then
        die "refusing to remove unrecognized file: $target"
    fi
done
for target in /etc/vmatlas-zram/profile.env /etc/vmatlas-zram/writeback.env; do
    if owned "$target"; then
        note "remove: $target"
    elif [ -e "$target" ]; then
        die "refusing to remove unrecognized file: $target"
    fi
done
for target in /etc/systemd/system/vmatlas-zram-mglru.service /etc/systemd/system/vmatlas-zram-writeback.service /etc/systemd/system/vmatlas-zram-writeback.timer; do
    if [ -f "$target" ] && ! grep -Fqs 'vmatlas-zram' "$target"; then
        die "refusing to remove unrecognized unit: $target"
    fi
    [ ! -e "$target" ] || note "remove: $target"
done
for target in /usr/local/bin/vmatlas-zram /usr/local/libexec/vmatlas-zram-mglru /usr/local/libexec/vmatlas-zram-process; do
    if [ -f "$target" ] && ! grep -Fqs 'vmatlas-zram-kit' "$target"; then
        die "refusing to remove unrecognized executable: $target"
    fi
    [ ! -e "$target" ] || note "remove: $target"
done

if [ "$DRY_RUN" -eq 1 ]; then
    note 'Dry run complete. No file or unit state changed.'
    exit 0
fi

if [ "${EUID}" -ne 0 ]; then
    exec sudo -- "$SELF" "${ORIGINAL_ARGS[@]}"
fi

systemctl disable vmatlas-zram-mglru.service >/dev/null 2>&1 || true
systemctl disable vmatlas-zram-writeback.timer >/dev/null 2>&1 || true
rm -f -- "${targets[@]}" \
    /etc/vmatlas-zram/profile.env \
    /etc/vmatlas-zram/writeback.env \
    /etc/systemd/system/vmatlas-zram-mglru.service \
    /etc/systemd/system/vmatlas-zram-writeback.service \
    /etc/systemd/system/vmatlas-zram-writeback.timer \
    /usr/local/bin/vmatlas-zram \
    /usr/local/libexec/vmatlas-zram-mglru \
    /usr/local/libexec/vmatlas-zram-process
rmdir --ignore-fail-on-non-empty /etc/vmatlas-zram \
    /etc/systemd/system/systemd-zram-setup@zram0.service.d \
    /etc/systemd/zram-generator.conf.d 2>/dev/null || true
systemctl daemon-reload
note 'Removed vmatlas-zram-kit next-boot files. Reboot later when convenient.'
