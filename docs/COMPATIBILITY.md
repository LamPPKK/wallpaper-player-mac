# Background Engine compatibility

| Type | Mode | Notes |
|---|---|---|
| Video | Full Live or Full Cached | AVFoundation-compatible streams play directly. Other valid local MP4/MOV/WebM/MKV/AVI content is probed and converted atomically by bundled FFmpeg 9.0.1 using VideoToolbox/AAC. An odd frame dimension is scaled up by at most one pixel; FFmpeg adjusts sample aspect ratio to preserve display aspect ratio. The cache identity includes the conversion recipe, and a legacy cache remains playable while it is flagged for a safe source rebuild. |
| Web | Full Live, Limited, or Unsupported | Project-root files only, non-persistent storage, property callbacks, local autoplay, and pause callbacks. Navigation/download/native bridge are blocked. External network is opt-in. Audio-reactive wallpapers receive neutral data and are Limited. A project whose entrypoint references a missing/escaping local script or stylesheet is Unsupported with `web_local_dependency_missing`; required HTTP(S) scripts/stylesheets are `web_network_access_required` until permission is granted. Both paths prevent a blank WKWebView from being presented as Full. |
| Image/GIF/APNG/WebP | Full Live | ImageIO playback preserves per-frame timing, decodes on demand under memory limits, and supports Fit, Fill, or Stretch. |
| Scene | Full Live, Full Cached, or Limited | Native playback is preferred when all required capabilities are supported. The GPL renderer creates a 20-second 30 FPS crossfaded H.264 cache otherwise. SceneScript interaction and audio-reactive behavior are Limited; authored sound is retained when it can be extracted. |
| Windows Application | Unsupported | Recognized but never launched through Wine or CrossOver. |

Scene compatibility claims apply only to the legally owned external corpus used for release testing. Every item receives a versioned compatibility report and a stable diagnostic code; intentionally dark or static frames are warnings, not hard failures. Release acceptance requires the app, XPC service, screen saver, Scene renderer, FFmpeg, and ffprobe to build and smoke-test on Apple Silicon and Intel. Real Workshop content stays outside Git.
