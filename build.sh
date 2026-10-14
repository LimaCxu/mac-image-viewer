#!/bin/bash
# 编译并打包成 .app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/ImageViewer.app"
BIN="$APP/Contents/MacOS/ImageViewer"

# 编译器缓存与临时目录放在项目内（避免受系统临时目录权限限制），
# 并按项目绝对路径派生目录名：移动项目后不会命中带旧路径的失效缓存。
CACHE_KEY="$(printf '%s' "$ROOT" | shasum -a 256 | cut -c1-12)"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/modulecache-$CACHE_KEY"
export SWIFT_MODULECACHE_PATH="$CLANG_MODULE_CACHE_PATH"
export TMPDIR="$ROOT/.build/tmp"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$TMPDIR"

# 先编译到暂存目录：编译失败时保留原有可用产物，不会把 .app 删成空的
STAGE="$ROOT/.build/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"

echo "==> 编译"
swiftc \
  -O -swift-version 5 \
  -target arm64-apple-macos13.0 \
  -o "$STAGE/ImageViewer" \
  "$ROOT/Sources/main.swift"

echo "==> 打包"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$STAGE/ImageViewer" "$BIN"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

echo "==> 临时签名 (ad-hoc)"
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "(签名跳过，不影响本机运行)"

echo "==> 完成: $APP"
echo "    运行: open '$APP'              # 打开后拖入图片或文件夹"
echo "    或:   open -a '$APP' 某张图片.jpg"
