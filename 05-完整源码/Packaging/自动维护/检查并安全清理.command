#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
python3 "$SCRIPT_DIR/pdd_safe_cleanup.py"
read -k 1 "?按任意键关闭…"
