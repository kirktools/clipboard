#!/bin/bash
# 只生成本地安装包与校验清单，不提交、推送或发布。
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh release

app="dist/release/Clipboard.app"
codesign --verify --strict "$app"

# 核对应用包已包含主许可证、依赖许可证和隐私清单资源。
for required in \
  "$app/Contents/Resources/LICENSE" \
  "$app/Contents/Resources/LICENSE-KirkLogging" \
  "$app/Contents/Resources/LICENSE-CocoaLumberjack" \
  "$app/Contents/Resources/CocoaLumberjack_CocoaLumberjack.bundle/PrivacyInfo.xcprivacy"; do
  if [[ ! -f "$required" ]]; then
    echo "打包失败：缺少必需资源 $required" >&2
    exit 1
  fi
done

# 核对应用包内二进制与资源不含本机个人路径、工作区路径或 SwiftPM checkout 路径。
# 命中时仅报告包内相对路径与问题类型，不输出敏感路径内容。
python3 - "$app" "$PWD" <<'PY'
import os, re, sys
from pathlib import Path

app_path = Path(sys.argv[1]).resolve()
repo_path = Path(sys.argv[2]).resolve()
home_path = Path.home().resolve()

checks = [
    ("user_home_path", re.compile(rb'/Users/[^/\x00\s"\'<>]+')),
    ("user_home_path", re.compile(re.escape(str(home_path).encode('utf-8')))),
    ("workspace_path", re.compile(re.escape(str(repo_path).encode('utf-8')))),
    ("swiftpm_checkout_path", re.compile(rb'\.build/checkouts/')),
]

findings = []
for file_path in sorted(app_path.rglob('*')):
    if not file_path.is_file() or file_path.is_symlink():
        continue
    data = file_path.read_bytes()
    rel = str(file_path.relative_to(app_path.parent))
    hit_kinds = []
    for kind, pattern in checks:
        if kind not in hit_kinds and pattern.search(data):
            hit_kinds.append(kind)
    for kind in hit_kinds:
        findings.append((rel, kind))

if findings:
    for rel, kind in findings:
        print(f"打包校验失败：检测到路径残留 file={rel} issue={kind}", file=sys.stderr)
    sys.exit(1)
PY

signing="adhoc"
if [[ "${RELEASE_SIGNING_IDENTITY:--}" != "-" && -n "${RELEASE_SIGNING_IDENTITY:-}" ]]; then
  signing="certificate"
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
architecture="$(uname -m)"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "应用版本必须为 major.minor.patch。" >&2
  exit 1
fi

stage="$(mktemp -d "$PWD/dist/.packages.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
payload="$stage/dmg-content"
output="$stage/artifacts"
mkdir -p "$payload" "$output"

app_zip="Clipboard-$version-macos-$architecture.zip"
app_dmg="Clipboard-$version-macos-$architecture.dmg"

/usr/bin/ditto "$app" "$payload/Clipboard.app"
ln -s /Applications "$payload/Applications"
/usr/bin/hdiutil create -format UDZO -fs HFS+ -volname Clipboard -srcfolder "$payload" "$output/$app_dmg"
/usr/bin/hdiutil verify "$output/$app_dmg"
/usr/bin/ditto -c -k --keepParent "$app" "$output/$app_zip"

# 对实际打包后的 ZIP 副本再做一次解压抽检，确认压缩包内二进制无路径残留且签名完整。
zip_verify_dir="$stage/zip-verify"
mkdir -p "$zip_verify_dir"
/usr/bin/ditto -x -k "$output/$app_zip" "$zip_verify_dir"
codesign --verify --strict "$zip_verify_dir/Clipboard.app"
python3 - "$zip_verify_dir/Clipboard.app" "$PWD" <<'PY'
import re, sys
from pathlib import Path

app_path = Path(sys.argv[1]).resolve()
repo_path = Path(sys.argv[2]).resolve()
home_path = Path.home().resolve()

checks = [
    ("user_home_path", re.compile(rb'/Users/[^/\x00\s"\'<>]+')),
    ("user_home_path", re.compile(re.escape(str(home_path).encode('utf-8')))),
    ("workspace_path", re.compile(re.escape(str(repo_path).encode('utf-8')))),
    ("swiftpm_checkout_path", re.compile(rb'\.build/checkouts/')),
]

for file_path in sorted(app_path.rglob('*')):
    if not file_path.is_file() or file_path.is_symlink():
        continue
    data = file_path.read_bytes()
    rel = str(file_path.relative_to(app_path.parent))
    for kind, pattern in checks:
        if pattern.search(data):
            print(f"ZIP 抽检失败：检测到路径残留 file={rel} issue={kind}", file=sys.stderr)
            sys.exit(1)
PY

python3 - "$output" "$app" "$architecture" "$app_zip" "$app_dmg" "$signing" <<'PY'
import hashlib, json, os, plistlib, shutil, sys
from pathlib import Path

stage = Path(sys.argv[1])
app, arch, app_zip, app_dmg, signing = sys.argv[2:]
aliases = {
    app_zip: f'Clipboard-macos-{arch}.zip',
    app_dmg: f'Clipboard-macos-{arch}.dmg',
}
for versioned, fixed in aliases.items():
    shutil.copyfile(stage / versioned, stage / fixed)

info = plistlib.loads((Path(app) / 'Contents/Info.plist').read_bytes())
files = []
for name in sorted([*aliases, *aliases.values()]):
    path = stage / name
    files.append(dict(name=name, size=path.stat().st_size, sha256=hashlib.sha256(path.read_bytes()).hexdigest()))

manifest = dict(
    version=info['CFBundleShortVersionString'],
    build=info['CFBundleVersion'],
    bundleIdentifier=info['CFBundleIdentifier'],
    signing=signing,
    notarized=False,
    files=files,
)
(stage / 'manifest.json').write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + '\n')
(stage / 'SHA256SUMS').write_text(''.join(f"{file['sha256']}  {file['name']}\n" for file in files))

out = Path('dist/packages')
out.mkdir(parents=True, exist_ok=True)
for name in [*sorted(aliases), *sorted(aliases.values()), 'SHA256SUMS', 'manifest.json']:
    os.replace(stage / name, out / name)
PY

echo "已生成本地安装包与校验清单：dist/packages/"
