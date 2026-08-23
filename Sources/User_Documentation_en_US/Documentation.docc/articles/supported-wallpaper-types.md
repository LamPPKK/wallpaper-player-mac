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

## Scene

Compatible two-dimensional Scene features play live using the native parser.
Projects outside that subset are labeled **Full Cached** and rendered to a
20-second, 30 FPS H.264 loop by the bundled GPL renderer when the user supplies
the required engine assets. SceneScript interaction and audio-reactive behavior
is labeled **Limited**. A compatibility reason and missing capabilities are
always shown.

## Windows Application

Application projects are detected and labeled **Unsupported**. Background
Engine does not launch them through Wine or CrossOver.
