#!/bin/bash
# 把 Swift Package 打成可双击的 ccenv.app（ad-hoc 签名，免 Xcode 工程）。
# 用法: macos/build.sh                 → macos/dist/ccenv.app（ad-hoc 签名）
#       macos/build.sh --dmg --zip     → 另外产出 dist/ccenv-<ver>.dmg 和 dist/ccenv-<ver>-macos.zip
# 正式签名 + 公证（需要 Developer ID Application 证书）：
#       CCENV_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" \
#       CCENV_NOTARY_PROFILE=ccenv-notary macos/build.sh --dmg
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' ../package.json | head -1)
BUILD=$(git -C .. rev-list --count HEAD 2>/dev/null || echo 1)
DIST=dist
APP="$DIST/ccenv.app"

echo "▸ swift build (release)"
BUILD_LOG="$DIST/swift-build.log"
mkdir -p "$DIST"
if ! swift build -c release --product CCEnv > "$BUILD_LOG" 2>&1; then
  echo "构建失败，swift build 输出末尾：" >&2
  tail -40 "$BUILD_LOG" >&2
  exit 1
fi
grep -E 'error|Build complete' "$BUILD_LOG" || true
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

# 签名：默认 ad-hoc；设置 CCENV_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" 则正式签名（开启 hardened runtime，公证必需）
IDENTITY="${CCENV_SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
  echo "▸ 签名（ad-hoc）"
  codesign --force --deep --sign - --identifier com.kadaliao.ccenv "$APP" 2>&1 | grep -v 'replacing existing signature' || true
else
  echo "▸ 签名（$IDENTITY）"
  codesign --force --deep --sign "$IDENTITY" --identifier com.kadaliao.ccenv --options runtime --timestamp "$APP"
fi
codesign --verify --deep --strict "$APP"

for arg in "$@"; do
  case "$arg" in
    --zip)
      echo "▸ 打包 zip"
      rm -f "$DIST/ccenv-$VERSION-macos.zip"
      ditto -c -k --keepParent "$APP" "$DIST/ccenv-$VERSION-macos.zip"
      echo "   $DIST/ccenv-$VERSION-macos.zip"
      ;;
    --dmg)
      echo "▸ 打包 dmg"
      STAGE="$DIST/dmg-stage"
      rm -rf "$STAGE" "$DIST/ccenv-$VERSION.dmg"
      mkdir -p "$STAGE"
      cp -R "$APP" "$STAGE/"
      ln -s /Applications "$STAGE/Applications"
      hdiutil create -quiet -volname "ccenv $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DIST/ccenv-$VERSION.dmg"
      rm -rf "$STAGE"
      if [ "$IDENTITY" != "-" ]; then
        codesign --force --sign "$IDENTITY" --timestamp "$DIST/ccenv-$VERSION.dmg"
      fi
      # 公证：设置 CCENV_NOTARY_PROFILE=<notarytool store-credentials 存的名字> 则提交 Apple 公证并 staple
      if [ -n "${CCENV_NOTARY_PROFILE:-}" ]; then
        [ "$IDENTITY" != "-" ] || { echo "公证需要 Developer ID 签名，请同时设置 CCENV_SIGN_IDENTITY" >&2; exit 1; }
        echo "▸ 公证（notarytool，通常 1~5 分钟）"
        xcrun notarytool submit "$DIST/ccenv-$VERSION.dmg" --keychain-profile "$CCENV_NOTARY_PROFILE" --wait
        xcrun stapler staple "$DIST/ccenv-$VERSION.dmg"
        spctl -a -vv -t open --context context:primary-signature "$DIST/ccenv-$VERSION.dmg" 2>&1 | tail -2
      fi
      echo "   $DIST/ccenv-$VERSION.dmg"
      ;;
  esac
done

echo "✓ $APP  (v$VERSION build $BUILD)"
