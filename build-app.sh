#!/bin/zsh
# Build DiskScope.app (universal arm64 + x86_64, Hardened Runtime) into ./build.
#
#   ./build-app.sh                 ad-hoc signed app for this Mac
#   ./build-app.sh --install       …and copy it to /Applications
#   ./build-app.sh --dmg           …and package build/DiskScope-<version>.dmg
#
# Distribution to other Macs (Gatekeeper-clean) — needs an Apple Developer ID:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=<profile from `xcrun notarytool store-credentials`> ./build-app.sh --dmg
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-1.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
[[ "$VERSION" =~ '^[0-9]+(\.[0-9]+){0,2}$' ]] || { echo "VERSION must look like 1.2.3 (got '$VERSION')" >&2; exit 2; }
[[ "$BUILD_NUMBER" =~ '^[0-9]+(\.[0-9]+)*$' ]] || { echo "BUILD_NUMBER must be numeric (got '$BUILD_NUMBER')" >&2; exit 2; }
INSTALL=0; DMG=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --dmg) DMG=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

APP=build/DiskScope.app
BIN="$APP/Contents/MacOS/DiskScope"

echo "==> Compiling (release, arm64 + x86_64)"
swift build -c release --triple arm64-apple-macosx14.0 --scratch-path .build/arm64
swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path .build/x86_64

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$BIN" \
  .build/arm64/arm64-apple-macosx/release/DiskScope \
  .build/x86_64/x86_64-apple-macosx/release/DiskScope
strip -x "$BIN"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>DiskScope</string>
  <key>CFBundleDisplayName</key><string>DiskScope</string>
  <key>CFBundleIdentifier</key><string>com.diskscope.app</string>
  <key>CFBundleExecutable</key><string>DiskScope</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsSuddenTermination</key><true/>
  <key>NSHumanReadableCopyright</key><string>© $(date +%Y) DiskScope</string>
  <!-- Shown by macOS privacy prompts when scanning protected locations. -->
  <key>NSDesktopFolderUsageDescription</key><string>DiskScope measures the size of files on your Desktop. Nothing is uploaded or changed.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>DiskScope measures the size of files in Documents. Nothing is uploaded or changed.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>DiskScope measures the size of files in Downloads. Nothing is uploaded or changed.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>DiskScope measures disk usage on external drives you choose to scan.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>DiskScope measures disk usage on network volumes you choose to scan.</string>
  <!-- Lets folders be dropped on the Dock icon / "Open With"; never claims to be the default app. -->
  <key>CFBundleDocumentTypes</key>
  <array><dict>
    <key>CFBundleTypeName</key><string>Folder</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>None</string>
    <key>LSItemContentTypes</key><array><string>public.folder</string><string>public.volume</string></array>
  </dict></array>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Signing (${SIGN_IDENTITY}) with Hardened Runtime"
# No entitlements needed: no JIT, no unsigned libraries, no Apple Events. (Outgoing HTTPS for the
# optional Ask Claude panel needs no entitlement outside the App Sandbox.)
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --options runtime --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict --deep "$APP"

if [[ -n "$NOTARY_PROFILE" ]]; then
  [[ "$SIGN_IDENTITY" == "-" ]] && { echo "Notarization needs SIGN_IDENTITY (Developer ID)" >&2; exit 1; }
  echo "==> Notarizing"
  ditto -c -k --keepParent "$APP" build/DiskScope-notarize.zip
  xcrun notarytool submit build/DiskScope-notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f build/DiskScope-notarize.zip
fi

if (( DMG )); then
  DMG_PATH="build/DiskScope-${VERSION}.dmg"
  echo "==> Creating $DMG_PATH"
  STAGE=$(mktemp -d)
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$DMG_PATH"
  hdiutil create -quiet -volname "DiskScope" -srcfolder "$STAGE" -format UDZO -ov "$DMG_PATH"
  rm -rf "$STAGE"
  if [[ "$SIGN_IDENTITY" != "-" ]]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
    if [[ -n "$NOTARY_PROFILE" ]]; then
      xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
      xcrun stapler staple "$DMG_PATH"
    fi
  fi
fi

if (( INSTALL )); then
  echo "==> Installing to /Applications"
  pkill -x DiskScope 2>/dev/null || true
  rm -rf /Applications/DiskScope.app
  cp -R "$APP" /Applications/
fi

echo "Built $APP ($(lipo -archs "$BIN"), v${VERSION} build ${BUILD_NUMBER})"
