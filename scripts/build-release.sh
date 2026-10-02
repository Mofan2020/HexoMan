#!/bin/bash
# 构建 Release 版 HexoMan 并输出到 build/release。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
OUT="$ROOT/build/release"

echo "==> 生成 Xcode 工程"
xcodegen generate

echo "==> 构建 Release"
xcodebuild \
  -project HexoMan.xcodeproj \
  -scheme HexoMan \
  -configuration Release \
  -derivedDataPath "$ROOT/build" \
  build

APP="$ROOT/build/Build/Products/Release/HexoMan.app"
if [ ! -d "$APP" ]; then
  echo "error: 没找到产物 $APP" >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"
cp -R "$APP" "$OUT/"

echo "==> 完成：$OUT/HexoMan.app"
