#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

bin_path="$1"
resources="$2"

privacy_bundle="$bin_path/CocoaLumberjack_CocoaLumberjack.bundle"
test -f "$privacy_bundle/PrivacyInfo.xcprivacy"
mkdir -p "$resources"
rm -rf "$resources/CocoaLumberjack_CocoaLumberjack.bundle"
ditto "$privacy_bundle" "$resources/CocoaLumberjack_CocoaLumberjack.bundle"

# SwiftPM 依赖检出目录可能为只读，使用 install 写入副本以支持重复构建。
install -m 0644 .build/checkouts/pkg-logging/LICENSE "$resources/LICENSE-KirkLogging"
install -m 0644 .build/checkouts/CocoaLumberjack/LICENSE "$resources/LICENSE-CocoaLumberjack"
