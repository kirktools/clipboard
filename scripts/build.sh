#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${1:-debug}"
case "$configuration" in
  debug|release) ;;
  *) echo "用法：scripts/build.sh [debug|release]" >&2; exit 2 ;;
esac

./scripts/swift.sh build -c "$configuration"
bin_path="$(./scripts/swift.sh build -c "$configuration" --show-bin-path)"

if [[ "$configuration" == debug ]]; then
  app="dist/dev/Clipboard Dev.app"
  icon_mode="dev"
else
  app="dist/release/Clipboard.app"
  icon_mode="release"
fi

rm -rf "$app"
mkdir -p .build/tools "$app/Contents/MacOS" "$app/Contents/Resources"

if [[ ! -x .build/tools/generate-icon || scripts/generate-icon.swift -nt .build/tools/generate-icon ]]; then
  xcrun swiftc scripts/generate-icon.swift -module-cache-path "$PWD/.build/module-cache" -o .build/tools/generate-icon
fi

iconset=".build/tools/$icon_mode.iconset"
.build/tools/generate-icon "$iconset" "$icon_mode" "$app/Contents/Resources/AppIcon.icns"

cp "$bin_path/Clipboard" "$app/Contents/MacOS/Clipboard"
if [[ "$configuration" == release ]]; then
  # 剥离调试符号中的本机绝对路径与 SwiftPM checkout 路径，再执行签名。
  strip -S "$app/Contents/MacOS/Clipboard"
fi
cp Resources/Info.plist "$app/Contents/Info.plist"
cp LICENSE "$app/Contents/Resources/LICENSE"
./scripts/copy-package-resources.sh "$bin_path" "$app/Contents/Resources"

if [[ "$configuration" == debug ]]; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier dev.clipboard.app.dev' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleName Clipboard Dev' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Clipboard Dev' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :ClipboardDataDirectoryName Clipboard-dev' "$app/Contents/Info.plist"
fi

./scripts/sign.sh "$app" "$configuration"
echo "已构建：$app"
