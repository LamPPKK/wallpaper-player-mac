# Supported wallpaper types

Understand Full Live, Full Cached, Limited, and Unsupported playback.

## Video and images

Compatible streams play through AVFoundation. Other valid local containers are
converted atomically with bundled FFmpeg and VideoToolbox. Odd video dimensions
are scaled up by at most one pixel per axis. FFmpeg adjusts sample aspect ratio
so display aspect ratio remains unchanged and no source row or column is cropped.
The conversion recipe is part of the cache identity; older converted caches stay
playable and are marked for a safe rebuild from the copied source.
GIF, APNG, and WebP animation uses ImageIO frame timing with bounded on-demand
decoding.

The Add Wallpaper File picker probes file contents instead of trusting the
extension. It accepts AVFoundation or FFmpeg-readable video containers,
ImageIO-readable still/animated images, and Wallpaper Engine PKGV Scene
packages. A macOS installer `.pkg` is not a Wallpaper Engine Scene package and
is rejected.

## Web

Web wallpapers run in a non-persistent WKWebView. File access stays inside the
project root; top-level navigation, downloads, and native bridges are blocked.
External networking is disabled by default and can be enabled for one
wallpaper after reviewing the warning. Wallpaper property and pause callbacks
are supported. Audio-reactive callbacks receive neutral data and are Limited.

Lively Wallpaper `.zip` exports and folders are normalized from
`LivelyInfo.json` into the same restricted Web runtime. Supported
`LivelyProperties.json` controls include checkbox, slider, color, dropdown,
textbox, and authored folder-dropdown choices. Button controls and Lively's
add/copy-file folder workflow are not available yet. Controls attached to
native Lively Video/Image playback are retained in metadata but are not applied
by those renderers yet; affected wallpapers are reported as **Limited**.
Metadata-only URL and video-stream exports accept only
public HTTPS targets and require an explicit network opt-in. Application-type
Lively packages are detected but remain **Unsupported** and are never launched.

Property values belong to the imported library asset in this alpha. Assigning
the same Web or Lively asset to multiple displays keeps separate playback,
layout, quality, and lifecycle sessions, but a property edit refreshes every
display using that asset.

## Scene

Compatible two-dimensional Scene features play live using the native parser.
Projects outside that subset are labeled **Full Cached** and rendered to a
20-second, 30 FPS H.264 loop by the bundled GPL renderer when the user supplies
the required engine assets. Truncated raw output and non-contiguous PNG frame
sequences are rejected before a cache is published. SceneScript interaction and audio-reactive behavior
is labeled **Limited**. Authored sound is muxed into the cache and the final
audio stream is verified. Each MP4 is published under an immutable generation
URL with a sidecar bound to its exact size and SHA-256; verification runs off
the main thread and is shared across displays. If a packaged track is missing,
muxing fails, metadata is corrupt, or the generation becomes stale, the visual
cache remains playable but the result becomes **Limited**, lists `sound`, and
reports `scene_authored_audio_unavailable`. A compatibility reason and missing
capabilities are always shown.

## Windows Application

Application projects are detected and labeled **Unsupported**. Background
Engine does not launch them through Wine or CrossOver.
