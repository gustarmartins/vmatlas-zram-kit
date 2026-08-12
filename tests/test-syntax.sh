#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

for script in install.sh uninstall.sh bin/vmatlas-zram libexec/vmatlas-zram-mglru; do
    bash -n "$ROOT/$script"
done

python3 - "$ROOT/libexec/vmatlas-zram-process" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
compile(source, sys.argv[1], "exec")
PY

grep -Fq 'Managed by vmatlas-zram-kit' "$ROOT/install.sh"
grep -Fq 'CONFIRM-EMERGENCY-WRITEBACK' "$ROOT/bin/vmatlas-zram"
grep -Fq 'CONFIRM-FORCE-WRITEBACK' "$ROOT/bin/vmatlas-zram"
grep -Fq 'CONFIRM-FORCE-RECOMPRESS' "$ROOT/bin/vmatlas-zram"
grep -Fq 'process_madvise(MADV_PAGEOUT)' "$ROOT/libexec/vmatlas-zram-process"
grep -Fq 'writeback=off' "$ROOT/profiles/android-dev-safe.env"
grep -Fq 'dedicated-empty-unmounted-raw-partition-only' "$ROOT/profiles/android-dev-tiered-writeback.env"

printf 'static checks passed\n'
