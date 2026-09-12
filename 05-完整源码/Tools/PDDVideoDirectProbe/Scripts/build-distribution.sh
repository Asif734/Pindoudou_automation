#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
timestamp=$(date +%Y%m%d-%H%M%S)
output_root=${1:-"$project_dir/dist"}
signing_identity=${PDD_VIDEO_CODESIGN_IDENTITY:--}
delivery_dir="$output_root/拼多多视频直链测试器-同事AB-$timestamp"
app="$delivery_dir/拼多多视频直链测试器.app"

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swift build --package-path "$project_dir" -c release --product PDDVideoProbeApp --arch arm64 --arch x86_64
cp "$project_dir/.build/apple/Products/Release/PDDVideoProbeApp" "$app/Contents/MacOS/PDDVideoProbeApp"
cp "$project_dir/Packaging/Info.plist" "$app/Contents/Info.plist"
cp "$project_dir/Packaging/同事测试说明.txt" "$delivery_dir/00-同事测试说明.txt"
cp "$project_dir/Packaging/把这个文件交给Codex-自动完成测试.md" "$delivery_dir/01-把这个文件交给Codex-自动完成测试.md"
cp "$project_dir/README.md" "$delivery_dir/项目说明.md"
chmod 755 "$app/Contents/MacOS/PDDVideoProbeApp"
/usr/bin/codesign --force --deep --timestamp=none --sign "$signing_identity" "$app"
/usr/bin/codesign --verify --deep --strict "$app"
zip_path="$output_root/拼多多视频直链测试器-同事AB-$timestamp.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$delivery_dir" "$zip_path"
/usr/bin/shasum -a 256 "$zip_path" > "$zip_path.sha256.txt"
printf 'DELIVERY_DIR=%s\nZIP=%s\nSHA256_FILE=%s\n' "$delivery_dir" "$zip_path" "$zip_path.sha256.txt"
