#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/CodexUsageIsland.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

swiftc "$ROOT_DIR/Sources/CodexUsageIsland/main.swift" \
  -o "$APP_DIR/Contents/MacOS/CodexUsageIsland" \
  -framework AppKit

codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
