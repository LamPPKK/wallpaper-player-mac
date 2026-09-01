#include "ScriptValueConverter.h"

#include "WallpaperEngine/Data/Utils/ScopeGuard.h"

#include <optional>
#include <string>

using WallpaperEngine::Data::Model::DynamicValue;
using WallpaperEngine::Data::Utils::ScopeGuard;

namespace {
void discardPendingException (JSContext* context) {
    JSValue exception = JS_GetException (context);
    JS_FreeValue (context, exception);
}

std::optional<double> numericProperty (JSContext* context, JSValueConst object, const char* name) {
    JSValue property = JS_GetPropertyStr (context, object, name);
    ScopeGuard guard ([=] { JS_FreeValue (context, property); });

    if (JS_IsException (property)) {
	discardPendingException (context);
	return std::nullopt;
    }
    if (!JS_IsNumber (property)) {
	return std::nullopt;
    }

    double value = 0.0;
    if (JS_ToFloat64 (context, &value, property) < 0) {
	discardPendingException (context);
	return std::nullopt;
    }
    return value;
}
}

bool WallpaperEngine::Scripting::applyScriptValueResult (
    JSContext* context, JSValueConst result, DynamicValue& source
) {
    if (JS_IsException (result)) {
	return false;
    }

    const int tag = JS_VALUE_GET_TAG (result);

    if (tag == JS_TAG_UNDEFINED || tag == JS_TAG_UNINITIALIZED || tag == JS_TAG_NULL) {
	source.update (DynamicValue::UpdateSource::Script);
	return true;
    }

    if (tag == JS_TAG_INT) {
	source.update (JS_VALUE_GET_INT (result), DynamicValue::UpdateSource::Script);
	return true;
    }

    if (tag == JS_TAG_BOOL) {
	source.update (static_cast<bool> (JS_VALUE_GET_BOOL (result)), DynamicValue::UpdateSource::Script);
	return true;
    }

    if (JS_TAG_IS_FLOAT64 (tag)) {
	source.update (static_cast<float> (JS_VALUE_GET_FLOAT64 (result)), DynamicValue::UpdateSource::Script);
	return true;
    }

    if (tag == JS_TAG_STRING) {
	const char* string = JS_ToCString (context, result);
	if (string == nullptr) {
	    discardPendingException (context);
	    return false;
	}
	ScopeGuard stringGuard ([=] { JS_FreeCString (context, string); });
	source.update (std::string (string), DynamicValue::UpdateSource::Script);
	return true;
    }

    if (tag != JS_TAG_OBJECT) {
	return false;
    }

    const auto x = numericProperty (context, result, "x");
    const auto y = numericProperty (context, result, "y");
    if (!x.has_value () || !y.has_value ()) {
	return false;
    }

    switch (source.getType ()) {
    case DynamicValue::Vec2:
	source.update (glm::vec2 (*x, *y), DynamicValue::UpdateSource::Script);
	return true;
    case DynamicValue::Vec3: {
	const auto z = numericProperty (context, result, "z");
	if (!z.has_value ()) {
	    return false;
	}
	source.update (glm::vec3 (*x, *y, *z), DynamicValue::UpdateSource::Script);
	return true;
    }
    case DynamicValue::Vec4: {
	const auto z = numericProperty (context, result, "z");
	const auto w = numericProperty (context, result, "w");
	if (!z.has_value () || !w.has_value ()) {
	    return false;
	}
	source.update (glm::vec4 (*x, *y, *z, *w), DynamicValue::UpdateSource::Script);
	return true;
    }
    default:
	return false;
    }
}
