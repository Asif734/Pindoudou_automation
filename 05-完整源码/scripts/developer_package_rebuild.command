#!/bin/zsh
set -euo pipefail

SOURCE_ROOT="${0:A:h:h}"
PACKAGE_ROOT="${SOURCE_ROOT:h}"
APP="$PACKAGE_ROOT/02-正式程序/pinduodou_automation.app"

fail() { print -u2 -- "$*"; exit 1; }
test -d "$APP" || fail "缺少正式 App：$APP"
test -s "$SOURCE_ROOT/Package.swift" || fail "源码不完整"

for resource in WebOCR SenseVoice V2Knowledge KnowledgeBase; do
  source_path="$APP/Contents/Resources/$resource"
  target_path="$SOURCE_ROOT/Resources/$resource"
  test -d "$source_path" || fail "App 中缺少构建资源：$resource"
  if [[ ! -d "$target_path" ]]; then
    /usr/bin/ditto "$source_path" "$target_path"
  fi
done

cd "$SOURCE_ROOT"
swift test
./scripts/build_app.sh --task-isolation-candidate
./scripts/verify_task_isolation_candidate.sh
print "重新构建完成：$SOURCE_ROOT/outputs/pinduodou_automation.app"
