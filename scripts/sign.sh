#!/bin/bash
# 本地与发布签名入口：不创建证书、不访问未授权私钥、不修改钥匙串。
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 || ! -d "$1/Contents" ]]; then
  echo "用法：scripts/sign.sh <应用.app> [debug|release]" >&2
  exit 2
fi

app="$1"
mode="${2:-release}"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
identity="-"
signing_kind="adhoc"

if [[ "$mode" == debug ]]; then
  identity="${DEV_SIGNING_IDENTITY:-}"
  identity_file="$(dirname "$0")/../.local/dev-signing-identity"
  if [[ -z "$identity" && -f "$identity_file" ]]; then
    identity="$(tr -d '\r\n' < "$identity_file")"
  fi
  if [[ -z "$identity" ]]; then
    identity="-"
    echo "开发签名：ad-hoc（未配置 DEV_SIGNING_IDENTITY 或 .local/dev-signing-identity；跨构建可能重置隐私授权）。"
  else
    signing_kind="certificate"
  fi
else
  identity="${RELEASE_SIGNING_IDENTITY:-}"
  if [[ -z "$identity" ]]; then
    identity="-"
  fi
  if [[ "${REQUIRE_STABLE_SIGNING:-0}" == "1" && "$identity" == "-" ]]; then
    echo "签名失败：当前要求稳定证书签名（REQUIRE_STABLE_SIGNING=1），但未配置 RELEASE_SIGNING_IDENTITY。" >&2
    exit 1
  fi
  if [[ "$identity" == "-" ]]; then
    echo "发布签名：ad-hoc（本地兜底模式；未配置 RELEASE_SIGNING_IDENTITY，不适用于公开发布）。"
  else
    signing_kind="certificate"
  fi
fi

options=()
if [[ "$mode" == release && "$signing_kind" == certificate ]]; then
  options+=(--options runtime)
  if [[ -n "${RELEASE_SIGNING_KEYCHAIN:-}" ]]; then
    options+=(--keychain "$RELEASE_SIGNING_KEYCHAIN")
  fi
fi

codesign --force --sign "$identity" --timestamp=none --identifier "$bundle_id" ${options[@]+"${options[@]}"} "$app"
codesign --verify --strict "$app"

if [[ "$mode" == release && "$signing_kind" == certificate ]]; then
  requirement="$(codesign --display --requirements - "$app" 2>/dev/null)"
  if [[ "$requirement" != *"certificate "* || "$requirement" == *"cdhash "* ]]; then
    echo "签名校验失败：未生成稳定的证书身份要求。" >&2
    exit 1
  fi
fi
