#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

for script in install.sh uninstall.sh bin/vmatlas-zram libexec/vmatlas-zram-mglru; do
    bash -n "$ROOT/$script"
done

grep -Fq 'Managed by vmatlas-zram-kit' "$ROOT/install.sh"
grep -Fq 'CONFIRM-EMERGENCY-WRITEBACK' "$ROOT/bin/vmatlas-zram"
grep -Fq 'writeback=off' "$ROOT/profiles/android-dev-safe.env"
grep -Fq 'dedicated-empty-unmounted-raw-partition-only' "$ROOT/profiles/android-dev-tiered-writeback.env"

printf 'static checks passed\n'
