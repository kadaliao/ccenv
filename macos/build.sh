#!/bin/bash
# 把 Swift Package 打成可双击的 ccenv.app（ad-hoc 签名，免 Xcode 工程）。
# 用法: macos/build.sh            → macos/dist/ccenv.app
#       macos/build.sh --zip      → 另外产出 macos/dist/ccenv-macos.zip
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' ../package.json | head -1)
BUILD=$(git -C .. rev-list --count HEAD 2>/dev/null || echo 1)
DIST=dist
APP="$DIST/ccenv.app"

echo "▸ swift build (release)"
swift build -c release --product CCEnv 2>&1 | grep -E 'error|Build complete' || { echo "构建失败" >&2; exit 1; }
BIN=$(swift build -c release --product CCEnv --show-bin-path)/CCEnv

echo "▸ 组装 bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CCEnv"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Support/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ 生成图标"
ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET"
swiftc -O -o "$DIST/make-icon" Support/MakeIcon.swift 2>/dev/null
"$DIST/make-icon" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET" "$DIST/make-icon"

echo "▸ 签名（ad-hoc）"
codesign --force --deep --sign - --identifier com.kadaliao.ccenv "$APP" 2>&1 | grep -v 'replacing existing signature' || true
codesign --verify --deep --strict "$APP"

if [ "${1:-}" = "--zip" ]; then
  echo "▸ 打包 zip"
  rm -f "$DIST/ccenv-macos.zip"
  ditto -c -k --keepParent "$APP" "$DIST/ccenv-macos.zip"
  echo "   $DIST/ccenv-macos.zip"
fi

echo "✓ $APP  (v$VERSION build $BUILD)"
