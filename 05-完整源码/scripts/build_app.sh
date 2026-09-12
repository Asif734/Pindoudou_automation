#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
APP_PATH="$PROJECT_ROOT/outputs/拼多多AX读取器.app"
PROBE_APP_PATH="$PROJECT_ROOT/outputs/拼多多AX单次解析测试器.app"
AUTO_REPLY_APP_PATH="$PROJECT_ROOT/outputs/拼多多全自动客服.app"
CANDIDATE_APP_PATH="$PROJECT_ROOT/outputs/pinduodou_automation.app"
SIGNING_IDENTITY="$($PROJECT_ROOT/scripts/select_codesign_identity.sh)"
PYTHON_RUNTIME_NAME="cpython-3.12.14+20260825-aarch64-apple-darwin-install_only_stripped.tar.gz"
PYTHON_RUNTIME_SHA256="8b0f1fa71eab7ca644e482c631807a1116fa848491051cd1c8d9429491de63a6"
PYTHON_RUNTIME_ROOT="$PROJECT_ROOT/Resources/ThirdParty/PythonRuntime"

sign_and_verify() {
    local app_path="$1"
    codesign --force --deep --options runtime --timestamp=none --sign "$SIGNING_IDENTITY" "$app_path"
    codesign --verify --deep --strict "$app_path"
    while IFS= read -r executable; do
        /usr/bin/file "$executable" | /usr/bin/grep -q 'Mach-O' || continue
        /usr/bin/lipo -archs "$executable" | /usr/bin/grep -qw arm64 || {
            print -u2 "原生依赖缺少 arm64：$executable"
            exit 1
        }
    done < <(/usr/bin/find "$app_path" -type f -perm -111)
}

copy_auto_reply_resources() {
    local destination_app="$1"
    ditto "$PROJECT_ROOT/Resources/WebOCR" "$destination_app/Contents/Resources/WebOCR"
    ditto "$PROJECT_ROOT/Resources/SenseVoice" "$destination_app/Contents/Resources/SenseVoice"
    for resource in CustomerService V2Knowledge KnowledgeBase; do
        local source_path="$PROJECT_ROOT/Resources/$resource"
        local destination_path="$destination_app/Contents/Resources/$resource"
        case "$destination_path" in
            "$destination_app"/Contents/Resources/*) ;;
            *) print -u2 "拒绝复制到意外资源路径：$destination_path"; exit 1 ;;
        esac
        test -e "$source_path" || { print -u2 "缺少自动客服资源：$source_path"; exit 1; }
        ditto "$source_path" "$destination_path"
    done
    "$PROJECT_ROOT/scripts/stage_python_runtime.sh" \
        "$PYTHON_RUNTIME_ROOT/$PYTHON_RUNTIME_NAME" \
        "$PYTHON_RUNTIME_SHA256" \
        "$destination_app/Contents/Resources/PythonRuntime"
    mkdir -p "$destination_app/Contents/Resources/ThirdPartyNotices"
    cp "$PYTHON_RUNTIME_ROOT/NOTICE.md" \
        "$destination_app/Contents/Resources/ThirdPartyNotices/PythonRuntime.md"
    cp "$PROJECT_ROOT/Resources/SenseVoice/NOTICE.md" \
        "$destination_app/Contents/Resources/ThirdPartyNotices/SenseVoice.md"
}

if [[ "${1:-}" == "--task-isolation-candidate" ]]; then
    case "$CANDIDATE_APP_PATH" in
        "$PROJECT_ROOT"/outputs/*.app) ;;
        *) print -u2 "拒绝替换意外路径：$CANDIDATE_APP_PATH"; exit 1 ;;
    esac
    cd "$PROJECT_ROOT"
    swift build -c release --product PDDAXReader
    BIN_DIR="$(swift build -c release --show-bin-path)"
    if [[ -e "$CANDIDATE_APP_PATH" ]]; then
        BACKUP_ROOT="$PROJECT_ROOT/outputs/backups/$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$BACKUP_ROOT"
        mv -- "$CANDIDATE_APP_PATH" "$BACKUP_ROOT/"
    fi
    mkdir -p "$CANDIDATE_APP_PATH/Contents/MacOS" "$CANDIDATE_APP_PATH/Contents/Resources"
    cp "$BIN_DIR/PDDAXReader" "$CANDIDATE_APP_PATH/Contents/MacOS/PDDTaskIsolationCandidate"
    cp "$PROJECT_ROOT/Resources/TaskIsolationCandidateInfo.plist" "$CANDIDATE_APP_PATH/Contents/Info.plist"
    cp "$PROJECT_ROOT/Resources/AppIcon/PDDLatest.icns" \
        "$CANDIDATE_APP_PATH/Contents/Resources/PDDLatest.icns"
    copy_auto_reply_resources "$CANDIDATE_APP_PATH"
    cmp "$PROJECT_ROOT/Resources/V2Knowledge/serve_top12.py" \
        "$CANDIDATE_APP_PATH/Contents/Resources/V2Knowledge/serve_top12.py"
    chmod 755 "$CANDIDATE_APP_PATH/Contents/MacOS/PDDTaskIsolationCandidate"
    sign_and_verify "$CANDIDATE_APP_PATH"
    print "$CANDIDATE_APP_PATH"
    exit 0
fi

if [[ $# -ne 0 ]]; then
    print -u2 "用法：$0 [--task-isolation-candidate]"
    exit 64
fi

case "$APP_PATH" in
    "$PROJECT_ROOT"/outputs/*.app) ;;
    *) print -u2 "拒绝清理意外路径：$APP_PATH"; exit 1 ;;
esac
case "$PROBE_APP_PATH" in
    "$PROJECT_ROOT"/outputs/*.app) ;;
    *) print -u2 "拒绝清理意外路径：$PROBE_APP_PATH"; exit 1 ;;
esac
case "$AUTO_REPLY_APP_PATH" in
    "$PROJECT_ROOT"/outputs/*.app) ;;
    *) print -u2 "拒绝清理意外路径：$AUTO_REPLY_APP_PATH"; exit 1 ;;
esac

cd "$PROJECT_ROOT"
swift build -c release --product PDDAXReader
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf -- "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_DIR/PDDAXReader" "$APP_PATH/Contents/MacOS/PDDAXReader"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
ditto "$PROJECT_ROOT/Resources/WebOCR" "$APP_PATH/Contents/Resources/WebOCR"
chmod 755 "$APP_PATH/Contents/MacOS/PDDAXReader"

sign_and_verify "$APP_PATH"

rm -rf -- "$PROBE_APP_PATH"
mkdir -p "$PROBE_APP_PATH/Contents/MacOS" "$PROBE_APP_PATH/Contents/Resources"
cp "$BIN_DIR/PDDAXReader" "$PROBE_APP_PATH/Contents/MacOS/PDDAXSingleParseProbe"
cp "$PROJECT_ROOT/Resources/SingleParseInfo.plist" "$PROBE_APP_PATH/Contents/Info.plist"
ditto "$PROJECT_ROOT/Resources/WebOCR" "$PROBE_APP_PATH/Contents/Resources/WebOCR"
chmod 755 "$PROBE_APP_PATH/Contents/MacOS/PDDAXSingleParseProbe"
sign_and_verify "$PROBE_APP_PATH"

rm -rf -- "$AUTO_REPLY_APP_PATH"
mkdir -p "$AUTO_REPLY_APP_PATH/Contents/MacOS" "$AUTO_REPLY_APP_PATH/Contents/Resources"
cp "$BIN_DIR/PDDAXReader" "$AUTO_REPLY_APP_PATH/Contents/MacOS/PDDAutoReply"
cp "$PROJECT_ROOT/Resources/AutoReplyInfo.plist" "$AUTO_REPLY_APP_PATH/Contents/Info.plist"
copy_auto_reply_resources "$AUTO_REPLY_APP_PATH"
cmp "$PROJECT_ROOT/Resources/CustomerService/customer-reply-prompt.md" \
    "$AUTO_REPLY_APP_PATH/Contents/Resources/CustomerService/customer-reply-prompt.md"
cmp "$PROJECT_ROOT/Resources/V2Knowledge/retrieve_top12.py" \
    "$AUTO_REPLY_APP_PATH/Contents/Resources/V2Knowledge/retrieve_top12.py"
cmp "$PROJECT_ROOT/Resources/V2Knowledge/serve_top12.py" \
    "$AUTO_REPLY_APP_PATH/Contents/Resources/V2Knowledge/serve_top12.py"
cmp "$PROJECT_ROOT/Resources/KnowledgeBase/Grozziie-China-KB-2026-08-24.zip" \
    "$AUTO_REPLY_APP_PATH/Contents/Resources/KnowledgeBase/Grozziie-China-KB-2026-08-24.zip"
chmod 755 "$AUTO_REPLY_APP_PATH/Contents/MacOS/PDDAutoReply"
sign_and_verify "$AUTO_REPLY_APP_PATH"

print "$APP_PATH"
print "$PROBE_APP_PATH"
print "$AUTO_REPLY_APP_PATH"
