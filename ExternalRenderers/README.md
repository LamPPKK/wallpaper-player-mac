# GPL Scene renderer

`wallpaperengine-mac-renderer` is pinned at commit `7acc6c92e0175d53e1cb6b2b2dff52f79faf83e0` with its submodules pinned by the upstream tree.

Build a Universal renderer with:

```sh
./Scripts/build-renderer.sh
```

The script builds both native slices for the macOS 14 deployment target,
collects their Homebrew dylib dependencies, and merges every Mach-O file into
one portable runtime. CI and release builds pin Homebrew 6.0.19 itself to commit
`0942cac2eda7648d4857f4e5da60f1de303b6818`, then install the complete
dependency closure from pinned `homebrew/core` commit
`229d435d9fc7d166b417e94ce66db01d6b34cf97`; the per-architecture lock files
must compare byte-for-byte before packaging. CI and release artifacts contain:

```text
ExternalRenderers/wallpaperengine-mac-renderer/build/runtime/
  background-engine-scene-renderer
  dependencies.lock.tsv
  macho-slice-digests.tsv
  renderer-build-manifest.tsv
  lib/*.dylib
```

The local convenience build has the same runtime layout but does not create a
dependency lock unless the pinned dependency-install step is run first. That
step replaces Homebrew kegs, so it runs automatically only on GitHub-hosted
runners; a local developer must use a disposable Homebrew environment and set
`BACKGROUND_ENGINE_ALLOW_HOMEBREW_MUTATION=1` explicitly. Every locally
provided dylib must still target macOS 14 or earlier. Each thin runtime records
the exact source revision, deterministic canonical-source fingerprint,
architecture, deployment target, dependency-lock digest, and the digest of a
canonical per-architecture Mach-O slice inventory in
`renderer-build-manifest.tsv`. `macho-slice-digests.tsv` binds the executable
and every regular bundled dylib to the exact bytes shipped for `arm64` and
`x86_64`; safe dylib aliases are deliberately excluded. The merge requires the
two manifests to agree on source and dependency provenance, then regenerates
the inventory after the final Universal link and signature. CMake
also embeds that exact provenance record in each Mach-O slice; the renderer
prints it with `--background-engine-build-info`. Bundling extracts the record
without executing cross-architecture binaries and refuses to generate a
manifest when the binary came from an older source tree.

Builds use `WPENGINE_SCENE_ONLY=ON` and exclude upstream tests/CEF. The
packaging script verifies both `arm64` and `x86_64` slices and rejects runtime
references to Homebrew, unresolved rpaths, unsafe aliases, non-canonical dylib
install IDs, a deployment target above macOS 14, non-Mach-O dependency files,
dependency-lock drift, or a renderer manifest that no longer matches the
canonical source under `ExternalRenderers/`. The application repeats the
manifest/version, dependency-lock, runtime file-set, and per-slice digest
checks before it considers the bundled renderer available, so an older binary
cannot be mislabeled as the current renderer after a source change and a dylib
cannot be swapped after packaging. User-owned
`wallpaper_engine/assets` files are never committed or distributed.
