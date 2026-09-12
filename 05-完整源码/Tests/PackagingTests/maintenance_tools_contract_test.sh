#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h:h}"
CLEANUP="$ROOT/scripts/maintenance/pdd_safe_cleanup.py"
DIAGNOSTIC="$ROOT/scripts/maintenance/pdd_diagnostic_export.py"

test -s "$CLEANUP"
test -s "$DIAGNOSTIC"

python3 "$CLEANUP" --self-test
python3 "$DIAGNOSTIC" --self-test

print "维护与诊断合同测试通过"
