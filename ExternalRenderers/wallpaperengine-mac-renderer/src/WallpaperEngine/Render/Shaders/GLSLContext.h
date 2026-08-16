#pragma once

#include <memory>
#include <ostream>
#include <sstream>
#include <string>
#include <vector>

namespace WallpaperEngine::Render::Shaders {
class GLSLContext {
public:
    /**
     * Types of shaders
     */
    enum UnitType { UnitType_Vertex = 0, UnitType_Fragment = 1 };

    GLSLContext ();
    ~GLSLContext ();

    [[nodiscard]] std::pair<std::string, std::string> toGlsl (const std::string& vertex, const std::string& fragment);

    [[nodiscard]] static GLSLContext& get ();

    /**
     * Explicitly tears down the singleton (and calls glslang::FinalizeProcess())
     * while the process is still fully alive.
     *
     * This must be called from the application's own deterministic shutdown path
     * (e.g. WallpaperApplication::cleanup()) rather than relying on the C++ runtime's
     * static-destruction order: glslang keeps its own global init mutex as a
     * separate static object (in ShaderLang.cpp), and the C++ standard does not
     * guarantee any destruction order between static objects defined in different
     * translation units. If GLSLContext::sInstance were destroyed by the runtime's
     * exit-time static destructors after that mutex had already been destroyed,
     * glslang::FinalizeProcess() would try to lock an already-destroyed std::mutex,
     * throwing std::system_error ("Invalid argument") during shutdown, which is
     * uncaught (it happens after main() returns) and aborts the process.
     */
    static void shutdown ();

private:
    static std::unique_ptr<GLSLContext> sInstance;
};
} // namespace WallpaperEngine::Render::Shaders