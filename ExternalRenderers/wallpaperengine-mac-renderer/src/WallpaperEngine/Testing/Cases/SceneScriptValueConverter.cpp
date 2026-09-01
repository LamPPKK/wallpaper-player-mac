#include <catch2/catch_test_macros.hpp>

#include "WallpaperEngine/Scripting/ScriptValueConverter.h"

#include <string>

using WallpaperEngine::Data::Model::DynamicValue;
using WallpaperEngine::Scripting::applyScriptValueResult;

namespace {
class QuickJSFixture {
public:
    QuickJSFixture () : runtime (JS_NewRuntime ()), context (runtime == nullptr ? nullptr : JS_NewContext (runtime)) { }

    ~QuickJSFixture () {
	if (context != nullptr) {
	    JS_FreeContext (context);
	}
	if (runtime != nullptr) {
	    JS_FreeRuntime (runtime);
	}
    }

    JSValue evaluate (const std::string& source) const {
	return JS_Eval (context, source.c_str (), source.size (), "<scene-script-value-test>", JS_EVAL_TYPE_GLOBAL);
    }

    JSRuntime* runtime;
    JSContext* context;
};

class OwnedJSValue {
public:
    OwnedJSValue (JSContext* context, JSValue value) : context (context), value (value) { }
    ~OwnedJSValue () { JS_FreeValue (context, value); }

    JSValue get () const { return value; }

private:
    JSContext* context;
    JSValue value;
};
}

TEST_CASE ("SceneScript vec2 results preserve both components") {
    QuickJSFixture js;
    REQUIRE (js.runtime != nullptr);
    REQUIRE (js.context != nullptr);
    DynamicValue value (glm::vec2 (9.0f, 8.0f));
    OwnedJSValue result (js.context, js.evaluate ("({ x: 11.5, y: -2.25 })"));
    REQUIRE_FALSE (JS_IsException (result.get ()));

    REQUIRE (applyScriptValueResult (js.context, result.get (), value));
    CHECK (value.getType () == DynamicValue::Vec2);
    CHECK (value.getVec2 ().x == 11.5f);
    CHECK (value.getVec2 ().y == -2.25f);
}

TEST_CASE ("SceneScript vec3 results preserve the z component") {
    QuickJSFixture js;
    REQUIRE (js.runtime != nullptr);
    REQUIRE (js.context != nullptr);
    DynamicValue value (glm::vec3 (9.0f, 8.0f, 7.0f));
    OwnedJSValue result (js.context, js.evaluate ("({ x: 11, y: 22, z: 33 })"));
    REQUIRE_FALSE (JS_IsException (result.get ()));

    REQUIRE (applyScriptValueResult (js.context, result.get (), value));
    CHECK (value.getType () == DynamicValue::Vec3);
    CHECK (value.getVec3 () == glm::vec3 (11.0f, 22.0f, 33.0f));
}

TEST_CASE ("SceneScript vec4 results preserve the w component") {
    QuickJSFixture js;
    REQUIRE (js.runtime != nullptr);
    REQUIRE (js.context != nullptr);
    DynamicValue value (glm::vec4 (9.0f, 8.0f, 7.0f, 6.0f));
    OwnedJSValue result (js.context, js.evaluate ("({ x: 11, y: 22, z: 33, w: 44 })"));
    REQUIRE_FALSE (JS_IsException (result.get ()));

    REQUIRE (applyScriptValueResult (js.context, result.get (), value));
    CHECK (value.getType () == DynamicValue::Vec4);
    CHECK (value.getVec4 () == glm::vec4 (11.0f, 22.0f, 33.0f, 44.0f));
}

TEST_CASE ("Malformed SceneScript vector results preserve the prior value") {
    QuickJSFixture js;
    REQUIRE (js.runtime != nullptr);
    REQUIRE (js.context != nullptr);
    DynamicValue value (glm::vec3 (9.0f, 8.0f, 7.0f));
    OwnedJSValue result (js.context, js.evaluate ("({ x: 1, y: 'bad', z: 3 })"));
    REQUIRE_FALSE (JS_IsException (result.get ()));

    CHECK_FALSE (applyScriptValueResult (js.context, result.get (), value));
    CHECK (value.getType () == DynamicValue::Vec3);
    CHECK (value.getVec3 () == glm::vec3 (9.0f, 8.0f, 7.0f));

    OwnedJSValue subsequentResult (js.context, js.evaluate ("40 + 2"));
    REQUIRE_FALSE (JS_IsException (subsequentResult.get ()));
    CHECK (JS_VALUE_GET_INT (subsequentResult.get ()) == 42);
}

TEST_CASE ("SceneScript boolean results return after applying the value") {
    QuickJSFixture js;
    REQUIRE (js.runtime != nullptr);
    REQUIRE (js.context != nullptr);
    DynamicValue value (false);
    OwnedJSValue result (js.context, js.evaluate ("true"));
    REQUIRE_FALSE (JS_IsException (result.get ()));

    REQUIRE (applyScriptValueResult (js.context, result.get (), value));
    CHECK (value.getType () == DynamicValue::Boolean);
    CHECK (value.getBool ());
}

TEST_CASE ("SceneScript scalar results preserve their concrete types") {
    QuickJSFixture js;
    REQUIRE (js.runtime != nullptr);
    REQUIRE (js.context != nullptr);

    SECTION ("integer") {
	DynamicValue value (0);
	OwnedJSValue result (js.context, js.evaluate ("42"));
	REQUIRE_FALSE (JS_IsException (result.get ()));

	REQUIRE (applyScriptValueResult (js.context, result.get (), value));
	CHECK (value.getType () == DynamicValue::Int);
	CHECK (value.getInt () == 42);
    }

    SECTION ("float") {
	DynamicValue value (0.0f);
	OwnedJSValue result (js.context, js.evaluate ("12.5"));
	REQUIRE_FALSE (JS_IsException (result.get ()));

	REQUIRE (applyScriptValueResult (js.context, result.get (), value));
	CHECK (value.getType () == DynamicValue::Float);
	CHECK (value.getFloat () == 12.5f);
    }

    SECTION ("string") {
	DynamicValue value (std::string ("before"));
	OwnedJSValue result (js.context, js.evaluate ("'after'"));
	REQUIRE_FALSE (JS_IsException (result.get ()));

	REQUIRE (applyScriptValueResult (js.context, result.get (), value));
	CHECK (value.getType () == DynamicValue::String);
	CHECK (value.getString () == "after");
    }

    SECTION ("null") {
	DynamicValue value (42);
	OwnedJSValue result (js.context, js.evaluate ("null"));
	REQUIRE_FALSE (JS_IsException (result.get ()));

	REQUIRE (applyScriptValueResult (js.context, result.get (), value));
	CHECK (value.getType () == DynamicValue::Null);
    }

    SECTION ("undefined") {
	DynamicValue value (42);
	OwnedJSValue result (js.context, js.evaluate ("undefined"));
	REQUIRE_FALSE (JS_IsException (result.get ()));

	REQUIRE (applyScriptValueResult (js.context, result.get (), value));
	CHECK (value.getType () == DynamicValue::Null);
    }
}

TEST_CASE ("SceneScript vector conversion only reads components required by the source arity") {
    QuickJSFixture js;
    REQUIRE (js.runtime != nullptr);
    REQUIRE (js.context != nullptr);

    SECTION ("vec2 does not access z or w") {
	DynamicValue value (glm::vec2 (9.0f, 8.0f));
	OwnedJSValue result (
	    js.context,
	    js.evaluate ("({ x: 1, y: 2, get z() { throw new Error('z'); }, get w() { throw new Error('w'); } })")
	);
	REQUIRE_FALSE (JS_IsException (result.get ()));

	REQUIRE (applyScriptValueResult (js.context, result.get (), value));
	CHECK (value.getVec2 () == glm::vec2 (1.0f, 2.0f));
    }

    SECTION ("vec3 does not access w") {
	DynamicValue value (glm::vec3 (9.0f, 8.0f, 7.0f));
	OwnedJSValue result (
	    js.context, js.evaluate ("({ x: 1, y: 2, z: 3, get w() { throw new Error('w'); } })")
	);
	REQUIRE_FALSE (JS_IsException (result.get ()));

	REQUIRE (applyScriptValueResult (js.context, result.get (), value));
	CHECK (value.getVec3 () == glm::vec3 (1.0f, 2.0f, 3.0f));
    }
}

TEST_CASE ("Throwing required vector getters preserve the prior value and clear the exception") {
    QuickJSFixture js;
    REQUIRE (js.runtime != nullptr);
    REQUIRE (js.context != nullptr);
    DynamicValue value (glm::vec3 (9.0f, 8.0f, 7.0f));
    OwnedJSValue result (
	js.context, js.evaluate ("({ x: 1, get y() { throw new Error('malformed y'); }, z: 3 })")
    );
    REQUIRE_FALSE (JS_IsException (result.get ()));

    CHECK_FALSE (applyScriptValueResult (js.context, result.get (), value));
    CHECK (value.getType () == DynamicValue::Vec3);
    CHECK (value.getVec3 () == glm::vec3 (9.0f, 8.0f, 7.0f));

    OwnedJSValue subsequentResult (js.context, js.evaluate ("21 * 2"));
    REQUIRE_FALSE (JS_IsException (subsequentResult.get ()));
    CHECK (JS_VALUE_GET_INT (subsequentResult.get ()) == 42);
}
