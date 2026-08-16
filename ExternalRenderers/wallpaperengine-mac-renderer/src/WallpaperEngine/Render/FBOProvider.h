#pragma once

#include <glm/vec2.hpp>

#include "CFBO.h"
#include "WallpaperEngine/Data/Model/Effect.h"

namespace WallpaperEngine::Render {
using namespace WallpaperEngine::Data::Model;

class FBOProvider {
public:
    /**
     * @param parent The parent FBO provider to inherit lookups (and HDR-ness) from, or nullptr for a root provider.
     * @param hdr Whether this (root) provider composites in HDR. Ignored when a parent is given, since HDR-ness
     *            is a scene-wide property inherited from the root wallpaper provider.
     */
    explicit FBOProvider (const FBOProvider* parent, bool hdr = false);

    std::shared_ptr<CFBO> create (const FBO& base, uint32_t flags, glm::vec2 size);
    std::shared_ptr<CFBO> create (
	const std::string& name, TextureFormat format, uint32_t flags, float scale, glm::vec2 realSize,
	glm::vec2 textureSize
    );
    std::shared_ptr<CFBO> alias (const std::string& newName, const std::string& original);
    [[nodiscard]] std::shared_ptr<CFBO> find (const std::string& name) const;

    /**
     * @return Whether this provider's scene composites in HDR (float) precision.
     */
    [[nodiscard]] bool isHdr () const { return this->m_hdr; }

private:
    const FBOProvider* m_parent;
    bool m_hdr;
    std::map<std::string, std::shared_ptr<CFBO>> m_fbos = {};
};
}
