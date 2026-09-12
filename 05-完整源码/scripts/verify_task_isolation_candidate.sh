#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
APP="$PROJECT_ROOT/outputs/pinduodou_automation.app"
PLIST="$APP/Contents/Info.plist"
EXECUTABLE="$APP/Contents/MacOS/PDDTaskIsolationCandidate"

test -d "$APP"
test -f "$PLIST"
test -x "$EXECUTABLE"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" = \
    "com.scy.pdd-auto-reply.task-isolation-candidate"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")" = \
    "PDDTaskIsolationCandidate"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$PLIST")" = \
    "pinduodou_automation"

for resource in \
    "CustomerService/customer-reply-prompt.md" \
    "SenseVoice/serve_sensevoice.py" \
    "SenseVoice/model/model.int8.onnx" \
    "SenseVoice/model/tokens.txt" \
    "SenseVoice/site-packages/sherpa_onnx/lib/_sherpa_onnx.cpython-312-darwin.so" \
    "V2Knowledge/retrieve_top12.py" \
    "KnowledgeBase/Grozziie-China-KB-2026-08-24.zip"; do
    test -e "$APP/Contents/Resources/$resource"
done

cmp "$PROJECT_ROOT/Resources/CustomerService/customer-reply-prompt.md" \
    "$APP/Contents/Resources/CustomerService/customer-reply-prompt.md"
cmp "$PROJECT_ROOT/Resources/V2Knowledge/retrieve_top12.py" \
    "$APP/Contents/Resources/V2Knowledge/retrieve_top12.py"
cmp "$PROJECT_ROOT/Resources/KnowledgeBase/Grozziie-China-KB-2026-08-24.zip" \
    "$APP/Contents/Resources/KnowledgeBase/Grozziie-China-KB-2026-08-24.zip"

codesign --verify --deep --strict "$APP"
print "候选版验证通过：$APP"
