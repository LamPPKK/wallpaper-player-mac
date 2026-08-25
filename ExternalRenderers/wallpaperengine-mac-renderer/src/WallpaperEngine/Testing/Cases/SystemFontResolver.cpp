#include <catch2/catch_test_macros.hpp>

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <string>

#include <ft2build.h>
#include FT_FREETYPE_H

#include "WallpaperEngine/Render/Objects/SystemFontResolver.h"

using WallpaperEngine::Render::Objects::SystemFontResolver::candidatesForWallpaperReference;
using WallpaperEngine::Render::Objects::SystemFontResolver::familyFromWallpaperReference;

TEST_CASE ("Wallpaper system-font references normalize their family") {
    CHECK (familyFromWallpaperReference ("").empty ());
    CHECK (familyFromWallpaperReference ("fonts/embedded.ttf").empty ());
    CHECK (familyFromWallpaperReference ("systemfont_arial") == "arial");
    CHECK (familyFromWallpaperReference ("systemfont_open_sans") == "open sans");
}

#ifdef __APPLE__
TEST_CASE ("macOS resolves empty and named Wallpaper Engine system fonts") {
    const auto defaultCandidates = candidatesForWallpaperReference ("");
    REQUIRE_FALSE (defaultCandidates.empty ());
    CHECK (std::filesystem::is_regular_file (defaultCandidates.front ()));

    const auto arialCandidates = candidatesForWallpaperReference ("systemfont_arial");
    REQUIRE_FALSE (arialCandidates.empty ());
    CHECK (std::filesystem::is_regular_file (arialCandidates.front ()));

    auto arialPath = arialCandidates.front ().string ();
    std::transform (arialPath.begin (), arialPath.end (), arialPath.begin (), [] (const unsigned char character) {
	return static_cast<char> (std::tolower (character));
    });
    CHECK (arialPath.find ("arial") != std::string::npos);

    FT_Library library = nullptr;
    REQUIRE (FT_Init_FreeType (&library) == 0);
    for (const auto& path : { defaultCandidates.front (), arialCandidates.front () }) {
	FT_Face face = nullptr;
	CHECK (FT_New_Face (library, path.c_str (), 0, &face) == 0);
	if (face != nullptr) {
	    FT_Done_Face (face);
	}
    }
    FT_Done_FreeType (library);
}

TEST_CASE ("macOS falls back when a requested system family is unavailable") {
    const auto candidates = candidatesForWallpaperReference ("systemfont_background_engine_missing_family");
    REQUIRE_FALSE (candidates.empty ());
    CHECK (std::filesystem::is_regular_file (candidates.front ()));

    auto fallbackPath = candidates.front ().string ();
    std::transform (fallbackPath.begin (), fallbackPath.end (), fallbackPath.begin (), [] (const unsigned char character) {
	return static_cast<char> (std::tolower (character));
    });
    CHECK (fallbackPath.find ("lastresort") == std::string::npos);
}
#endif
