# GPL Scene renderer

`wallpaperengine-mac-renderer` is pinned at commit `7acc6c92e0175d53e1cb6b2b2dff52f79faf83e0` with its submodules pinned by the upstream tree.

Build a Universal renderer with:

```sh
./Scripts/build-renderer.sh
```

The script builds both native slices, collects their Homebrew dylib
dependencies, and merges every Mach-O file into one portable runtime. The
expected output directory is:

```text
ExternalRenderers/wallpaperengine-mac-renderer/build/runtime/
  background-engine-scene-renderer
  lib/*.dylib
```

Builds use `WPENGINE_SCENE_ONLY=ON` and exclude upstream tests/CEF. The
packaging script verifies both `arm64` and `x86_64` slices and rejects runtime
references to Homebrew or unresolved rpaths. User-owned
`wallpaper_engine/assets` files are never committed or distributed.
