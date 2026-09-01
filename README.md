<p align="center">
  <img src="Sources/User_Documentation_en_US/Documentation.docc/Resources/documentation-art/WallpaperPlayer-icon@2x.png" width="152" alt="Background Engine logo">
</p>

<h1 align="center">Background Engine</h1>

<p align="center">
  A native, privacy-conscious wallpaper player for macOS.<br>
  Play legally acquired Wallpaper Engine projects across one or more displays.
</p>

<p align="center">
  <img alt="macOS 14 or newer" src="https://img.shields.io/badge/macOS-14%2B-111111?logo=apple">
  <img alt="Apple Silicon and Intel" src="https://img.shields.io/badge/Universal-arm64%20%7C%20x86__64-2864DC">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
  <img alt="GPL version 3" src="https://img.shields.io/badge/License-GPLv3-663399">
  <img alt="Version 0.2.0 alpha 1 build 23" src="https://img.shields.io/badge/version-0.2.0--alpha.1%20(23)-E3A008">
</p>

![Background Engine Library](docs/images/background-engine-library.png)

> [!IMPORTANT]
> Background Engine is an alpha project. Scene playback is best-effort and depends on the features used by each wallpaper. Users must provide their own legally acquired Wallpaper Engine content and engine assets.

## Current capabilities

- Import complete Wallpaper Engine project folders, user-provided Lively Wallpaper `.zip` exports or project folders, standalone media files, Web URLs, and supported Wallpaper Engine Scene PKGV `.pkg` files.
- Download eligible Workshop items by URL or numeric ID through an anonymous, constrained SteamCMD XPC service for app ID `431960`. The service requests SteamCMD `validate`, publishes a distinct **Importing** state while the downloaded project is checked and copied, rejects a genuinely overlapping Workshop operation, and releases a completed install before replying so the immediate download step cannot receive a false busy result.
- Play compatible video directly with AVFoundation and convert other valid local containers atomically with bundled FFmpeg.
- Render still images and frame-timed GIF, APNG, and WebP animation with ImageIO and bounded memory use.
- Run Web wallpapers through the self-hosted Plash runtime and a non-persistent, restricted WKWebView.
- Install six license-reviewed Web wallpapers from official Lively sources into the private library with one explicit action, including the project-created **Depth Observatory** parallax wallpaper and a media-free **Chromatic Fluids** derivative. Nine more official releases—including weather, system-information and music visualizer samples—can be downloaded on demand after a per-wallpaper license and compatibility confirmation.
- Play compatible 2D Scenes live; render unsupported Scene features to a validated 20-second, 30 FPS MP4 cache when the external renderer and user-provided engine assets are available. Build 21 admits only immutable Scene cache generations whose sidecar, size, and SHA-256 match, and now requires at least one actually decoded video frame before publishing a render; a merely declared stream or demuxable corrupt packet is rejected. It falls back to an older verified generation and deduplicates recovery if cached playback fails on several displays. The queue runs at most two distinct external renders, preserves FIFO order, and starts each render timeout only after that job receives a permit; balanced/high renders retry once at low quality after a timeout. Authored sound resolves from `scene.pkg`, the unpacked project, then engine assets without permitting path or symlink escape.
- Maintain an independent wallpaper, layout, quality, and playback session for every connected display.
- Use the active video or Scene cache in the bundled Universal screen saver when macOS locks the session.
- Pause for sleep, Low Power Mode, or a fully covered desktop, then restore playback and window ordering after wake, Space changes, and display reconnection.
- Store a versioned private library in `~/Library/Application Support/Background Engine` without modifying the original Workshop folder.
- Validate imports against path traversal, symbolic-link escapes, size limits, malformed packages, and duplicate content using SHA-256.
- Report renderer, FFmpeg/ffprobe, and engine-assets health; export redacted diagnostics without wallpaper assets or Steam information.
- No telemetry, account, cloud sync, Steam password collection, or embedded Workshop catalog.

Windows Application wallpapers are detected and labeled **Unsupported**. Every other imported project receives a visible **Full Live**, **Full Cached**, **Limited**, or **Unsupported** result with a reason.

## Screenshots

<table>
  <tr>
    <td width="50%"><img src="docs/images/background-engine-downloads.png" alt="Anonymous Steam Workshop download screen"></td>
    <td width="50%"><img src="docs/images/background-engine-displays.png" alt="Independent wallpaper settings for two displays"></td>
  </tr>
  <tr>
    <td align="center"><strong>Anonymous Workshop downloads</strong></td>
    <td align="center"><strong>Independent multi-display sessions</strong></td>
  </tr>
  <tr>
    <td colspan="2"><img src="docs/images/background-engine-settings.png" alt="Playback settings and runtime health checks"></td>
  </tr>
  <tr>
    <td colspan="2" align="center"><strong>Playback controls, Runtime Health, engine assets, and diagnostics</strong></td>
  </tr>
</table>

The screenshots above are captured from the macOS application itself. No Wallpaper Engine content is included in this repository.

## Supported wallpaper types

| Type | Playback path | Notes |
| --- | --- | --- |
| Video | AVFoundation direct playback or atomic FFmpeg conversion | Content is probed instead of trusted by extension. Supported inputs include AVFoundation- or FFmpeg-readable local containers such as MP4, MOV, WebM, MKV, and AVI. After the source is copied into the private library, a cancellable, time-bounded AVFoundation probe requires both `isPlayable` and a video track. This keeps system-supported HEVC, ProRes, HDR, and alpha video on the original **Direct** path instead of discarding fidelity through needless conversion; a rejection, load failure, timeout, or occupied process-wide probe budget falls back to the existing FFmpeg path. File, folder, legacy-library, and SteamCMD imports all convert automatically when needed. Converted playback prefers VideoToolbox H.264 and uses bundled native MPEG-4/mp4v only when FFmpeg reports a recognized VideoToolbox session failure. It scales an odd dimension up by at most one pixel while preserving display aspect ratio, and preserves rotation, color metadata, and audio where possible. If only the authored audio metadata/encode is unusable, build 21 keeps the visual wallpaper as a video-only **Limited** conversion with `video_audio_unavailable`; stream-count and decoded-dimension limits remain hard failures. Conversion cache keys include the recipe version, so a legacy cache stays playable but is flagged for a safe rebuild from the copied source. |
| Image | ImageIO still or animated playback | Supports ImageIO-readable images, including GIF, APNG, and WebP animation with source frame timing. |
| Web | PlashRuntime + restricted WKWebView | Supports local Web projects, Lively Wallpaper `.zip` exports and folders, ordinary website URLs, a native editor for boolean/slider/color/combo/text/button properties, sandboxed file/directory properties, callbacks registered after startup, pause callbacks, autoplay of local media, presentation CSS/JavaScript, print styles, and color inversion. Lively `LivelyInfo.json` and `LivelyProperties.json` are normalized only on an isolated staging copy; source packages are never edited. Metadata-only Lively URL and video-stream exports become restricted Web wallpapers and require a per-wallpaper opt-in before a public HTTPS target can load. Because remote content cannot be statically inspected, an enabled URL stays live but is honestly reported **Limited** with `web_remote_runtime_unverified`, never false Full. Lively buttons are momentary native controls: a click sends `livelyPropertyListener(name, true)` to every active display running the exact asset revision without persisting the event or reopening its window. Generic Wallpaper Engine buttons similarly receive `applyUserProperties({name: {value: true}})`. Folder dropdowns expose authored choices and can copy one or several filtered files inside the wallpaper sandbox; the last file becomes active, every imported file remains selectable, and only the delete control remains Limited. Required local scripts/stylesheets are validated before playback across the complete bounded entrypoint, including executable inline script/style blocks, template-literal expressions, reachable static ES-module imports, and CSS `@import`, so incomplete projects are reported instead of opening a blank window. Script dependencies are collected only from executable/default/module script types; JSON and speculation-rule data blocks plus classic `nomodule` fallbacks remain inert on the macOS 14 module-capable Web runtime. Build 16 resolves bounded inline import maps with bare and URL-like keys, longest-matching scopes, prefix mappings, and reachable `null` blocks; it fails closed for malformed, oversized, unsafe, late, duplicated, or unmapped imports. Local `.js` and `.mjs` imports are recursively analyzed; other local literal specifiers are still checked for existence and project-root containment but are not parsed recursively. Static `fetch`, XHR, WebSocket, EventSource, Worker, and beacon targets share the same project-containment and public/private-network policy as declared resources; dynamic request targets remain playable but are labeled **Limited** instead of being claimed Full. Required HTTP(S)/WS(S) dependencies remain blocked with an actionable `web_network_access_required` result until the user opts that wallpaper into external network access. Dependency probing is bounded and fails closed with `web_dependency_probe_limit_exceeded` when a project exceeds its safety limits. Audio visualization and Windows system-media integration receive neutral compatibility events and are labeled Limited. Probe 16 also detects mouse, pointer, touch, wheel, drag, and click handlers; because desktop wallpaper windows ignore input, those projects remain playable but are classified **Limited** with `web_interaction_limited`. |
| Scene | Native live renderer or rendered Scene cache | Accepts Wallpaper Engine PKGV Scene packages, including large structurally valid packages inspected through read-only memory mapping and bounded entry reads. A macOS installer `.pkg` is not a wallpaper and is rejected. Full Scene cache rendering requires user-provided `wallpaper_engine/assets`. |
| Windows Application | None | Recognized and reported as **Unsupported**. Wine and CrossOver are outside this project's scope. |

Web suspension is enforced below the optional wallpaper callbacks: the injected
runtime freezes `requestAnimationFrame`, timeout and interval work in the main
page and child frames, while WKWebView suspends native media. Lively pages that
do not implement a pause callback therefore stop rendering when the desktop is
covered or the Mac sleeps, then resume their pending work after wake.

### Compatibility labels

| Label | Meaning |
| --- | --- |
| **Full Live** | The wallpaper is rendered in real time with every detected required capability available. |
| **Full Cached** | The visual result is rendered ahead of time and played as a validated video loop. |
| **Limited** | The primary visual playback remains available, but every approximated or unavailable capability—such as authored sound, mouse interaction, full SceneScript, or audio reactivity—is listed explicitly. |
| **Unsupported** | The project cannot produce valid playback. The UI displays a stable diagnostic code and reason instead of opening a black wallpaper window. |

Scene classification combines static feature analysis with a small renderer preflight. A dark or intentionally static frame is a warning, not an automatic failure. Crashes, timeouts, missing frames, corrupt packages, and missing required assets are treated as hard failures.

Compatibility probe version 22 detects reachable particle emitters, initializers, operators, renderers, child systems, and collection forms that the bundled Scene renderer would otherwise accept but silently omit. Those Scenes are now reported as **Limited** with exact particle-module reasons instead of **Full Cached** merely because preflight emitted one frame. It retains probe 21's explicit-font renderer routing, probe 20's expanded staging-only package-root HTML, CSS, import-map, and ES-module normalization for Web and Lively assets, probe 19's rule that permitted remote Website and Lively URL/video-stream exports remain **Limited**, and probe 18's classification of opaque or dynamically constructed local media as Limited. Discovery examines at most 10,000 project entries, sorts and stages at most 64 eligible candidates, records a path-free truncation diagnostic, and still loads the page. At playback time, AVFoundation-compatible local audio and video remain direct sources; FFmpeg conversion is reserved for sources WebKit cannot play.

Those retained rules include bounded inline import maps with bare and URL-like keys; Static `fetch`, XHR, WebSocket, EventSource and other requests obey the same containment and network policy, while dynamic request targets stay **Limited**. Pointer-dependent pages use `web_interaction_limited`. Scene packages that once hit the former 512 MiB inspection limit are now read through bounded memory mapping. Audio-reactive detection covers `supportsaudioprocessing`, reachable `audioprocessingmode` settings and bounded `g_Audio*` shader identifiers. Authored sound loops only when a valid string `playbackmode` is exactly lowercase `"loop"`; a non-string value is invalid renderer metadata and remains **Limited** rather than receiving guessed behavior.

## Multi-display playback

Background Engine keys assignments by the stable display UUID rather than the temporary display index. Each connected display has its own:

- Wallpaper assignment and playback session.
- **Fit**, **Fill**, or **Stretch** layout.
- **Low**, **Balanced**, or **High** quality selection.
- Recovery lifecycle when resolution, Retina scale, primary-display status, or connection state changes.

Wallpaper audio is off by default. When enabled, it plays only from the primary display so multiple sessions do not produce competing audio streams. A failure or cache job on one screen does not stop wallpapers on other screens.

Web and Lively property overrides are stored with the library asset in this alpha. If the same asset is assigned to more than one display, changing its properties refreshes every display using that asset; wallpaper assignment, layout, quality, lifecycle, and playback sessions remain independent per display.

## Importing wallpapers

### Local projects and files

1. Open **Library**.
2. Choose **Browse** and scan a copied `steamapps/workshop/content/431960` folder, or use **Add Wallpaper File…** for standalone media and Scene packages.
3. Select an imported wallpaper, choose its layout, and assign it to a display.

Imports are staged and committed atomically into Background Engine's private library. Existing source folders are never edited or deleted. Content hashes and Workshop IDs prevent duplicate copies.

### Web wallpapers

Choose **Add Website…** to add an HTTPS address. Web content uses ephemeral website storage, blocks downloads and native commands, rejects credential-bearing URLs, and restricts navigation to the trusted origin. Local Web projects cannot read files outside their project root. Network access for a local project remains disabled until the user enables it for that wallpaper. The opt-in warning explains that hostname resolution and DNS rebinding can still reach services on the local network; enable it only for wallpaper code you trust.

The property bridge supports boolean, slider, color, combo, text, momentary button actions, `applyUserProperties`, `applyGeneralProperties`, and `setPaused`. Use **Library → More → Customize Web Properties…** to edit scalar values or invoke an action; file and directory properties remain in the same menu and are copied into the wallpaper's private sandbox. Saving refreshes only displays currently using that wallpaper, while a button action is delivered immediately to all matching live display sessions without a restart. **Reset to Defaults** removes custom scalar overrides so future Workshop defaults can take effect; buttons are never persisted. The bridge also defines Wallpaper Engine's Web media registration functions so a wallpaper can keep running when Windows media-session data is unavailable. Audio listeners receive a neutral 128-bin spectrum; media listeners receive disabled/empty status, metadata, thumbnail, playback, and timeline events. These wallpapers are labeled **Limited** because Background Engine does not capture system audio or expose Windows media sessions.

### Bundled Lively wallpapers

Open **Library**, choose **Lively Wallpapers**, then **Install Included Collection** to validate and copy the optional collection into Background Engine's private library. Installation is explicit and idempotent: the app does not silently reinstall removed items, and the source resources in the app bundle are never used as a writable library.

The collection contains six local Web wallpapers:

| Wallpaper | Primary author | License notes |
| --- | --- | --- |
| The Hill | Yoichi Kobayashi | MIT; bundled Cinzel and Dancing Script fonts use SIL OFL 1.1, and Roboto uses Apache-2.0 |
| Periodic Table | Mike Golus | MIT |
| Parallax.js | Matthew Wagerfield | MIT |
| Music TV (LQ) | rocksdanister | MIT/ISC code; the Old TV model is CC-BY-4.0, the Colorful Studio HDR is CC0-1.0, and FilmShader is CC-BY-3.0 |
| Depth Observatory | rocksdanister runtime; Background Engine artwork | MIT/Apache-2.0 runtime; original image, depth map, and thumbnail are CC0-1.0 |
| Chromatic Fluids | Pavel Dobryakov; Lively integration by rocksdanister | MIT simulation and tagged dithering texture; original thumbnail is CC0-1.0 |

The first four entries are derived from the official [Lively `v2.2.1.0` release installer](https://github.com/rocksdanister/lively/releases/tag/v2.2.1.0), pinned to release commit `6860a4093fc50058c4815908658a4391c4449935`; they are not claimed to live in the upstream source checkout. The audited installer SHA-256 is `98f4e96bb8e2c416384eeaf48016eadaea9dce8263b8d212052775ebcf2d7e34`. Background Engine adds a normalized `project.json` compatibility descriptor to each copied wallpaper while preserving the original Lively metadata and license files. Parallax.js also removes twelve compiled CSS references to absent Awwwards badge images whose markup is already commented out; this offline-compatibility adjustment is documented beside that wallpaper and does not change its rendered scene.

Depth Observatory is sourced separately. Its WebGL runtime is pinned to the official [Lively depth-map wallpaper](https://github.com/rocksdanister/depthmap-wallpaper) commit `0a0e64ef5b1f56544899adfb909a335bfe246286`; the audited commit archive SHA-256 is `b453c4cff443598144f186b3fb7fd2209da4570beed5ac3547e992502bce7e91`. Background Engine replaces the upstream image placeholders with an original image/depth-map pair created for this repository and adds a slow idle drift so the parallax remains animated in click-through desktop windows. The visual stays usable without pointer events and is honestly labeled **Limited** because interactive mouse control is unavailable.

Chromatic Fluids is derived from the official [WebGL Fluid Simulation `v6`](https://github.com/rocksdanister/WebGL-Fluid-Simulation/tree/v6) source at commit `bd028c0b4a931c4173e77e52cb953d964e857557`; the audited source archive SHA-256 is `4a10cffb51ec5c86b1464c1d91b25773da4b27288dd5874a422ab49c6323556f`. Only the MIT simulation script and tagged dithering texture are retained. Background Engine excludes the release archive's Pexels backgrounds, logo, overlay, font, promo files, and unused dat.GUI dependency, supplies a CC0 thumbnail, and enables automatic splats so the animation continues without system-audio capture or pointer input. Missing audio reactivity and interaction are reported as **Limited**.

Eight other installer wallpaper packages are intentionally not redistributed: **Triangles & Light** has ambiguous provenance for one embedded Delaunay implementation; **Medusae** is a stripped bundle whose complete dependency notices and authorship chain could not be verified; the installer versions of **Fluids** and **Music Tunnel** contain Pexels assets that were not suitable for this vendored package; **Simple System** contains `pcmr.png` without an explicit reusable license; **Rain** combines CC BY-NC-SA content with Pexels/Unsplash assets; **Living Room** contains a CGTrader model with separate redistribution restrictions; and **Matrix Rain** did not include a usable license notice. Chromatic Fluids does not reuse the installer media. This is a conservative packaging decision, not a claim about whether an end user may obtain or use those wallpapers separately.

The **Lively Wallpapers** menu also offers nine optional direct downloads from pinned rocksdanister GitHub releases:

| Download | Package terms shown before download | Background Engine result |
| --- | --- | --- |
| Rain v3 | CC BY-NC-SA 3.0 plus retained media notices | Live Web wallpaper |
| Snow v1 | CC BY-NC-SA 3.0 plus retained media notices | Live Web wallpaper |
| Clouds v1.0 | CC BY-NC-SA 3.0 plus retained media notices | Live Web wallpaper |
| Simple System | MIT package notice with retained artwork/dependency credits | **Limited**: charts animate with neutral values because Windows hardware telemetry and chart pointer input are unavailable |
| Simple System 3D | MIT code with retained CC0, CC BY and CC BY-NC asset notices | **Limited**: the 3D scene remains visible but hardware, media, audio and pointer inputs are unavailable or neutral; dynamic requests stay under network permission |
| Weather Demo | MIT code plus retained weather-icon and SIL OFL notices | **Limited/network-blocked** until the user supplies an OpenWeatherMap key and enables network access |
| Ferrari 458 Italia | MIT package notice plus retained model and HDRI attribution links | **Limited**: the 3D car remains visible, but audio-reactive lighting receives neutral data, pointer/orbit camera control is unavailable, and dynamic requests remain under network permission |
| Music Tunnel | MIT, SIL OFL 1.1, and retained shader/media attribution notices | **Limited**: the tunnel remains animated, but Windows Now Playing colour updates and pointer interaction are unavailable, and dynamic requests remain under network permission |
| AudiOrbits | GPL-3.0 with retained package notices | **Limited**: automatic orbit motion works, while system-audio reactivity and cursor parallax are unavailable or neutral; dynamic requests stay under network permission |

These projects are not embedded in the app, repository, DMG, source archive, or SBOM. Before downloading, Background Engine shows that individual entry's terms, runtime limitation, archive size, pinned source, and license link. The downloader accepts only an exact catalog entry, follows only trusted GitHub HTTPS responses, enforces both the pinned byte count and SHA-256, and sends the verified archive through the same traversal/symlink/decompression-safe Lively importer. Build 23 shows byte progress, exposes Cancel through download/verification/import, and retains a per-wallpaper Retry action after cancellation or failure. This convenience does not grant rights beyond each upstream license.

Choose **Browse Lively Sample Projects…** to open Lively's upstream [Sample Wallpaper Projects](https://github.com/rocksdanister/lively/wiki/Sample-Wallpaper-Projects) page. That page mixes projects and licenses, and includes examples that are not portable to macOS, so Background Engine never scrapes or executes it as a remote catalog. Download only content you are entitled to use, inspect its terms, then import a lawful ZIP or folder with **Add Lively…**.

To use another wallpaper that you obtained legally, choose **Add Lively…** and select either its exported `.zip` file or its project folder containing `LivelyInfo.json`. Background Engine validates the ZIP central directory before extraction, rejects encrypted, multi-disk, traversal, symlink, collision, and decompression-bomb shapes, and validates the extracted tree again. It maps supported Lively metadata and property controls to the native Web compatibility bridge on a temporary copy, then atomically imports the result as user-owned, non-redistributable content. Because Lively treats `/js/...` as package-root-relative while Background Engine protects each loopback session with a random path token, an unambiguous local Web entrypoint with no `<base>` element has quoted root-relative resource and import-map values normalized only on that staging copy. Ambiguous base semantics remain fail-closed instead of weakening the token boundary. Local Video, GIF/Picture, Web and WebAudio packages use the existing native playback paths. Metadata-only URL and video-stream packages accept only public HTTPS targets and remain blocked until network access is explicitly enabled for that wallpaper. Web buttons use Lively's one-shot callback semantics. A Web folder dropdown can copy one or several filtered files through Library's **More** menu; every copy stays in the wallpaper sandbox, the last file becomes active, and the native editor can switch between imported and authored choices. It remains **Limited** because Lively's delete control is not implemented yet. WebAudio receives neutral audio data, and Lively controls attached to native Video/Image playback remain **Limited** until their corresponding live behavior is available. Windows application-type Lively packages are retained only as an **Unsupported** library item and are never executed.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and the license files retained beside each wallpaper under [LivelyWallpapers](Sources/BackgroundEngineApp/Resources/LivelyWallpapers) for complete attribution.

### Steam Workshop

1. Open **Downloads**.
2. Paste an official Steam Community Workshop URL or a numeric item ID.
3. Confirm installation of SteamCMD when prompted.
4. Assign the imported result from **Library** after the download completes.

SteamCMD runs anonymously and is only allowed to construct install, download, cancel, and diagnostic requests for Wallpaper Engine Workshop app ID `431960`. The generated request pins the Windows content platform and passes `+force_install_dir` for Background Engine's private SteamCMD root before anonymous login. A result is accepted only when SteamCMD emits a success receipt containing the exact absolute private item path; a missing, malformed, redirected, wrong-item, or symlinked location fails closed before import. Background Engine never requests a Steam username, password, or Web API key, and it does not bypass ownership or Workshop permissions. If Valve denies anonymous access, install the item through Steam on Windows and copy the legally owned project folder to the Mac.

The SteamCMD installer accepts only a successful HTTPS response from Valve's pinned host. It bounds the compressed archive, entry list, expanded size, and extraction time; rejects traversal, duplicate paths, special files, data-directory collisions, and symlinks that leave the staging root; then swaps the complete runtime through same-volume directory renames. Every app-owned runtime path component is checked before recovery, installation, preflight, launch and receipt validation, so a symlink cannot redirect the private runtime into the user's normal Steam library. A durable transaction marker restores the previous runtime after an interrupted update without touching downloaded Workshop content. On Apple Silicon, Background Engine accepts a native ARM or Universal SteamCMD executable; Valve's current Intel-only executable requires Rosetta and otherwise reports `rosetta_required`. The app checks for Rosetta but never installs it or invokes privileged tools.

Valve SteamCMD can try to update `~/Library/Application Support/Steam/logs/stderr.txt` even when its install directory is private. Background Engine blocks that normal-Steam write by launching SteamCMD through the fixed `/usr/bin/sandbox-exec` executable with a private `0600` profile; it does not change `HOME` or `CFFIXED_USER_HOME`. Apple marks `sandbox-exec` as deprecated, so this is a fail-closed defense-in-depth boundary rather than a future platform API: if the executable, profile, or sandbox application is unavailable or invalid, SteamCMD is not launched and there is no unsandboxed fallback.

## Scene playback and engine assets

Compatible 2D Scene features use the native parser and renderer. More complex Scenes use the bundled GPL renderer to produce a local MP4 cache through a raw video pipe and bundled FFmpeg. VideoToolbox H.264 is preferred, with a classified MPEG-4/mp4v recovery path when the macOS encoder session is unavailable. The output is validated before an immutable cache generation is atomically published; a failed render retries once at lower quality and never removes a known-good generation.

Scene cache identity includes the wallpaper content hash, renderer version, FFmpeg build ID, engine-assets fingerprint, resolution, and quality. Render jobs are bounded, deduplicated by their actual output key, cancellable, timed out, and terminated per display job during sleep or app shutdown so one failed screen cannot kill another screen's renderer or leave child processes behind. Raw and PNG recording paths reject truncated output before encoding: long recordings may miss at most one final flush frame, short recordings must be exact, and PNG sequences must be contiguous from `frame_00001.png`. Every completed cache is published at a unique immutable generation URL with a versioned metadata sidecar bound to the MP4 size and SHA-256. Sidecar verification runs off the main thread and is shared by displays using the same generation. A missing file, failed mux, absent final audio stream, corrupt sidecar, or stale generation keeps valid visual playback available but changes the result to **Limited**, lists `sound` as missing, and reports `scene_authored_audio_unavailable` instead of silently claiming Full Cached.

Background Engine does not distribute proprietary Wallpaper Engine assets. To enable Scene cache rendering:

1. Open **Settings**.
2. Under **Scene Engine Assets**, choose a legally obtained `wallpaper_engine/assets` directory.
3. Review **Runtime Health** and use **Retry** after all required files are available.

Clock and text content can combine a cached base with a native live overlay. Full SceneScript interaction, mouse interaction, and audio-reactive behavior remain **Limited** in this milestone.

## Screen saver and lock behavior

The Universal `.saver` bundle can be installed for the current user and selected in System Settings. It reuses a compatible video or Scene cache. “Lock screen animation” means this screen saver can run while the macOS session is locked; Background Engine does not modify the login-window background.

## Privacy and security

- The application works locally and has no telemetry.
- Web storage is non-persistent, and external access is opt-in per wallpaper.
- User-selected folders use security-scoped bookmarks.
- SteamCMD is isolated behind a narrow XPC interface and cannot receive arbitrary shell commands.
- SteamCMD is validated in a private staging directory and installed transactionally; existing `steamapps` content is preserved.
- Diagnostics redact local paths and exclude wallpaper files, Steam IDs, and credentials.
- Release FFmpeg builds disable network protocols and device capture.
- Imported files are copied into the application library after traversal, symlink, decompression, and size validation.

## Requirements

- macOS 14 Sonoma or newer.
- Apple Silicon (`arm64`) or Intel (`x86_64`) Mac.
- Xcode 16 or newer to build from source; the CI release pipeline currently validates with a current macOS Xcode toolchain.
- User-provided Wallpaper Engine assets for rendered Scene caches.
- Legal access to every imported wallpaper and its dependencies.

The current source milestone is **v0.2.0-alpha.1, build 23**. Prebuilt artifacts, when published, are available from [GitHub Releases](https://github.com/LamPPKK/wallpaper-player-mac/releases).

## Build

Clone the repository, generate the Xcode project, then open it:

```sh
git clone https://github.com/LamPPKK/wallpaper-player-mac.git
cd wallpaper-player-mac
xcodegen generate
open "Background Engine.xcodeproj"
```

The app targets macOS 14+, uses Swift 6 strict concurrency, and produces Universal `arm64`/`x86_64` app, XPC, and screen-saver products. XcodeGen is required only when regenerating `Background Engine.xcodeproj` from `project.yml`.

Swift Package Manager can build the core, app executable, command-line tools, and tests:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift build -c release --disable-sandbox

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --disable-sandbox
```

The external GPL Scene renderer has additional CMake dependencies. See [ExternalRenderers/README.md](ExternalRenderers/README.md).

Build the pinned, signed-source FFmpeg 9.0.1 runtime for both architectures and merge it into a local-only Universal runtime:

```sh
./Scripts/build-ffmpeg-runtime.sh /absolute/path/to/ffmpeg-universal-runtime
```

GnuPG and the build tools documented by the script are required. The Release app does not fall back to a Homebrew installation.

### Tests and command-line diagnostics

The repository includes unit, application, UI, media-runtime, renderer, packaging, concurrency, migration, and security regression tests. FFmpeg-dependent tests require the two runtime paths:

```sh
BACKGROUND_ENGINE_FFMPEG=/absolute/path/to/ffmpeg \
BACKGROUND_ENGINE_FFPROBE=/absolute/path/to/ffprobe \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --disable-sandbox
```

Before changing a pinned optional Lively release, place the five unmodified
archives named in the catalog in one external directory and run the release
corpus gate. The bytes remain outside Git; setting the require flag makes a
missing directory a test failure instead of an informational note:

```sh
BACKGROUND_ENGINE_OFFICIAL_LIVELY_ARCHIVE_DIR=/absolute/path/to/lively-release-zips \
BACKGROUND_ENGINE_REQUIRE_OFFICIAL_LIVELY_ARCHIVES=1 \
  xcrun swift test --disable-sandbox \
    --filter testConfiguredOfficialReleaseCorpusImportsEveryCatalogWallpaper
```

GitHub-hosted macOS virtual machines do not expose an NSGL pixel format that
GLFW can use, so CI runs the standalone Scene package smoke in explicit
`--load-only` mode on both architectures. On a Mac with an active graphical
session, the default command remains the real renderer gate and fails unless
the synthetic standalone package produces exactly two non-empty PNG frames:

```sh
./Scripts/smoke-test-standalone-scene-package.sh \
  /absolute/path/to/background-engine-scene-renderer
```

`be-cli` provides local corpus tooling without copying owned Workshop content into Git:

```sh
swift run be-cli inventory /absolute/path/to/corpus
swift run be-cli scene-engine-info /absolute/path/to/wallpaper_engine/assets
swift run be-cli scene-parity-check \
  --windows /absolute/path/to/windows-reference.mp4 \
  --mac /absolute/path/to/mac-render.mp4 \
  --out /absolute/path/to/report \
  --size 1920x1080

# Or render a Scene deterministically and compare it with owned golden PNGs.
BACKGROUND_ENGINE_SCENE_RENDERER=/absolute/path/to/background-engine-scene-renderer \
BACKGROUND_ENGINE_SCENE_ASSETS_DIR=/absolute/path/to/wallpaper_engine/assets \
swift run be-cli scene-parity-check \
  /absolute/path/to/project/scene.pkg \
  /absolute/path/to/golden-frames \
  --out /absolute/path/to/golden-report
```

Parity report directories must not already exist. The tooling never overwrites
an owned corpus; it writes per-frame metrics, filtered renderer logs, and a
side-by-side contact sheet into a new report directory. The golden-frame mode
requires Xcode command-line tools plus the pinned local FFmpeg runtime.

## Project layout

| Path | Purpose |
| --- | --- |
| `Sources/BackgroundEngineCore` | Versioned models, importing, probing, migration, cache keys, validation, and reusable app logic. |
| `Sources/BackgroundEngineApp` | SwiftUI application, per-display sessions, Aerial-inspired video coordination, Plash Web playback, Scene playback, and diagnostics. |
| `Sources/SteamCMDRunnerService` | Constrained anonymous SteamCMD XPC service. |
| `Sources/BackgroundEngineScreenSaver` | Universal ScreenSaver.framework plug-in. |
| `ExternalRenderers` | Pinned GPL Scene renderer source and build documentation. |
| `Scripts` | Runtime builds, media smoke tests, parity tools, SBOM generation, signing, notarization, and packaging. |
| `Tests` | Core, app, script, runtime, packaging, and UI regression coverage. |

## Package a DMG

Create a self-contained unsigned development DMG from verified Universal runtimes:

```sh
SCENE_RENDERER_RUNTIME_DIR="/absolute/path/to/universal/scene-runtime" \
FFMPEG_RUNTIME_DIR="/absolute/path/to/ffmpeg-universal-runtime" \
./Scripts/package-app.sh
```

The Xcode Release and Archive paths use the same validator and fail closed when
either runtime is missing. Pass the runtime directories as build settings:

```sh
xcodebuild -project "Background Engine.xcodeproj" \
  -scheme "Background Engine" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath /absolute/path/to/BackgroundEngine.xcarchive \
  'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  BACKGROUND_ENGINE_FFMPEG_RUNTIME_DIR="/absolute/path/to/ffmpeg-universal-runtime" \
  BACKGROUND_ENGINE_SCENE_RENDERER_RUNTIME_DIR="/absolute/path/to/universal/scene-runtime" \
  archive
```

Debug builds may omit both settings while working on UI or direct playback.
Those builds intentionally do not provide format conversion or Scene-cache
rendering.

Create a Developer ID-signed and notarized release:

```sh
REQUIRE_SIGNING=1 REQUIRE_NOTARIZATION=1 \
SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
NOTARY_PROFILE="background-engine-notary" \
SCENE_RENDERER_RUNTIME_DIR="/absolute/path/to/universal/scene-runtime" \
FFMPEG_RUNTIME_DIR="/absolute/path/to/ffmpeg-universal-runtime" \
./Scripts/package-app.sh
```

Release packaging and Xcode Archive fail closed unless the app, Scene renderer, FFmpeg, ffprobe, XPC service, and screen saver have valid `arm64` and `x86_64` slices. They share the same staged runtime embedding and dependency-closure validation, so a failed update cannot replace a known-good runtime inside the product. Release packaging signs nested code before the app and DMG, submits with `notarytool`, staples the ticket, runs Gatekeeper assessment, and creates SHA-256, source, license, compatibility, and CycloneDX SBOM artifacts.

## Known limitations

- Windows Application wallpapers do not run through Wine or CrossOver.
- Scene compatibility is corpus-scoped; the Wallpaper Engine format and SceneScript API are broad and can change.
- Full SceneScript, mouse interaction, and audio-reactive system-audio capture are not classified as Full in v0.2.
- Anonymous SteamCMD availability is controlled by Valve and the Workshop item owner.
- The app does not include Wallpaper Engine engine assets or third-party Workshop projects.
- This alpha still requires physical-device validation for every Intel/Apple Silicon, sleep/wake, Spaces, lock, and multi-display release matrix before a stable release.

## Contributing

Bug reports should include the compatibility label, stable error code, feature fingerprint, macOS version, Mac architecture, and sanitized diagnostics exported from **Settings**. Do not attach paid Workshop content, Wallpaper Engine assets, Steam credentials, or personal filesystem paths.

Before submitting a change, run the relevant Swift tests and `git diff --check`. Changes to playback or packaging should also pass the Universal Xcode build and the applicable FFmpeg/renderer smoke tests.

## Legal and content ownership

Background Engine is licensed under the [GNU General Public License version 3](LICENSE). It is not affiliated with, endorsed by, or sponsored by Valve Corporation or Wallpaper Engine.

Users must own or otherwise be licensed to use Wallpaper Engine, imported content, references, and engine assets. Wallpaper Engine assets and Workshop projects are not redistributed by this repository. Valve may deny anonymous SteamCMD access; Background Engine does not work around that decision.

This project incorporates or adapts work from Open Wallpaper Engine, Workshop Wallpaper Bridge, wallpaperengine-mac-renderer, Aerial, Plash, and the audited Lively release collection. Pinned upstream revisions, bundled-content hashes, license texts, FFmpeg build details, attribution, and distribution obligations are documented in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Contributors are listed in [AUTHORS](AUTHORS).
