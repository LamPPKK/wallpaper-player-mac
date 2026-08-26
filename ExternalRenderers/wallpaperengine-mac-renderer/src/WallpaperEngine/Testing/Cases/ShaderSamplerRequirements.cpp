#include <catch2/catch_test_macros.hpp>

#include "WallpaperEngine/Render/Shaders/ShaderSamplerRequirements.h"

using WallpaperEngine::Data::Model::ComboMap;
using WallpaperEngine::Render::Shaders::resolveEffectiveComboValue;
using WallpaperEngine::Render::Shaders::samplerRequirementsMatch;

TEST_CASE ("Shader combo overrides take precedence when resolving sampler requirements") {
    const ComboMap combos = { { "QUALITY", 1 }, { "BASE_ONLY", 3 } };
    const ComboMap overrides = { { "quality", 2 }, { "OVERRIDE_ONLY", 4 } };
    const ComboMap discovered = { { "QUALITY", 5 }, { "BASE_ONLY", 6 }, { "DEFAULT_ONLY", 7 } };

    CHECK (resolveEffectiveComboValue (combos, overrides, discovered, "QUALITY") == 2);
    CHECK (resolveEffectiveComboValue (combos, overrides, discovered, "QuAlItY") == 2);
    CHECK (resolveEffectiveComboValue (combos, overrides, discovered, "BASE_ONLY") == 3);
    CHECK (resolveEffectiveComboValue (combos, overrides, discovered, "OVERRIDE_ONLY") == 4);
    CHECK (resolveEffectiveComboValue (combos, overrides, discovered, "DEFAULT_ONLY") == 7);
    CHECK_FALSE (resolveEffectiveComboValue (combos, overrides, discovered, "MISSING").has_value ());
}

TEST_CASE ("Sampler require-all metadata only matches when every effective combo matches") {
    const ComboMap combos = { { "QUALITY", 1 }, { "BLEND", 2 } };
    const ComboMap overrides = { { "quality", 3 }, { "OVERRIDE_ONLY", 4 } };
    const ComboMap discovered = { { "DEFAULT_ONLY", 5 } };

    CHECK (samplerRequirementsMatch (
	{ { "QUALITY", 3 }, { "BLEND", 2 }, { "OVERRIDE_ONLY", 4 }, { "DEFAULT_ONLY", 5 } }, combos,
	overrides, discovered, false
    ));
    CHECK_FALSE (samplerRequirementsMatch ({ { "QUALITY", 1 } }, combos, overrides, discovered, false));
    CHECK_FALSE (samplerRequirementsMatch ({ { "MISSING", 0 } }, combos, overrides, discovered, false));
    CHECK (samplerRequirementsMatch ({}, combos, overrides, discovered, false));
}

TEST_CASE ("Sampler require-any metadata matches at least one effective combo") {
    const ComboMap combos = { { "QUALITY", 1 }, { "BLEND", 2 } };
    const ComboMap overrides = { { "quality", 3 }, { "OVERRIDE_ONLY", 4 } };
    const ComboMap discovered = { { "DEFAULT_ONLY", 5 } };

    CHECK (samplerRequirementsMatch (
	{ { "MISSING", 0 }, { "OVERRIDE_ONLY", 4 } }, combos, overrides, discovered, true
    ));
    CHECK (samplerRequirementsMatch ({ { "DEFAULT_ONLY", 5 } }, combos, overrides, discovered, true));
    CHECK_FALSE (samplerRequirementsMatch (
	{ { "QUALITY", 1 }, { "BLEND", 9 }, { "MISSING", 0 } }, combos, overrides, discovered, true
    ));
    CHECK_FALSE (samplerRequirementsMatch ({}, combos, overrides, discovered, true));
}
