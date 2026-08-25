#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=runtime-script-common.sh
source "$ROOT/Scripts/runtime-script-common.sh"
APP_NAME="Background Engine"
APP_VERSION="${APP_VERSION:-0.2.0-alpha.1}"
BUNDLE_VERSION="${BUNDLE_VERSION:-5}"
DIST_DIR="$ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
XPC_DIR="$CONTENTS_DIR/XPCServices/BackgroundEngineSteamCMDRunner.xpc"
SAVER_DIR="$RESOURCES_DIR/Background Engine.saver"
DMG_NAME="Background-Engine-${APP_VERSION}-macOS-universal.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
SCENE_RENDERER_BINARY="${SCENE_RENDERER_BINARY:-}"
SCENE_RENDERER_RUNTIME_DIR="${SCENE_RENDERER_RUNTIME_DIR:-}"
FFMPEG_RUNTIME_DIR="${FFMPEG_RUNTIME_DIR:-}"
REQUIRE_SIGNING="${REQUIRE_SIGNING:-0}"
REQUIRE_NOTARIZATION="${REQUIRE_NOTARIZATION:-0}"
STAGING_DIR=""

cleanup() {
  if [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ]; then
    rm -rf "$STAGING_DIR"
  fi
}
trap cleanup EXIT

be_require_tools env xcrun lipo otool file find codesign spctl shasum \
  awk mktemp cp chmod mv dirname basename mkdir rm cat ln /usr/bin/perl
if [ ! -x "$ROOT/Scripts/create-dmg.sh" ]; then
  printf '%s\n' "Required build tool is missing or not executable: $ROOT/Scripts/create-dmg.sh" >&2
  exit 1
fi

if [ "$REQUIRE_SIGNING" = "1" ] && [ -z "$SIGN_IDENTITY" ]; then
  printf '%s\n' "SIGN_IDENTITY is required for a release build." >&2
  exit 1
fi

if [ "$REQUIRE_NOTARIZATION" = "1" ] && [ -z "$NOTARY_PROFILE" ]; then
  printf '%s\n' "NOTARY_PROFILE is required for notarization." >&2
  exit 1
fi
if [ -n "$NOTARY_PROFILE" ] && [ -z "$SIGN_IDENTITY" ]; then
  printf '%s\n' "Notarization requires a Developer ID Application identity." >&2
  exit 1
fi

cd "$ROOT"
env DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  xcrun swift build -c release --arch arm64 --arch x86_64 --disable-sandbox
BIN_DIR="$(env DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  xcrun swift build -c release --arch arm64 --arch x86_64 --disable-sandbox --show-bin-path)"

if [ "$DIST_DIR" != "$ROOT/dist" ]; then
  printf '%s\n' "Refusing to clean unexpected dist path: $DIST_DIR" >&2
  exit 1
fi
rm -rf "$DIST_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$XPC_DIR/Contents/MacOS" "$SAVER_DIR/Contents/MacOS"

cp "$BIN_DIR/BackgroundEngine" "$MACOS_DIR/Background Engine"
cp "$BIN_DIR/be-cli" "$MACOS_DIR/be-cli"
cp "$BIN_DIR/BackgroundEngineSteamCMDRunner" "$XPC_DIR/Contents/MacOS/BackgroundEngineSteamCMDRunner"
RESOURCE_BUNDLE="$BIN_DIR/BackgroundEngine_BackgroundEngineApp.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
  cp -R "$RESOURCE_BUNDLE" "$RESOURCES_DIR/"
fi
cp LICENSE AUTHORS THIRD_PARTY_NOTICES.md "$RESOURCES_DIR/"
cp -R ThirdPartyLicenses "$RESOURCES_DIR/"
mkdir -p "$RESOURCES_DIR/Scripts"
cp Scripts/scene-parity-compare.sh Scripts/scene-golden-parity.sh \
  Scripts/scene-frame-diff.swift Scripts/runtime-script-common.sh "$RESOURCES_DIR/Scripts/"
chmod +x "$RESOURCES_DIR/Scripts/scene-parity-compare.sh" "$RESOURCES_DIR/Scripts/scene-golden-parity.sh"

if [ -n "$FFMPEG_RUNTIME_DIR" ]; then
  test -x "$FFMPEG_RUNTIME_DIR/MediaTools/ffmpeg"
  test -x "$FFMPEG_RUNTIME_DIR/MediaTools/ffprobe"
  cp -R "$FFMPEG_RUNTIME_DIR/MediaTools" "$RESOURCES_DIR/"
  cp -R "$FFMPEG_RUNTIME_DIR/Source" "$RESOURCES_DIR/FFmpeg-Source"
  lipo "$RESOURCES_DIR/MediaTools/ffmpeg" -verify_arch arm64 x86_64
  lipo "$RESOURCES_DIR/MediaTools/ffprobe" -verify_arch arm64 x86_64
elif [ "$REQUIRE_SIGNING" = "1" ]; then
  printf '%s\n' "A verified Universal FFmpeg 9.0.1 runtime is required for release." >&2
  exit 1
else
  printf '%s\n' "warning: bundled FFmpeg runtime is absent from this development package." >&2
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>Background Engine</string>
  <key>CFBundleIdentifier</key><string>com.lamppkk.backgroundengine</string>
  <key>CFBundleName</key><string>Background Engine</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$BUNDLE_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

cat > "$XPC_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>BackgroundEngineSteamCMDRunner</string>
  <key>CFBundleIdentifier</key><string>com.lamppkk.backgroundengine.steamcmd-runner</string>
  <key>CFBundleName</key><string>Background Engine SteamCMD Runner</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$BUNDLE_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>XPCService</key><dict><key>ServiceType</key><string>Application</string></dict>
</dict></plist>
PLIST

cat > "$SAVER_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>BackgroundEngineScreenSaver</string>
  <key>CFBundleIdentifier</key><string>com.lamppkk.backgroundengine.screensaver</string>
  <key>CFBundleName</key><string>Background Engine</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$BUNDLE_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>BackgroundEngineScreenSaverView</string>
</dict></plist>
PLIST

env DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" xcrun clang \
  -fobjc-arc -bundle -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
  -framework AppKit -framework AVFoundation -framework CoreMedia \
  -framework QuartzCore -framework ScreenSaver \
  "$ROOT/Sources/BackgroundEngineScreenSaver/BackgroundEngineScreenSaverView.m" \
  -o "$SAVER_DIR/Contents/MacOS/BackgroundEngineScreenSaver"

if [ -z "$SCENE_RENDERER_RUNTIME_DIR" ] && [ -x "$ROOT/ExternalRenderers/wallpaperengine-mac-renderer/build/runtime/background-engine-scene-renderer" ]; then
  SCENE_RENDERER_RUNTIME_DIR="$ROOT/ExternalRenderers/wallpaperengine-mac-renderer/build/runtime"
fi
if [ -n "$SCENE_RENDERER_RUNTIME_DIR" ]; then
  test -x "$SCENE_RENDERER_RUNTIME_DIR/background-engine-scene-renderer"
  mkdir -p "$RESOURCES_DIR/Renderers"
  cp -R "$SCENE_RENDERER_RUNTIME_DIR/." "$RESOURCES_DIR/Renderers/"
elif [ -n "$SCENE_RENDERER_BINARY" ]; then
  mkdir -p "$RESOURCES_DIR/Renderers"
  cp "$SCENE_RENDERER_BINARY" "$RESOURCES_DIR/Renderers/background-engine-scene-renderer"
elif [ "$REQUIRE_SIGNING" = "1" ]; then
  printf '%s\n' "A portable Universal Scene renderer runtime is required for release." >&2
  exit 1
else
  printf '%s\n' "warning: GPL Scene renderer is not bundled in this development build." >&2
fi

chmod +x "$MACOS_DIR/Background Engine" "$MACOS_DIR/be-cli" \
  "$XPC_DIR/Contents/MacOS/BackgroundEngineSteamCMDRunner" \
  "$SAVER_DIR/Contents/MacOS/BackgroundEngineScreenSaver"

if [ -n "$SIGN_IDENTITY" ]; then
  if [ -d "$RESOURCES_DIR/MediaTools" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$RESOURCES_DIR/MediaTools/ffmpeg"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$RESOURCES_DIR/MediaTools/ffprobe"
  fi
  if [ -d "$RESOURCES_DIR/Renderers" ]; then
    while IFS= read -r renderer_file; do
      if /usr/bin/file "$renderer_file" | /usr/bin/grep -Eq 'Mach-O'; then
        codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$renderer_file"
      fi
    done < <(find "$RESOURCES_DIR/Renderers" -type f -print)
  fi
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$MACOS_DIR/be-cli"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$SAVER_DIR"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$XPC_DIR"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_DIR"
  codesign --verify --deep --strict --verbose=2 "$APP_DIR"
fi

if [ -d "$RESOURCES_DIR/Renderers" ]; then
  "$ROOT/Scripts/verify-renderer-runtime.sh" "$RESOURCES_DIR/Renderers" arm64 x86_64
  /usr/bin/perl -e 'alarm 30; exec @ARGV' \
    "$RESOURCES_DIR/Renderers/background-engine-scene-renderer" --help >/dev/null
fi

STAGING_DIR="$(mktemp -d)"
cp -R "$APP_DIR" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
"$ROOT/Scripts/create-dmg.sh" "$STAGING_DIR" "$APP_NAME" "$DMG_PATH" >/dev/null

if [ -n "$SIGN_IDENTITY" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH"
fi
if [ -n "$NOTARY_PROFILE" ]; then
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
fi

(cd "$DIST_DIR" && shasum -a 256 "$DMG_NAME") > "$DMG_PATH.sha256"
"$ROOT/Scripts/generate-sbom.sh" "$DIST_DIR/Background-Engine-${APP_VERSION}.sbom.json"
printf '%s\n' "$DMG_PATH"
