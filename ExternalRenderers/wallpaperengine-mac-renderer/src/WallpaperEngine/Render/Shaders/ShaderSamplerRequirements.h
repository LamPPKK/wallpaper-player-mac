#pragma once

#include <optional>
#include <string>

#include "WallpaperEngine/Data/Model/Types.h"

namespace WallpaperEngine::Render::Shaders {
using WallpaperEngine::Data::Model::ComboMap;

/**
 * Resolves a shader combo using the current unit's compilation precedence.
 * Material/pass overrides take precedence over the base combo map, followed
 * by defaults discovered while preprocessing the shader.
 */
[[nodiscard]] std::optional<int> resolveEffectiveComboValue (
    const ComboMap& combos, const ComboMap& overrideCombos, const ComboMap& discoveredCombos, const std::string& name
);

/**
 * Checks a sampler's `require` metadata against the effective shader combos.
 *
 * With requireAny set, at least one requirement must match. Otherwise every
 * requirement must match. A missing combo never matches a requirement.
 */
[[nodiscard]] bool samplerRequirementsMatch (
    const ComboMap& requirements, const ComboMap& combos, const ComboMap& overrideCombos,
    const ComboMap& discoveredCombos, bool requireAny
);
}
