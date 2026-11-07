#!/bin/zsh
# Builds a universal Release ContextDrop.app and zips it into dist/ for sharing.
#
# Ad-hoc signed by default (free; friends must approve it once in Privacy & Security).
# Optional notarization (needs a paid Apple Developer account):
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=contextdrop scripts/package.sh
#   (create the profile once: xcrun notarytool store-credentials contextdrop --apple-id you@example.com --team-id TEAMID)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_SRC=build/DerivedData/Build/Products/Release/ContextDrop.app
mkdir -p dist
rm -rf dist/ContextDrop.app dist/ContextDrop.zip

echo "→ Building Release (arm64 + x86_64)…"
xcodebuild -project ContextDrop.xcodeproj -scheme ContextDrop -configuration Release \
  -derivedDataPath build/DerivedData ONLY_ACTIVE_ARCH=NO build -quiet

cp -R "$APP_SRC" dist/ContextDrop.app
# Keep the build-folder copy out of Launch Services so it doesn't shadow your dev build.
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -u "$APP_SRC" 2>/dev/null || true
rm -rf "$APP_SRC"

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  echo "→ Signing with $DEVELOPER_ID (hardened runtime)…"
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" dist/ContextDrop.app
fi

ditto -c -k --keepParent dist/ContextDrop.app dist/ContextDrop.zip

if [[ -n "${DEVELOPER_ID:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
  echo "→ Notarizing (takes a few minutes)…"
  xcrun notarytool submit dist/ContextDrop.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple dist/ContextDrop.app
  rm dist/ContextDrop.zip && ditto -c -k --keepParent dist/ContextDrop.app dist/ContextDrop.zip
fi

echo "→ $(lipo -archs dist/ContextDrop.app/Contents/MacOS/ContextDrop) · $(codesign -dv dist/ContextDrop.app 2>&1 | grep -E '^Signature|^Authority' | head -1)"
echo "✓ dist/ContextDrop.zip ($(du -h dist/ContextDrop.zip | cut -f1))"
