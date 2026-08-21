#!/usr/bin/env bash
# Syntax and integrity test suite for vmatlas-zram-kit
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

for script in install.sh uninstall.sh bin/vmatlas-zram \
              libexec/vmatlas-zram-tier-init libexec/vmatlas-zram-tier-manager \
              libexec/vmatlas-zram-mglru tests/vm/launch-test-vm.sh; do
    bash -n "$ROOT/$script"
done

python3 - "$ROOT/libexec/vmatlas-zram-process" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
compile(source, sys.argv[1], "exec")
PY

grep -Fq 'Managed by vmatlas-zram-kit' "$ROOT/install.sh"
grep -Fq 'vmatlas-zram' "$ROOT/bin/vmatlas-zram"
grep -Fq 'algorithm_params' "$ROOT/libexec/vmatlas-zram-tier-init"
grep -Fq 'vmatlas-tier-manager' "$ROOT/libexec/vmatlas-zram-tier-manager"
grep -Fq 'process_madvise(MADV_PAGEOUT)' "$ROOT/libexec/vmatlas-zram-process"

printf 'All static syntax and structural checks passed successfully.\n'
