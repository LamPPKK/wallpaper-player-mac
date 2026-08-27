#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${1:-$ROOT/dist/Background-Engine.sbom.json}"
VERSION="${APP_VERSION:-0.2.0-alpha.1}"
cat > "$OUTPUT" <<JSON
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "version": 1,
  "metadata": {"component": {"type": "application", "name": "Background Engine", "version": "$VERSION"}},
  "components": [
    {"type": "library", "name": "Workshop Wallpaper Bridge core", "version": "c0b8bec", "licenses": [{"license": {"id": "MIT"}}]},
    {"type": "application", "name": "wallpaper-player-mac-steamcmd", "version": "fa0929c", "licenses": [{"license": {"id": "GPL-3.0-only"}}]},
    {"type": "application", "name": "wallpaperengine-mac-renderer", "version": "7acc6c9-be4", "properties": [{"name": "background-engine:upstream-ref", "value": "7acc6c92e0175d53e1cb6b2b2dff52f79faf83e0"}], "licenses": [{"license": {"id": "GPL-3.0-only"}}]},
    {"type": "library", "name": "PlashRuntime", "version": "b9f585368264c79de997d7d82e10d2dc85f3024e", "properties": [{"name": "background-engine:upstream-ref", "value": "Joehuu/Plash@d9ac1bbde078c5b0fd3fb52c7bad3d64ccbc43ae"}], "licenses": [{"license": {"id": "MIT"}}]},
    {"type": "file", "name": "Lively bundled wallpaper collection", "version": "v2.2.1.0", "properties": [{"name": "background-engine:source-ref", "value": "rocksdanister/lively@6860a4093fc50058c4815908658a4391c4449935"}, {"name": "background-engine:installer-sha256", "value": "98f4e96bb8e2c416384eeaf48016eadaea9dce8263b8d212052775ebcf2d7e34"}]},
    {"type": "file", "name": "Lively wallpaper: The Hill", "version": "v2.2.1.0", "properties": [{"name": "background-engine:content-hash", "value": "a85bbf10244b0978dd7ca32c56553b93dbcd19c2a78eb58a5fa19b2226dfb17a"}], "licenses": [{"license": {"id": "MIT"}}, {"license": {"id": "OFL-1.1"}}, {"license": {"id": "Apache-2.0"}}]},
    {"type": "file", "name": "Lively wallpaper: Periodic Table", "version": "v2.2.1.0", "properties": [{"name": "background-engine:content-hash", "value": "10519543efbe05f727db1e9c09046b887add60868e6ad24abf60791633be5b4f"}], "licenses": [{"license": {"id": "MIT"}}]},
    {"type": "file", "name": "Lively wallpaper: Parallax.js", "version": "v2.2.1.0", "properties": [{"name": "background-engine:content-hash", "value": "43496ded57b3b91524ebbe8ccd371fd6c82bbff84841e75f16cd46c74fc60bb9"}], "licenses": [{"license": {"id": "MIT"}}]},
    {"type": "file", "name": "Lively wallpaper: Music TV (LQ)", "version": "v2.2.1.0", "properties": [{"name": "background-engine:content-hash", "value": "4e70957a2fdcc34de02dfd5bbbbc99bdb9e3c53524376ab6981a7c991bd9413b"}], "licenses": [{"license": {"id": "MIT"}}, {"license": {"id": "ISC"}}, {"license": {"id": "CC-BY-4.0"}}, {"license": {"id": "CC-BY-3.0"}}, {"license": {"id": "CC0-1.0"}}]},
    {"type": "file", "name": "Lively wallpaper: Depth Observatory", "version": "0a0e64ef5b1f56544899adfb909a335bfe246286", "properties": [{"name": "background-engine:source-ref", "value": "rocksdanister/depthmap-wallpaper@0a0e64ef5b1f56544899adfb909a335bfe246286"}, {"name": "background-engine:archive-sha256", "value": "b453c4cff443598144f186b3fb7fd2209da4570beed5ac3547e992502bce7e91"}, {"name": "background-engine:content-hash", "value": "ede0136a2bd235d20ce8669a545eae3e437808dfe6aa80b8b8c25fa40d68c60b"}], "licenses": [{"license": {"id": "MIT"}}, {"license": {"id": "Apache-2.0"}}, {"license": {"id": "CC0-1.0"}}]},
    {"type": "library", "name": "Three.js", "version": "r150", "purl": "pkg:github/mrdoob/three.js@r150", "hashes": [{"alg": "SHA-256", "content": "4d2e6fde359dcfd3de70163cb7f73e6eca16a658716153703c9a26b19f5258ff"}], "licenses": [{"license": {"id": "MIT"}}]},
    {"type": "library", "name": "dat.GUI depthmap snapshot", "version": "0a0e64ef5b1f56544899adfb909a335bfe246286", "properties": [{"name": "background-engine:source-ref", "value": "rocksdanister/depthmap-wallpaper@0a0e64ef5b1f56544899adfb909a335bfe246286"}], "hashes": [{"alg": "SHA-256", "content": "6e21301e269b7fff15f217c1454b0f614c937d53081e998e8559c26ab0be3944"}], "licenses": [{"license": {"id": "Apache-2.0"}}]},
    {"type": "file", "name": "Lively wallpaper: Chromatic Fluids", "version": "v6", "properties": [{"name": "background-engine:source-ref", "value": "rocksdanister/WebGL-Fluid-Simulation@bd028c0b4a931c4173e77e52cb953d964e857557"}, {"name": "background-engine:archive-sha256", "value": "4a10cffb51ec5c86b1464c1d91b25773da4b27288dd5874a422ab49c6323556f"}, {"name": "background-engine:content-hash", "value": "eba7f82e08d3e72e3f6cde8d4a80738a6d4cef67573e1b53a217c4dc09f7a2c8"}], "licenses": [{"license": {"id": "MIT"}}, {"license": {"id": "CC0-1.0"}}]},
    {"type": "application", "name": "FFmpeg", "version": "9.0.1", "properties": [{"name": "background-engine:build-id", "value": "ffmpeg-9.0.1-background-engine-1"}], "licenses": [{"license": {"id": "LGPL-2.1-or-later"}}]},
    {"type": "application", "name": "SteamCMD", "publisher": "Valve Corporation", "scope": "optional"}
  ]
}
JSON
