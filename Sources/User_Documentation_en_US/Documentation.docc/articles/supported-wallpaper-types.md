# Supported wallpaper types

Understand live, cached, and unsupported playback.

## Video and images

MP4, MOV, and M4V play through AVFoundation. Still images and GIF files use
native image playback. Other video containers can be converted before import.

## Web

Web wallpapers run in a non-persistent WKWebView. File access stays inside the
project root; top-level navigation, downloads, and native bridges are blocked.
External networking is disabled by default and can be enabled for one
wallpaper after reviewing the warning.

## Scene

Compatible two-dimensional Scene features play live using the native parser.
Projects outside that subset are labeled **Cached** and rendered to a
20-second, 30 FPS H.264 loop by the bundled GPL renderer when the user supplies
the required engine assets. A compatibility reason is always shown.

## Windows Application

Application projects are detected and labeled **Unsupported**. Background
Engine does not launch them through Wine or CrossOver.
