#pragma once

#include <filesystem>

#include "WallpaperEngine/Data/JSON.h"

namespace WallpaperEngine::Application::SceneProjectMetadata {

/**
 * Loads the on-disk project metadata used with an explicitly selected PKGV
 * scene package. A standalone package has no project.json, so a minimal Scene
 * project is synthesized in memory. Existing metadata is preserved except for
 * the main file, which must resolve inside the mounted package rather than to
 * the PKGV container itself.
 */
[[nodiscard]] WallpaperEngine::Data::JSON::JSON
loadForExplicitPackage (const std::filesystem::path& backgroundPath);

} // namespace WallpaperEngine::Application::SceneProjectMetadata
