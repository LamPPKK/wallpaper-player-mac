#pragma once

#include "WallpaperEngine/Data/Model/DynamicValue.h"

extern "C" {
#include <quickjs.h>
}

namespace WallpaperEngine::Scripting {
/**
 * Applies a SceneScript update result to an existing DynamicValue.
 *
 * Object results preserve the source vector arity. Malformed results are
 * rejected without mutating the source so one bad script cannot abort Scene
 * construction or poison the QuickJS context for subsequent frame updates.
 */
[[nodiscard]] bool applyScriptValueResult (
    JSContext* context, JSValueConst result, Data::Model::DynamicValue& source
);
}
