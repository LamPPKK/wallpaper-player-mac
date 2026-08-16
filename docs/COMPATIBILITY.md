# Background Engine compatibility

| Type | Mode | Notes |
|---|---|---|
| Video | Live | MP4/MOV/M4V through AVFoundation; WebM/MKV/AVI require conversion. |
| Web | Live | Project-root files only, non-persistent storage, navigation/download/native bridge blocked. External network is opt-in per wallpaper. |
| Image/GIF | Live | Native image playback with Fit, Fill, or Stretch. |
| Scene | Live or Cached | Native 2D subset when compatible; GPL renderer produces a 20-second 30 FPS H.264 crossfaded cache otherwise. Advanced shaders, particles, SceneScript, audio, and video textures are best-effort. |
| Windows Application | Unsupported | Recognized but never launched through Wine or CrossOver. |

Release acceptance requires the app, XPC service, screen saver, and Scene renderer to build and smoke-test on both Apple Silicon and Intel. Real Workshop test content must be legally owned and is intentionally kept outside Git.
