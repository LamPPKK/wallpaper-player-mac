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
    {"type": "application", "name": "wallpaperengine-mac-renderer", "version": "7acc6c9", "licenses": [{"license": {"id": "GPL-3.0-only"}}]},
    {"type": "application", "name": "FFmpeg", "version": "9.0.1", "properties": [{"name": "background-engine:build-id", "value": "ffmpeg-9.0.1-background-engine-1"}], "licenses": [{"license": {"id": "LGPL-2.1-or-later"}}]},
    {"type": "application", "name": "SteamCMD", "publisher": "Valve Corporation", "scope": "optional"}
  ]
}
JSON
