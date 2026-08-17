# Supported wallpaper types

Understand Full Live, Full Cached, Limited, and Unsupported playback.

## Video and images

Compatible streams play through AVFoundation. Other valid local containers are
converted atomically with bundled FFmpeg and VideoToolbox. GIF, APNG, and WebP
animation uses ImageIO frame timing with bounded on-demand decoding.

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
