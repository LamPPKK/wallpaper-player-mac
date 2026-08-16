# wallpaperengine-mac-renderer

macOS port of [linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine), used as the offscreen scene renderer for [Workshop Wallpaper Bridge](https://github.com/3x-haust/workshop-wallpaper-bridge).

It renders a Wallpaper Engine scene (`scene.pkg`) to frames — no window, no desktop integration. The app encodes those frames into a looping video wallpaper.

All engine credit goes to [@Almamu](https://github.com/Almamu) and upstream contributors. → [upstream README](https://github.com/Almamu/linux-wallpaperengine#readme)

## Changes from upstream

| Area | What |
| --- | --- |
| Build | macOS / Apple Silicon (OpenGL 4.1 core, Homebrew deps) |
| GL fixes | Shader macro conflicts, float FBO formats, `composelayer` sizing, blit UV clamp — issues Apple's strict GL rejects but Mesa tolerates |
| HDR | `hdr: true` scenes composite in float buffers, tonemapped once at the final blit |
| Recording | `--record-dir` (PNG), `--record-raw` (RGBA stream for piping into an encoder, ~4x faster) |
| Debugging | `--dump-passes`, `--gl-debug` |

Requires the real Wallpaper Engine `assets` folder (`--assets-dir`, copy from your own Windows install). Missing assets abort with the file list instead of rendering black.

## Build

```bash
brew install cmake lz4 sdl2 ffmpeg glfw glew glm mpv freetype
cmake -B build/macos-scene -DCMAKE_BUILD_TYPE=Release
cmake --build build/macos-scene
```

## Record a scene

```bash
./output/wwb-scene-renderer \
  --window 0x0x1920x1080 --silent --no-audio-processing --disable-mouse \
  --record-raw /tmp/frames.rgba --record-fps 30 --record-seconds 20 \
  --assets-dir "/path/to/wallpaper_engine/assets" \
  "/path/to/workshop/scene-folder"

ffmpeg -f rawvideo -pix_fmt rgba -s 1920x1080 -r 30 -i /tmp/frames.rgba \
  -c:v libx264 -pix_fmt yuv420p -crf 18 scene.mp4
```

Recording flags: `--record-fps`, `--record-seconds`, `--record-exclude-live` (skip clocks etc.), exact `--window WxH` output.

## License

GPL-3.0 (same as upstream). Complete corresponding source for the renderer binary bundled with Workshop Wallpaper Bridge.
