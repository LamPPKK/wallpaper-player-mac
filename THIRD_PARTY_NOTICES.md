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
- Background Engine renderer build: `7acc6c9-be4`, containing the GPLv3 host-integration, standalone/explicit PKGV metadata normalization, macOS system-font resolution, and shader sampler-requirement patches shipped in this source tree.
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

## Lively bundled wallpaper collection

- Official project: <https://github.com/rocksdanister/lively>
- Official release: <https://github.com/rocksdanister/lively/releases/tag/v2.2.1.0>
- Release commit: `6860a4093fc50058c4815908658a4391c4449935`
- Audited installer: `lively_setup_x86_full_v2210.exe`
- Installer SHA-256: `98f4e96bb8e2c416384eeaf48016eadaea9dce8263b8d212052775ebcf2d7e34`
- Lively application license: GNU GPL version 3. Individual wallpapers and their embedded assets retain the separate licenses listed below.

The first four wallpaper projects in this distribution were extracted from the official release installer. They are not represented as files stored in the upstream Lively source checkout. Background Engine does not include the Lively desktop executable. It adds a normalized `project.json` compatibility descriptor to each selected wallpaper. Music TV's three root-relative local import URLs are rewritten as equivalent project-relative URLs so the fail-closed local-resource validator can prove they remain inside that wallpaper. All other installer metadata, source, media, copyright notices, and license files are retained. Two additional derivatives are pinned to separate official Lively wallpaper source repositories as described below. The immutable source-archive and installed-content hashes are recorded in `Sources/BackgroundEngineApp/Resources/LivelyWallpapers/catalog.json`.

The following six local Web wallpapers are included and are copied into the user's private Background Engine library only after the user opens **Lively Wallpapers** and chooses **Install Included Collection**:

### The Hill

- Author: Yoichi Kobayashi
- Original work: <https://codepen.io/ykob/pen/aBrjaR>
- Primary license: MIT
- Retained license and Lively modification notice: `Sources/BackgroundEngineApp/Resources/LivelyWallpapers/lively-the-hill/license.txt`
- Cinzel, copyright Natanael Gama, and Dancing Script, copyright Pablo Impallari and Igino Marini, are distributed under the SIL Open Font License 1.1. Roboto font data, copyright Google 2012, is distributed under Apache License 2.0. The full font licenses are retained below `lively-the-hill/css/fonts/`.
- Embedded Three.js, webgl-noise and shader sources retain their copyright and MIT notices. Consolidated dependency notices are kept beside the wallpaper in `THIRD_PARTY_NOTICES.txt`.

### Periodic Table

- Author: Mike Golus
- Original work: <https://codepen.io/mikegolus/pen/OwrPgB>
- License: MIT
- Retained license: `Sources/BackgroundEngineApp/Resources/LivelyWallpapers/lively-periodic-table/license.txt`
- The embedded normalize.css notice and MIT terms are kept beside the wallpaper in `THIRD_PARTY_NOTICES.txt`.

### Parallax.js

- Author and copyright holder: Matthew Wagerfield, copyright 2014
- Original source: <https://github.com/wagerfield/parallax>
- License: MIT
- Retained license: `Sources/BackgroundEngineApp/Resources/LivelyWallpapers/lively-parallax/LICENSE`
- FastClick, jQuery, Hammer.JS, Underscore.js and the requestAnimationFrame polyfill retain their MIT notices beside the wallpaper. The upstream `humans.txt` credits Claudio Guglieri for demo design and artwork.

### Music TV (LQ)

- Author: rocksdanister
- Original source: <https://github.com/rocksdanister/audio-visualizer-wallpaper>
- Wallpaper code: MIT, copyright 2023 rocksdanister
- Old TV model: visualdiscette, [source](https://sketchfab.com/3d-models/old-tv-3fb1a4b9d14c44abaac69fec119bf251), [Creative Commons Attribution 4.0](https://creativecommons.org/licenses/by/4.0/). No model geometry was changed by Background Engine.
- Colorful Studio environment: Poly Haven, [source](https://polyhaven.com/a/colorful_studio), [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/).
- Color Thief: copyright 2015 Lokesh Dhakar, MIT, <https://github.com/lokesh/color-thief>.
- Stats.js: copyright 2009–2016 stats.js authors, MIT, <https://github.com/mrdoob/stats.js>.
- Three.js revision 147: copyright 2010–2022 Three.js Authors, MIT, <https://github.com/mrdoob/three.js/tree/r147>.
- Earcut 2.2.4: copyright 2016 Vladimir Agafonkin, ISC, <https://github.com/mapbox/earcut/tree/v2.2.4>. Its retained ISC text is included beside the wallpaper as `Earcut-ISC.txt`.
- ES Module Shims 1.3.6: copyright 2018–2021 Guy Bedford, MIT, <https://github.com/guybedford/es-module-shims/tree/1.3.6>.
- Three.js `FilmShader`: the original implementation and noise algorithm are credited to Pat "Hawthorne" Shearon and the optimized scanline/noise version to Georg "Leviathan" Steinrohder; the retained port is licensed under [Creative Commons Attribution 3.0](https://creativecommons.org/licenses/by/3.0/). Background Engine did not modify the shader. A standalone attribution is included at `ThirdPartyLicenses/Lively-Music-TV-FilmShader-CC-BY-3.0.txt`.
- Retained attribution: `Sources/BackgroundEngineApp/Resources/LivelyWallpapers/lively-music-tv/license.txt`; additional MIT notices and license text are included at `ThirdPartyLicenses/Lively-Music-TV-MIT.txt`.

Music TV's authored system-audio and now-playing integrations receive bounded neutral compatibility events on macOS. Background Engine reports those unavailable real-time capabilities as **Limited**, rather than claiming full media-session parity.

### Depth Observatory

- Runtime source: <https://github.com/rocksdanister/depthmap-wallpaper>
- Pinned commit: `0a0e64ef5b1f56544899adfb909a335bfe246286`
- Audited source archive SHA-256: `b453c4cff443598144f186b3fb7fd2209da4570beed5ac3547e992502bce7e91`
- Depth-map runtime: MIT, based on work copyright 2023 Chris Johnson.
- Three.js revision 150: copyright 2010–2023 Three.js Authors, MIT.
- dat.GUI: copyright 2011 Data Arts Team, Google Creative Lab, Apache-2.0.
- Background Engine's original image, depth map and thumbnail are offered under CC0-1.0. They replace the upstream placeholders; no upstream wallpaper image is distributed.
- Full notices, the Apache-2.0 text and asset provenance are retained beside `lively-depth-observatory`.

### Chromatic Fluids

- Runtime source: <https://github.com/rocksdanister/WebGL-Fluid-Simulation>
- Pinned tag and commit: `v6`, `bd028c0b4a931c4173e77e52cb953d964e857557`
- Audited source archive SHA-256: `4a10cffb51ec5c86b1464c1d91b25773da4b27288dd5874a422ab49c6323556f`
- Simulation: copyright 2017 Pavel Dobryakov, MIT; Lively integration by rocksdanister.
- Only the tagged simulation script and its small dithering texture are retained. Background Engine does not distribute the release package's Pexels backgrounds, logo, overlay, font, promotional preview or unused dat.GUI dependency.
- Background Engine's generated thumbnail is offered under CC0-1.0. Full notices and asset provenance are retained beside `lively-chromatic-fluids`.

The following eight wallpapers present in the same installer are intentionally not redistributed by Background Engine after a conservative asset and license audit:

- **Triangles & Light**: one embedded Delaunay implementation has ambiguous provenance between differently licensed distributions.
- **Medusae**: the installer contains a stripped JavaScript bundle whose complete dependency notices and authorship chain could not be verified.
- The installer package for **Fluids** and **Music Tunnel**: contains Pexels assets that were not selected for redistribution in this vendored package. Chromatic Fluids is a separate media-free derivative of the pinned source tag.
- **Simple System**: contains `pcmr.png` without an explicit reusable license in the package.
- **Rain**: combines CC BY-NC-SA material with separate Pexels and Unsplash assets.
- **Living Room**: contains a CGTrader model with separate redistribution restrictions.
- **Matrix Rain**: did not include a usable license notice in the installer package.

This exclusion list records Background Engine's packaging decision; it does not decide what an end user may separately download or use under the applicable terms.

### Optional official Lively downloads

Rain v3, Snow v1, and Clouds v1.0 are not embedded in the app, source tree, DMG, or SBOM. The Library menu can download their exact official GitHub release archives only after the user reviews the license prompt. Each catalog entry pins its official repository, tag commit, archive byte count, and SHA-256; the downloader verifies those values before invoking the safe Lively package importer.

These upstream projects use Creative Commons Attribution-NonCommercial-ShareAlike 3.0 terms and may include separately attributed media. Background Engine does not relicense them and does not grant commercial-use or redistribution rights. The source and license links shown before download are authoritative for the user's use.

Background Engine can also normalize and import a Lively Wallpaper `.zip` export or project folder that the user supplies. That path copies the selected package into the user's private library, never marks it redistributable, and does not add the package or its assets to Background Engine's source archive, DMG notices, or SBOM. The user remains responsible for the package's license and content rights.

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
