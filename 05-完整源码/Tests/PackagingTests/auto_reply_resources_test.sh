#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h:h}"
APP="$PROJECT_ROOT/outputs/pinduodou_automation.app"
RESOURCE_ROOT="$APP/Contents/Resources"

"$PROJECT_ROOT/scripts/build_app.sh" --task-isolation-candidate >/dev/null

test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" = \
    "com.scy.pdd-auto-reply.task-isolation-candidate"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")" = \
    "PDDTaskIsolationCandidate"
test -x "$APP/Contents/MacOS/PDDTaskIsolationCandidate"

test -f "$RESOURCE_ROOT/CustomerService/customer-reply-prompt.md"
test -f "$RESOURCE_ROOT/V2Knowledge/retrieve_top12.py"
test -d "$RESOURCE_ROOT/V2Knowledge/site-packages"
test -d "$RESOURCE_ROOT/V2Knowledge/cache"
test -f "$RESOURCE_ROOT/KnowledgeBase/Grozziie-China-KB-2026-08-24.zip"

cmp "$PROJECT_ROOT/Resources/CustomerService/customer-reply-prompt.md" \
    "$RESOURCE_ROOT/CustomerService/customer-reply-prompt.md"
cmp "$PROJECT_ROOT/Resources/V2Knowledge/retrieve_top12.py" \
    "$RESOURCE_ROOT/V2Knowledge/retrieve_top12.py"
cmp "$PROJECT_ROOT/Resources/KnowledgeBase/Grozziie-China-KB-2026-08-24.zip" \
    "$RESOURCE_ROOT/KnowledgeBase/Grozziie-China-KB-2026-08-24.zip"

codesign --verify --deep --strict "$APP"
