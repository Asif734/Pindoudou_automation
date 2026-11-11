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
test -x "$RESOURCE_ROOT/PythonRuntime/python/bin/python3"

cmp "$PROJECT_ROOT/Resources/CustomerService/customer-reply-prompt.md" \
    "$RESOURCE_ROOT/CustomerService/customer-reply-prompt.md"
if [[ -f "$PROJECT_ROOT/Resources/FolderKnowledge/config.json" ]]; then
    for resource in config.json serve_folder.py; do
        cmp "$PROJECT_ROOT/Resources/FolderKnowledge/$resource" \
            "$RESOURCE_ROOT/FolderKnowledge/$resource"
    done
else
    test -d "$RESOURCE_ROOT/V2Knowledge/site-packages"
    test -d "$RESOURCE_ROOT/V2Knowledge/cache"
    for resource in retrieve_top12.py serve_top12.py; do
        cmp "$PROJECT_ROOT/Resources/V2Knowledge/$resource" \
            "$RESOURCE_ROOT/V2Knowledge/$resource"
    done
    cmp "$PROJECT_ROOT/Resources/KnowledgeBase/Grozziie-China-KB-2026-08-24.zip" \
        "$RESOURCE_ROOT/KnowledgeBase/Grozziie-China-KB-2026-08-24.zip"
fi

codesign --verify --deep --strict "$APP"
