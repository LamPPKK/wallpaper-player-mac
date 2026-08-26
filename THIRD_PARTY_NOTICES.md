# Third-Party Notices

Background Engine is distributed under GNU GPL version 3. It is not affiliated with, endorsed by, or sponsored by Valve Corporation or Wallpaper Engine.

## Open Wallpaper Engine / SteamCMD fork

- Source: <https://github.com/OWmess/wallpaper-player-mac-steamcmd>
- Pinned source: `fa0929c582914d28a896577d56b29c5ccf2e2bb8`
- License: GNU GPL version 3
- Used for the macOS app/XPC lineage and SteamCMD integration concepts. Background Engine removes the legacy username/password and arbitrary-command paths.

## Workshop Wallpaper Bridge

- Source: <https://github.com/3x-haust/workshop-wallpaper-bridge>
- Pinned source: `c0b8becfc77ff8c73141129aa37af8a8f68b510d`
- License: MIT; the license text is included at `ThirdPartyLicenses/Workshop-Wallpaper-Bridge-MIT.txt`.
- Used for the safe library scanner, Scene package/texture/parser implementation, native playback, Scene video cache, screen saver, and its test foundation.

## wallpaperengine-mac-renderer

- Source: <https://github.com/3x-haust/wallpaperengine-mac-renderer>
- Pinned source: `7acc6c92e0175d53e1cb6b2b2dff52f79faf83e0`
- Background Engine renderer build: `7acc6c9-be3`, containing the GPLv3 host-integration, explicit PKGV-mount, macOS system-font resolution, and shader sampler-requirement patches shipped in this source tree.
- License: GNU GPL version 3
- Corresponding source, including pinned submodules, is kept under `ExternalRenderers/wallpaperengine-mac-renderer` and must accompany any binary distribution.

The renderer requires Wallpaper Engine assets supplied by the user. Background Engine does not distribute those assets.

## Aerial

- Source: <https://github.com/AerialScreensaver/Aerial>
- Reviewed source: `0083c721dcc0fa6df55a0a011678c11493ad2810`
- License: MIT; the license text is included at `ThirdPartyLicenses/Aerial-MIT.txt`.
- Background Engine's video playback coordinator ports Aerial's independent pause-reason arbitration and resilient AVQueuePlayer/AVPlayerLooper lifecycle pattern while retaining Background Engine's own library, display, and cache model.

## Plash / PlashRuntime

- Self-hosted source: <https://github.com/LamPPKK/Plash>
- Upstream fork synchronized from: <https://github.com/Joehuu/Plash> at `d9ac1bbde078c5b0fd3fb52c7bad3d64ccbc43ae`
- Pinned integration source: `b9f585368264c79de997d7d82e10d2dc85f3024e`
- License: MIT; the license text is included at `ThirdPartyLicenses/Plash-MIT.txt`.
- Background Engine links the reusable `PlashRuntime` Swift package for transparent WebKit presentation, ephemeral website data, autoplay, CSS/JavaScript presentation, print styles, color inversion and media pause/resume. Background Engine retains its stricter same-origin navigation, download, credential and native-command policy.

## FFmpeg

- Source: <https://ffmpeg.org/>
- Pinned release: `9.0.1`
- Background Engine build ID: `ffmpeg-9.0.1-background-engine-1`
- License: LGPL version 2.1 or later for the configured build; GPL and non-free components are disabled.

Release packaging includes the exact signed upstream source archive, FFmpeg license, signing-key fingerprint, and configure flags. The runtime disables networking and device capture and uses Apple's VideoToolbox encoder rather than `libx264`.

## Valve SteamCMD

SteamCMD is not bundled in the source tree. When the user explicitly confirms installation, the XPC service downloads the macOS archive from Valve's official CDN. SteamCMD and Steam Workshop content remain subject to Valve's and the content owner's terms. Background Engine supports anonymous downloads only and does not bypass ownership or Workshop permissions.

## Platform frameworks

Background Engine links Apple system frameworks including AppKit, AVFoundation, CoreGraphics, CoreImage, CoreMedia, QuartzCore, ScreenSaver, SwiftUI, and WebKit. These are supplied by macOS and Xcode, not redistributed as project source.
