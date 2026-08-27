# Supported wallpaper types

Understand Full Live, Full Cached, Limited, and Unsupported playback.

## Video and images

Compatible streams play through AVFoundation. Once a source is safely copied
into the private library, a cancellable, time-bounded AVFoundation probe checks
both `isPlayable` and the presence of a video track. System-supported HEVC,
ProRes, HDR, and alpha sources therefore retain their original Direct playback
instead of losing fidelity through an unnecessary conversion. A rejected,
failed, or timed-out probe continues through the bundled FFmpeg fallback.
Other valid local containers are converted atomically with bundled FFmpeg and
VideoToolbox. Odd video dimensions are scaled up by at most one pixel per axis.
FFmpeg adjusts sample aspect ratio
so display aspect ratio remains unchanged and no source row or column is cropped.
The conversion recipe is part of the cache identity; older converted caches stay
playable and are marked for a safe rebuild from the copied source.
When only an authored audio stream has unsafe metadata or cannot survive
conversion, the visual stream is retried without audio and remains playable as
**Limited** with `video_audio_unavailable`. Stream-count and decoded-dimension
limits are still hard failures.
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
textbox, momentary button actions, and authored folder-dropdown choices. A
button click sends `livelyPropertyListener(name, true)` once to every active
display running the exact asset revision; it is not persisted and does not
restart the Web wallpaper. A folder dropdown can also copy and select one file
at a time through Library's **More** menu. The authored extension filter is
enforced, the original file is never exposed to wallpaper JavaScript, and the
native property editor can switch back to an authored choice. Multi-file add
and delete controls are not available yet. Controls attached to
native Lively Video/Image playback are retained in metadata but are not applied
by those renderers yet; affected wallpapers are reported as **Limited**.
Metadata-only URL and video-stream exports accept only
public HTTPS targets and require an explicit network opt-in. Application-type
Lively packages are detected but remain **Unsupported** and are never launched.
An enabled remote URL is **Limited** with `web_remote_runtime_unverified` because
the bounded preflight cannot prove a remote page's visual output or callback
parity; the page still runs live in the restricted runtime.

Library's **Lively Wallpapers** menu can explicitly install six embedded,
license-reviewed Web wallpapers. Depth Observatory uses project-created CC0
image/depth assets with the official MIT depth-map runtime. Chromatic Fluids
uses the official MIT `v6` simulation source without its Pexels release media
and enables automatic splats for click-through desktops. Their unavailable
pointer/audio-reactive paths remain **Limited**. Rain, Snow, and Clouds are not
bundled; the app can download exact pinned official release archives after a
license confirmation, then verifies byte count and SHA-256 before safe import.

Property values belong to the imported library asset in this alpha. Assigning
the same Web or Lively asset to multiple displays keeps separate playback,
layout, quality, and lifecycle sessions, but a property edit refreshes every
display using that asset. A momentary button instead dispatches directly to all
matching live sessions without reopening any display window.

## Scene

Compatible two-dimensional Scene features play live using the native parser.
Projects outside that subset are labeled **Full Cached** and rendered to a
20-second, 30 FPS H.264 loop by the bundled GPL renderer when the user supplies
the required engine assets. Truncated raw output and non-contiguous PNG frame
sequences are rejected before a cache is published. SceneScript interaction and audio-reactive behavior
is labeled **Limited**. Authored sound is muxed into the cache and the final
audio stream is verified. Each MP4 is published under an immutable generation
URL with a sidecar bound to its exact size and SHA-256; verification runs off
the main thread and is shared across displays. A corrupt newest generation is
skipped in favor of an older verified generation; if none remains, one
deduplicated rebuild is scheduled even when several displays report failure.
If a packaged track is missing,
muxing fails, metadata is corrupt, or the generation becomes stale, the visual
cache remains playable but the result becomes **Limited**, lists `sound`, and
reports `scene_authored_audio_unavailable`. A compatibility reason and missing
capabilities are always shown.

## Windows Application

Application projects are detected and labeled **Unsupported**. Background
Engine does not launch them through Wine or CrossOver.
