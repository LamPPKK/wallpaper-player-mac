#pragma once

#include <filesystem>
#include <string>
#include <string_view>
#include <vector>

namespace WallpaperEngine::Render::Objects::SystemFontResolver {
/**
 * Converts Wallpaper Engine's `systemfont_<family>` reference into a native
 * family name. Empty and non-system references do not name a system family.
 */
std::string familyFromWallpaperReference (std::string_view reference);

/**
 * Returns existing system-font files in preference order.
 *
 * macOS resolves the requested family (when present) and the system UI font
 * through CoreText before trying stable on-disk fallbacks. Other platforms
 * retain the renderer's existing DejaVu/Liberation fallback order.
 */
std::vector<std::filesystem::path> candidatesForWallpaperReference (std::string_view reference);
} // namespace WallpaperEngine::Render::Objects::SystemFontResolver
