# Brief

Task: wallpaperengine-mac-renderer fork, remove fake asset stubs and fail loudly.

Repository: /Users/lyu/01_Project/01_Projects/wallpaperengine-mac-renderer
Branch: macos-scene-only

Required order:
1. Commit all current uncommitted changes as-is with message `feat: macOS port checkpoint (GLFW/Cocoa build, virtual asset stubs)`. Do not push.
2. Remove fork-added VFS stubs that shadow real Wallpaper Engine assets in `WallpaperApplication.cpp`, while keeping upstream virtual files `effects/wpenginelinux/bloomeffect.json`, `models/wpenginelinux.json`, and `materials/wpenginelinux.json`.
3. After asset containers are mounted, verify sentinel real asset files resolve. If missing, log a clear error listing missing files and expected `--assets-dir` usage, then exit nonzero.
4. Build in existing `build/macos-scene`, verify `./output-binary --help`, and verify running without assets exits nonzero with the clear missing-assets error.
5. Commit final fix as Conventional Commit. Do not push.

Constraints: keep GPLv3 headers; do not break Linux code paths; do not bundle, download, or synthesize WE assets; report commits, build result, and exact missing-assets error output.
