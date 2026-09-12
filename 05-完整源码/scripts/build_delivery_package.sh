#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
STAMP="$(date +%Y%m%d-%H%M%S)"
DELIVERY_PARENT="${PDD_DELIVERY_OUTPUT_DIR:-$PROJECT_ROOT/outputs/delivery}"
PACKAGE_NAME="拼多多全自动客服-同事完整交付包-$STAMP"
STAGE="$DELIVERY_PARENT/$PACKAGE_NAME"
ZIP="$DELIVERY_PARENT/$PACKAGE_NAME.zip"
APP="$PROJECT_ROOT/outputs/pinduodou_automation.app"
PDF_GUIDE="$PROJECT_ROOT/output/pdf/拼多多全自动客服-同事首次设置与维护手册-中英双语版.pdf"

fail() { print -u2 -- "$*"; exit 1; }
test -x "$PROJECT_ROOT/scripts/build_app.sh" || fail "缺少构建脚本"
test -s "$PDF_GUIDE" || fail "缺少中英双语图文手册：$PDF_GUIDE"

if [[ "${1:-}" != "--skip-tests" ]]; then
  cd "$PROJECT_ROOT"
  swift test
fi
"$PROJECT_ROOT/scripts/build_app.sh" --task-isolation-candidate
"$PROJECT_ROOT/scripts/verify_task_isolation_candidate.sh"

mkdir -p "$DELIVERY_PARENT"
test ! -e "$STAGE" || fail "目标已存在：$STAGE"
test ! -e "$ZIP" || fail "目标已存在：$ZIP"
mkdir -p \
  "$STAGE/00-把这个文件交给Codex" \
  "$STAGE/01-安装" \
  "$STAGE/02-正式程序" \
  "$STAGE/03-自动维护" \
  "$STAGE/04-故障处理" \
  "$STAGE/05-完整源码"

/usr/bin/ditto "$PROJECT_ROOT/Packaging/00-把这个文件交给Codex" "$STAGE/00-把这个文件交给Codex"
/usr/bin/ditto "$PDF_GUIDE" "$STAGE/00-把这个文件交给Codex/拼多多全自动客服-同事首次设置与维护手册-中英双语版.pdf"
/usr/bin/ditto "$APP" "$STAGE/02-正式程序/${APP:t}"
/usr/bin/ditto "$PROJECT_ROOT/Packaging/自动维护" "$STAGE/03-自动维护"
/usr/bin/ditto "$PROJECT_ROOT/Packaging/故障处理" "$STAGE/04-故障处理"
/usr/bin/ditto "$PROJECT_ROOT/scripts/maintenance/pdd_safe_cleanup.py" "$STAGE/03-自动维护/pdd_safe_cleanup.py"
/usr/bin/ditto "$PROJECT_ROOT/scripts/maintenance/pdd_diagnostic_export.py" "$STAGE/04-故障处理/pdd_diagnostic_export.py"

/usr/bin/rsync -a \
  --exclude '.build' \
  --exclude 'outputs' \
  --exclude '.DS_Store' \
  --exclude 'Resources/WebOCR' \
  --exclude 'Resources/SenseVoice' \
  --exclude 'Resources/V2Knowledge' \
  --exclude 'Resources/KnowledgeBase' \
  --exclude '/Tools/PDDVideoDirectProbe/dist/' \
  --exclude '/Tools/PDDVideoDirectProbe/backups/' \
  "$PROJECT_ROOT/" "$STAGE/05-完整源码/"
/usr/bin/ditto "$PROJECT_ROOT/scripts/developer_package_rebuild.command" "$STAGE/05-完整源码/scripts/developer_package_rebuild.command"

chmod +x \
  "$STAGE/03-自动维护/检查并安全清理.command" \
  "$STAGE/03-自动维护/安装每日自动清理.command" \
  "$STAGE/03-自动维护/pdd_safe_cleanup.py" \
  "$STAGE/04-故障处理/一键导出脱敏诊断包.command" \
  "$STAGE/04-故障处理/pdd_diagnostic_export.py" \
  "$STAGE/05-完整源码/scripts/developer_package_rebuild.command"

/usr/bin/osacompile -o "$STAGE/01-安装/安装并启动拼多多客服.app" "$PROJECT_ROOT/scripts/installer/PDDInstaller.applescript"
SIGNING_IDENTITY="$($PROJECT_ROOT/scripts/select_codesign_identity.sh)"
/usr/bin/codesign --force --deep --options runtime --timestamp=none --sign "$SIGNING_IDENTITY" "$STAGE/01-安装/安装并启动拼多多客服.app"
/usr/bin/codesign --verify --deep --strict "$STAGE/01-安装/安装并启动拼多多客服.app"

DMG="$STAGE/01-安装/pinduodou_automation.dmg"
/usr/bin/hdiutil create -quiet -fs HFS+ -format UDZO -volname "拼多多全自动客服" -srcfolder "$STAGE/02-正式程序" "$DMG"

SOURCE="$STAGE/05-完整源码"
print -r -- "# 源码版本说明\n\n本源码从 2026-09-04 当前已验证工作目录建立交付基线。原工作目录没有 .git 元数据，因此此仓库从本次交付开始记录完整历史；没有伪造此前提交。大型离线资源由同目录的正式 App 提供，运行 scripts/developer_package_rebuild.command 会自动还原后构建。" > "$SOURCE/源码版本说明.md"
(
  cd "$SOURCE"
  git init -q
  git config user.name "PDD Delivery Baseline"
  git config user.email "pdd-delivery@local.invalid"
  git add .
  git commit -q -m "PDD auto-reply colleague delivery baseline $STAMP"
)

(
  cd "$STAGE"
  /usr/bin/find . -type f ! -path './SHA-256校验清单.txt' -print0 \
    | /usr/bin/sort -z \
    | /usr/bin/xargs -0 shasum -a 256 > "SHA-256校验清单.txt"
)

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$ZIP"
shasum -a 256 "$ZIP" > "$ZIP.sha256.txt"
print "$ZIP"
print "$ZIP.sha256.txt"
