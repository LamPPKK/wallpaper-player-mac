#include "SystemFontResolver.h"

#include <algorithm>
#include <array>
#include <system_error>

#ifdef __APPLE__
#include <CoreText/CoreText.h>
#include <limits.h>
#endif

namespace WallpaperEngine::Render::Objects::SystemFontResolver {
namespace {
constexpr std::string_view kSystemFontPrefix = "systemfont_";

const std::array<std::filesystem::path, 4> kPortableFallbacks = {
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
};

#ifdef __APPLE__
const std::array<std::filesystem::path, 4> kMacOSFallbacks = {
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/System/Library/Fonts/LucidaGrande.ttc",
};

std::filesystem::path filePathForFont (CTFontRef font) {
    if (font == nullptr) {
	return {};
    }

    CFTypeRef attribute = CTFontCopyAttribute (font, kCTFontURLAttribute);
    if (attribute == nullptr || CFGetTypeID (attribute) != CFURLGetTypeID ()) {
	if (attribute != nullptr) {
	    CFRelease (attribute);
	}
	return {};
    }

    std::array<UInt8, PATH_MAX> buffer = {};
    const bool resolved = CFURLGetFileSystemRepresentation (
	static_cast<CFURLRef> (attribute), true, buffer.data (), static_cast<CFIndex> (buffer.size ())
    );
    CFRelease (attribute);

    if (!resolved) {
	return {};
    }
    return std::filesystem::path (reinterpret_cast<const char*> (buffer.data ()));
}

std::filesystem::path resolveNamedFont (const std::string& family) {
    if (family.empty ()) {
	return {};
    }

    CFStringRef familyName = CFStringCreateWithCString (nullptr, family.c_str (), kCFStringEncodingUTF8);
    if (familyName == nullptr) {
	return {};
    }
    CTFontRef font = CTFontCreateWithName (familyName, 12.0, nullptr);
    CFRelease (familyName);

    const auto path = filePathForFont (font);
    if (font != nullptr) {
	CFRelease (font);
    }
    return path;
}

std::filesystem::path resolveSystemUIFont () {
    CTFontRef font = CTFontCreateUIFontForLanguage (kCTFontUIFontSystem, 0.0, nullptr);
    const auto path = filePathForFont (font);
    if (font != nullptr) {
	CFRelease (font);
    }
    return path;
}
#endif

void appendExistingUnique (
    std::vector<std::filesystem::path>& candidates, const std::filesystem::path& candidate
) {
    if (candidate.empty ()) {
	return;
    }

    std::error_code error;
    if (!std::filesystem::is_regular_file (candidate, error) || error) {
	return;
    }
    if (std::find (candidates.begin (), candidates.end (), candidate) == candidates.end ()) {
	candidates.push_back (candidate);
    }
}
} // namespace

std::string familyFromWallpaperReference (const std::string_view reference) {
    if (!reference.starts_with (kSystemFontPrefix)) {
	return {};
    }

    std::string family (reference.substr (kSystemFontPrefix.size ()));
    std::replace (family.begin (), family.end (), '_', ' ');
    return family;
}

std::vector<std::filesystem::path> candidatesForWallpaperReference (const std::string_view reference) {
    std::vector<std::filesystem::path> candidates;

#ifdef __APPLE__
    appendExistingUnique (candidates, resolveNamedFont (familyFromWallpaperReference (reference)));
    appendExistingUnique (candidates, resolveSystemUIFont ());
    for (const auto& fallback : kMacOSFallbacks) {
	appendExistingUnique (candidates, fallback);
    }
#endif

    for (const auto& fallback : kPortableFallbacks) {
	appendExistingUnique (candidates, fallback);
    }
    return candidates;
}
} // namespace WallpaperEngine::Render::Objects::SystemFontResolver
