#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h:h}"
MANUAL="$ROOT/Packaging/00-把这个文件交给Codex/完整接管、安装、配置与Debug手册.md"
INSTALLER="$ROOT/scripts/installer/PDDInstaller.applescript"
BUILD="$ROOT/scripts/build_delivery_package.sh"
MAINTENANCE_INSTALLER="$ROOT/Packaging/自动维护/安装每日自动清理.command"

test -s "$MANUAL"
test -s "$INSTALLER"
test -x "$BUILD"
test -x "$MAINTENANCE_INSTALLER"

for phrase in \
  "辅助功能" \
  "屏幕录制" \
  "语音识别" \
  "客服 ID" \
  "兼容性检查" \
  "30 天" \
  "10 GB" \
  "8 GB" \
  "禁止导出客户消息" \
  "Codex"; do
  grep -Fq "$phrase" "$MANUAL"
done

grep -Fq '拼多多全自动客服-任务隔离候选版.app' "$INSTALLER"
grep -Fq '/Applications' "$INSTALLER"
grep -Fq '完整源码' "$BUILD"
grep -Fq 'SHA-256' "$BUILD"
grep -Fq 'Library/Application Support/PDDAutoReplyMaintenance' "$MAINTENANCE_INSTALLER"

print "同事交付合同测试通过"
