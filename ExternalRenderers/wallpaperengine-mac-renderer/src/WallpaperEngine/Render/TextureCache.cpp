#include "TextureCache.h"

#include "AlbumTexture.h"
#include "WallpaperEngine/FileSystem/Container.h"

#include "CTexture.h"
#include "WallpaperEngine/Assets/AssetLoadException.h"
#include "WallpaperEngine/Render/Helpers/ContextAware.h"

#include "WallpaperEngine/Data/Model/Project.h"
#include "WallpaperEngine/Data/Parsers/TextureParser.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <cstdlib>
#include <filesystem>
#include <fstream>

using namespace WallpaperEngine::Render;
using namespace WallpaperEngine::FileSystem;
using namespace WallpaperEngine::Data::Parsers;
using namespace WallpaperEngine::Data::Assets;

namespace {
TextureUniquePtr makeFallbackTexture () {
    auto texture = std::make_unique<Texture> ();
    texture->containerVersion = ContainerVersion_TEXB0001;
    texture->flags = TextureFlags_ClampUVs;
    texture->width = 1;
    texture->height = 1;
    texture->textureWidth = 1;
    texture->textureHeight = 1;
    texture->format = TextureFormat_ARGB8888;
    texture->imageCount = 1;

    auto mipmap = std::make_shared<Mipmap> ();
    mipmap->width = 1;
    mipmap->height = 1;
    mipmap->compression = 0;
    mipmap->uncompressedSize = 4;
    mipmap->compressedSize = 4;
    mipmap->uncompressedData = std::make_unique<char[]> (4);
    const unsigned char white[] = { 255, 255, 255, 255 };
    std::memcpy (mipmap->uncompressedData.get (), white, 4);
    texture->images.emplace (0, MipmapList { mipmap });
    return texture;
}
}

TextureCache::TextureCache (RenderContext& context) : Helpers::ContextAware (context) {
    // these textures are special cases, so make sure they're created only upon request
    this->m_currentThumbnail = std::make_shared<AlbumTexture> (this->getContext ());

#if !NDEBUG
    glObjectLabel (GL_TEXTURE, this->m_currentThumbnail->getTextureID (0), -1, "$mediaThumbnail");
#endif

    this->m_previousThumbnail = std::make_shared<AlbumTexture> (this->getContext ());

#if !NDEBUG
    glObjectLabel (GL_TEXTURE, this->m_previousThumbnail->getTextureID (0), -1, "$mediaPreviousThumbnail");
#endif

    // load the latest texture (if available)
    this->m_currentThumbnail->load ();

    // add these to the cache and return the right one
    this->store ("$mediaThumbnail", this->m_currentThumbnail);
    this->store ("$mediaPreviousThumbnail", this->m_previousThumbnail);

    this->m_mediaCallback = this->getContext ().getMediaSource ().addAlbumArtListener (
	[this] (const Media::MediaSource::MediaInfo& data) {
	    if (this->m_currentThumbnail->isReady ()) {
		// copy over pixel data and setup the new texture with the new data
		this->m_previousThumbnail->copyContents (*this->m_currentThumbnail);
	    }

	    // load the next image
	    this->m_currentThumbnail->load ();
	}
    );
}

TextureCache::~TextureCache () { this->m_mediaCallback (); }

std::shared_ptr<const TextureProvider> TextureCache::resolve (const std::string& filename) {
    if (const auto found = this->m_textureCache.find (filename); found != this->m_textureCache.end ()) {
	return found->second;
    }

    // search for the texture in all the different containers just in case
    for (const auto& project : this->getContext ().getApp ().getBackgrounds () | std::views::values) {
	try {
	    const auto contents = project->assetLocator->texture (filename);
	    auto stream = BinaryReader (contents);

	    // Create metadata loader lambda that captures the assetLocator
	    // so we need to construct the full path here
	    auto metadataLoader = [&project] (const std::string& metaFilename) -> std::string {
		std::filesystem::path fullPath = std::filesystem::path ("materials") / metaFilename;
		return project->assetLocator->readString (fullPath);
	    };

	    auto parsedTexture = TextureParser::parse (stream, filename, metadataLoader);
	    auto texture = std::make_shared<CTexture> (this->getContext (), std::move (parsedTexture));
	    if (std::getenv ("WPENGINE_TRACE_TEXTURES") != nullptr) {
		sLog.out (
		    "Resolved texture ", filename, " size=", texture->getRealWidth (), "x", texture->getRealHeight (),
		    " backing=", texture->getTextureWidth (0), "x", texture->getTextureHeight (0)
		);
	    }

#if !NDEBUG
	    glObjectLabel (GL_TEXTURE, texture->getTextureID (0), -1, filename.c_str ());
#endif

	    this->store (filename, texture);

	    return texture;
	} catch (AssetLoadException&) {
	    // ignored, this happens if we're looking at the wrong background
	}
    }

    auto texture = std::make_shared<CTexture> (this->getContext (), makeFallbackTexture ());
    if (std::getenv ("WPENGINE_TRACE_TEXTURES") != nullptr) {
	sLog.out ("Using fallback texture ", filename);
    }
    this->store (filename, texture);
    return texture;
}

void TextureCache::store (const std::string& name, std::shared_ptr<const TextureProvider> texture) {
    this->m_textureCache.insert_or_assign (name, texture);
}
