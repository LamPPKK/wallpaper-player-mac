# Background Engine

Background Engine is a native macOS 14+ desktop wallpaper player for legally acquired Wallpaper Engine projects. It supports Video, Web, images/GIF, and best-effort Scene playback on Apple Silicon and Intel Macs.

The app is GPLv3 software and is not affiliated with Valve or Wallpaper Engine.

## Current capabilities

- Private, versioned library in `~/Library/Application Support/Background Engine`; imports are atomic and never modify the original Workshop folder.
- Folder and video import with path/symlink/size validation plus SHA-256 deduplication.
- Anonymous Workshop URL/ID downloads through a constrained SteamCMD XPC service. No Steam login, password, Web API key, or arbitrary shell command is accepted.
- SteamCMD requests only Wallpaper Engine Workshop app ID `431960`; Valve's anonymous access and ownership rules remain authoritative.
- Independent wallpaper, Fit/Fill/Stretch, quality, and audio policy for each display UUID.
- AVFoundation looped video, non-persistent restricted WKWebView, still/GIF, native Scene subset, and cached Scene fallback.
- Scene fallback is encoded as a 20-second, 30 FPS H.264 MP4 loop with a crossfade when the external renderer is available.
- Universal Screen Saver bundle using the active video or Scene cache when macOS locks the session.
- Pause on sleep, Low Power Mode, or a fully covered desktop; restore after wake, Space changes, and display reconnects.
- No telemetry, account, cloud sync, or embedded Workshop catalog.

Windows Application wallpapers are recognized and shown as **Unsupported**. Scene projects are always labeled **Live**, **Cached**, or **Unsupported** with a reason; compatibility is best-effort.

## Build

Requirements: Xcode with the macOS 14 SDK and XcodeGen.

```sh
xcodegen generate
open "Background Engine.xcodeproj"
```

Or use Swift Package Manager:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --disable-sandbox
```

The external GPL renderer has additional CMake dependencies. See [ExternalRenderers/README.md](ExternalRenderers/README.md).

## Package a DMG

Development (unsigned):

```sh
./Scripts/package-app.sh
```

Developer ID and notarized release:

```sh
REQUIRE_SIGNING=1 REQUIRE_NOTARIZATION=1 \
SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
NOTARY_PROFILE="background-engine-notary" \
SCENE_RENDERER_RUNTIME_DIR="/absolute/path/to/universal/runtime" \
./Scripts/package-app.sh
```

The script signs nested renderer files, the `.saver`, XPC service, app, and DMG in order; submits with `notarytool`; staples and validates the ticket; runs Gatekeeper assessment; and writes SHA-256 plus a CycloneDX SBOM.

## Legal and content ownership

Users must own or otherwise be licensed to use Wallpaper Engine and imported content. Valve can deny anonymous SteamCMD downloads; in that case, install the owned item through Steam on Windows and copy its Workshop project folder to the Mac.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), [AUTHORS](AUTHORS), and [LICENSE](LICENSE).
