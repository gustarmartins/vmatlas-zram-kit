#!/usr/bin/env bash
# uninstall.sh: Safely remove files and services installed by vmatlas-zram-kit
# Managed by vmatlas-zram-kit
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
SELF="$SCRIPT_DIR/uninstall.sh"
DRY_RUN=0
ORIGINAL_ARGS=("$@")

die() { printf 'uninstall.sh: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

usage() {
    cat <<'EOF'
usage: sudo ./uninstall.sh [--dry-run]

Removes vmatlas-zram-kit system configurations, drop-ins, and systemd units.
Does not reset live /dev/zram0 or force swapoff.
EOF
}

case "${1:-}" in
    '') ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
esac

owned() { [ -f "$1" ] && grep -Fqs 'vmatlas-zram' "$1"; }

targets=(
    /etc/systemd/zram-generator.conf.d/90-vmatlas-zram.conf
    /etc/sysctl.d/90-vmatlas-zram.conf
    /etc/vmatlas-zram/tiers.conf
    /etc/vmatlas-zram/profile.env
    /etc/vmatlas-zram/writeback.env
    /etc/systemd/system/systemd-zram-setup@zram0.service.d/10-vmatlas-tier.conf
    /etc/systemd/system/systemd-zram-setup@zram0.service.d/90-vmatlas-zram-writeback.conf
    /etc/systemd/system/vmatlas-zram-mglru.service
    /etc/systemd/system/vmatlas-zram-tier-manager.service
    /etc/systemd/system/vmatlas-zram-tier-manager.timer
    /etc/systemd/system/vmatlas-zram-writeback.service
    /etc/systemd/system/vmatlas-zram-writeback.timer
    /usr/local/bin/vmatlas-zram
    /usr/local/libexec/vmatlas-zram-tier-init
    /usr/local/libexec/vmatlas-zram-tier-manager
    /usr/local/libexec/vmatlas-zram-mglru
    /usr/local/libexec/vmatlas-zram-process
)

note 'Scanning for installed vmatlas-zram-kit components...'
for target in "${targets[@]}"; do
    if [ -e "$target" ]; then
        note "  Found: $target"
    fi
done

if [ "$DRY_RUN" -eq 1 ]; then
    note 'Dry run complete. No system files were modified or removed.'
    exit 0
fi

if [ "${EUID}" -ne 0 ]; then
    exec sudo -- "$SELF" "${ORIGINAL_ARGS[@]}"
fi

note 'Disabling systemd units...'
systemctl disable --now vmatlas-zram-tier-manager.timer 2>/dev/null || true
systemctl disable --now vmatlas-zram-writeback.timer 2>/dev/null || true
systemctl disable vmatlas-zram-mglru.service 2>/dev/null || true
systemctl disable vmatlas-zram-tier-manager.service 2>/dev/null || true
systemctl disable vmatlas-zram-writeback.service 2>/dev/null || true

note 'Removing kit files...'
rm -f -- "${targets[@]}"
rmdir --ignore-fail-on-non-empty /etc/vmatlas-zram \
    /etc/systemd/system/systemd-zram-setup@zram0.service.d \
    /etc/systemd/zram-generator.conf.d 2>/dev/null || true

systemctl daemon-reload
note 'vmatlas-zram-kit successfully uninstalled. Changes will take full effect on next reboot.'
