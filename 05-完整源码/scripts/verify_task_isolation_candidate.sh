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
    "PythonRuntime/python/bin/python3"; do
    test -e "$APP/Contents/Resources/$resource"
done
if [[ -d "$PROJECT_ROOT/Resources/SenseVoice" ]]; then
    for resource in "serve_sensevoice.py" "model/model.int8.onnx" "model/tokens.txt"; do
        test -e "$APP/Contents/Resources/SenseVoice/$resource"
    done
fi

cmp "$PROJECT_ROOT/Resources/CustomerService/customer-reply-prompt.md" \
    "$APP/Contents/Resources/CustomerService/customer-reply-prompt.md"
for resource in "FolderKnowledge/config.json" "FolderKnowledge/serve_folder.py"; do
    cmp "$PROJECT_ROOT/Resources/$resource" "$APP/Contents/Resources/$resource"
done

codesign --verify --deep --strict "$APP"
print "候选版验证通过：$APP"
