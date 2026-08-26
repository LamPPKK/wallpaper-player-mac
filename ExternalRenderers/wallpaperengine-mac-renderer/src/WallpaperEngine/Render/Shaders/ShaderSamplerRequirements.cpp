#include "ShaderSamplerRequirements.h"

#include <algorithm>
#include <cctype>
#include <iterator>

using namespace WallpaperEngine::Render::Shaders;

namespace {
std::string normalizedComboName (const std::string& name) {
    std::string normalized;
    normalized.reserve (name.size ());
    std::ranges::transform (name, std::back_inserter (normalized), [] (const unsigned char character) {
	return static_cast<char> (std::toupper (character));
    });
    return normalized;
}

std::optional<int> valueForNormalizedCombo (const ComboMap& combos, const std::string& normalizedName) {
    for (const auto& [name, value] : combos) {
	if (normalizedComboName (name) == normalizedName) {
	    return value;
	}
    }

    return std::nullopt;
}
}

std::optional<int> WallpaperEngine::Render::Shaders::resolveEffectiveComboValue (
    const ComboMap& combos, const ComboMap& overrideCombos, const ComboMap& discoveredCombos, const std::string& name
) {
    const auto normalizedName = normalizedComboName (name);

    if (const auto overrideValue = valueForNormalizedCombo (overrideCombos, normalizedName)) {
	return overrideValue;
    }

    if (const auto value = valueForNormalizedCombo (combos, normalizedName)) {
	return value;
    }

    if (const auto discoveredValue = valueForNormalizedCombo (discoveredCombos, normalizedName)) {
	return discoveredValue;
    }

    return std::nullopt;
}

bool WallpaperEngine::Render::Shaders::samplerRequirementsMatch (
    const ComboMap& requirements, const ComboMap& combos, const ComboMap& overrideCombos,
    const ComboMap& discoveredCombos, const bool requireAny
) {
    const auto matches = [&combos, &overrideCombos, &discoveredCombos] (const auto& requirement) {
	const auto effectiveValue
	    = resolveEffectiveComboValue (combos, overrideCombos, discoveredCombos, requirement.first);
	return effectiveValue.has_value () && *effectiveValue == requirement.second;
    };

    if (requireAny) {
	return std::ranges::any_of (requirements, matches);
    }

    return std::ranges::all_of (requirements, matches);
}
