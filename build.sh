#!/bin/bash
# 编译并打包成 .app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/ImageViewer.app"
BIN="$APP/Contents/MacOS/ImageViewer"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 编译器的缓存与临时目录限制在项目内，避免受限于系统临时目录权限
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/modulecache"
export SWIFT_MODULECACHE_PATH="$ROOT/.build/modulecache"
export TMPDIR="$ROOT/.build/tmp"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$TMPDIR"

echo "==> 编译"
swiftc \
  -O -swift-version 5 \
  -target arm64-apple-macos13.0 \
  -o "$BIN" \
  "$ROOT/Sources/main.swift"

echo "==> 打包"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

echo "==> 临时签名 (ad-hoc)"
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "(签名跳过，不影响本机运行)"

echo "==> 完成: $APP"
echo "    运行: open '$APP'              # 打开后拖入图片或文件夹"
echo "    或:   open -a '$APP' 某张图片.jpg"
