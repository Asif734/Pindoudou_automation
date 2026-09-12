#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
python3 "$SCRIPT_DIR/pdd_diagnostic_export.py"
read -k 1 "?按任意键关闭…"
