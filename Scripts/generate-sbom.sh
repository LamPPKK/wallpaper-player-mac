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
    {"type": "file", "name": "Lively wallpaper: The Hill", "version": "v2.2.1.0", "licenses": [{"license": {"id": "MIT"}}, {"license": {"id": "OFL-1.1"}}, {"license": {"id": "Apache-2.0"}}]},
    {"type": "file", "name": "Lively wallpaper: Periodic Table", "version": "v2.2.1.0", "licenses": [{"license": {"id": "MIT"}}]},
    {"type": "file", "name": "Lively wallpaper: Parallax.js", "version": "v2.2.1.0", "licenses": [{"license": {"id": "MIT"}}]},
    {"type": "file", "name": "Lively wallpaper: Music TV (LQ)", "version": "v2.2.1.0", "licenses": [{"license": {"id": "MIT"}}, {"license": {"id": "ISC"}}, {"license": {"id": "CC-BY-4.0"}}, {"license": {"id": "CC-BY-3.0"}}, {"license": {"id": "CC0-1.0"}}]},
    {"type": "application", "name": "FFmpeg", "version": "9.0.1", "properties": [{"name": "background-engine:build-id", "value": "ffmpeg-9.0.1-background-engine-1"}], "licenses": [{"license": {"id": "LGPL-2.1-or-later"}}]},
    {"type": "application", "name": "SteamCMD", "publisher": "Valve Corporation", "scope": "optional"}
  ]
}
JSON
