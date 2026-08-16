#pragma once
#include "WallpaperEngine/Render/CObject.h"
#include "WallpaperEngine/Render/FBOProvider.h"
#include "WallpaperEngine/Render/Objects/Effects/CPass.h"
#include "WallpaperEngine/Render/Wallpapers/CScene.h"

#include "WallpaperEngine/Render/Shaders/Shader.h"

using namespace WallpaperEngine;
using namespace WallpaperEngine::Render;

namespace WallpaperEngine::Render::Objects {
class CRenderable : virtual public CObject, public FBOProvider {
    friend CObject;

public:
    CRenderable (Wallpapers::CScene& scene, const Object& object, const Material& material);

    [[nodiscard]] std::shared_ptr<const TextureProvider> getTexture () const;

    [[nodiscard]] double getAnimationTime () const;

    void setup () override;

    [[nodiscard]] virtual const float& getBrightness () const = 0;
    [[nodiscard]] virtual const float& getUserAlpha () const = 0;
    [[nodiscard]] virtual const float& getAlpha () const = 0;
    [[nodiscard]] virtual const glm::vec3& getColor () const = 0;
    [[nodiscard]] virtual const glm::vec4& getColor4 () const = 0;
    [[nodiscard]] virtual const glm::vec3& getCompositeColor () const = 0;

protected:
    void detectTexture ();

    double m_animationTime = 0.0;

    std::shared_ptr<const TextureProvider> m_texture = nullptr;
    const Material& m_material;

    // True when m_texture was resolved from a scene-wide shared render target (e.g. "_rt_FullFrameBuffer",
    // bound by the "composelayer"/"passthrough"/"fullscreenlayer" bridge materials so an object can read back
    // the current composite). That buffer's resolution is the whole scene's, not this object's - it is only
    // ever an *input sample source*, never a stand-in for this object's own authored footprint. See
    // CImage::getSize().
    bool m_textureIsSharedRenderTarget = false;
};
}
