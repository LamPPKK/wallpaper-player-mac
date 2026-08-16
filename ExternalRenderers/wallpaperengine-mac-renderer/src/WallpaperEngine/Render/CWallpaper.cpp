#include "CWallpaper.h"
#include "WallpaperEngine/Logging/Log.h"
#include <algorithm>
#include "WallpaperEngine/Render/Wallpapers/CScene.h"
#include "WallpaperEngine/Render/Wallpapers/CVideo.h"
#ifndef WPENGINE_SCENE_ONLY
#include "WallpaperEngine/Render/Wallpapers/CWeb.h"
#endif

#include "WallpaperEngine/Data/Model/Project.h"
#include "WallpaperEngine/Data/Model/Wallpaper.h"

using namespace WallpaperEngine::Render;

namespace {
// Scenes authored with "hdr":true expect their bloom/shine thresholds to be evaluated against un-clamped
// composite values; only scenes carry that flag, so other wallpaper kinds (video/web) are always LDR.
bool isHdrWallpaper (const Wallpaper& wallpaperData) {
    return wallpaperData.is<Scene> () && wallpaperData.as<Scene> ()->hdr;
}
}

CWallpaper::CWallpaper (
    const Wallpaper& wallpaperData, RenderContext& context, AudioContext& audioContext,
    const WallpaperState::TextureUVsScaling& scalingMode, const uint32_t& clampMode
) :
    ContextAware (context), FBOProvider (nullptr, isHdrWallpaper (wallpaperData)), m_wallpaperData (wallpaperData),
    m_audioContext (audioContext), m_state (scalingMode, clampMode) {
    // generate the VAO to stop opengl from complaining
    glGenVertexArrays (1, &this->m_vaoBuffer);
    glBindVertexArray (this->m_vaoBuffer);

    this->setupShaders ();

    constexpr GLfloat texCoords[] = { 0.0f, 0.0f, 1.0f, 0.0f, 0.0f, 1.0f, 0.0f, 1.0f, 1.0f, 0.0f, 1.0f, 1.0f };

    // inverted positions so the final texture is rendered properly
    constexpr GLfloat position[] = { -1.0f, 1.0f,  0.0f, 1.0,  1.0f, 0.0f, -1.0f, -1.0f, 0.0f,
				     -1.0f, -1.0f, 0.0f, 1.0f, 1.0f, 0.0f, 1.0f,  -1.0f, 0.0f };

    glGenBuffers (1, &this->m_texCoordBuffer);
    glBindBuffer (GL_ARRAY_BUFFER, this->m_texCoordBuffer);
    glBufferData (GL_ARRAY_BUFFER, sizeof (texCoords), texCoords, GL_STATIC_DRAW);

    glGenBuffers (1, &this->m_positionBuffer);
    glBindBuffer (GL_ARRAY_BUFFER, this->m_positionBuffer);
    glBufferData (GL_ARRAY_BUFFER, sizeof (position), position, GL_STATIC_DRAW);
}

CWallpaper::~CWallpaper () {
    // destroy shader programs
    GLuint attachedShaders[2];
    GLsizei attachedCount = 0;

    // destroy shaders (we only attach 2 to each program)
    glGetAttachedShaders (this->m_shader, 2, &attachedCount, attachedShaders);

    for (auto i = 0; i < attachedCount; i++) {
	glDeleteShader (attachedShaders[i]);
    }

    glDeleteProgram (this->m_shader);

    // destroy used buffers
    glDeleteBuffers (1, &this->m_texCoordBuffer);
    glDeleteBuffers (1, &this->m_positionBuffer);
    glDeleteVertexArrays (1, &this->m_vaoBuffer);
}

const AssetLocator& CWallpaper::getAssetLocator () const { return *this->m_wallpaperData.project.assetLocator; }

const Wallpaper& CWallpaper::getWallpaperData () const { return this->m_wallpaperData; }

GLuint CWallpaper::getWallpaperFramebuffer () const { return this->m_sceneFBO->getFramebuffer (); }

GLuint CWallpaper::getWallpaperTexture () const { return this->m_sceneFBO->getTextureID (0); }

void CWallpaper::setupShaders () {
    // reserve shaders in OpenGL
    const GLuint vertexShaderID = glCreateShader (GL_VERTEX_SHADER);

    // give shader's source code to OpenGL to be compiled
    const char* sourcePointer = "#version 330\n"
				"precision highp float;\n"
				"in vec3 a_Position;\n"
				"in vec2 a_TexCoord;\n"
				"out vec2 v_TexCoord;\n"
				"void main () {\n"
				"gl_Position = vec4 (a_Position, 1.0);\n"
				"v_TexCoord = a_TexCoord;\n"
				"}";

    glShaderSource (vertexShaderID, 1, &sourcePointer, nullptr);
    glCompileShader (vertexShaderID);

    GLint result = GL_FALSE;
    int infoLogLength = 0;

    // ensure the vertex shader was correctly compiled
    glGetShaderiv (vertexShaderID, GL_COMPILE_STATUS, &result);
    glGetShaderiv (vertexShaderID, GL_INFO_LOG_LENGTH, &infoLogLength);

    if (infoLogLength > 0) {
	const auto logBuffer = new char[infoLogLength + 1];
	// ensure logBuffer ends with a \0
	memset (logBuffer, 0, infoLogLength + 1);
	// get information about the error
	glGetShaderInfoLog (vertexShaderID, infoLogLength, nullptr, logBuffer);
	// throw an exception about the issue
	const std::string message = logBuffer;
	// free the buffer
	delete[] logBuffer;
	// throw an exception
	sLog.exception (message);
    }

    // reserve shaders in OpenGL
    const GLuint fragmentShaderID = glCreateShader (GL_FRAGMENT_SHADER);

    // give shader's source code to OpenGL to be compiled
    //
    // This engine composites entirely in gamma/display space (no sRGB decode on sampling, no linear-light
    // math anywhere) - matching upstream, which never touches texture encoding either. So there is no
    // radiometric "linear HDR" here: "HDR" only means the composite is allowed to exceed 1.0 mid-pipeline
    // instead of being clamped at every 8-bit stage, so bloom/shine thresholds (authored against true
    // brightness) don't see an artificially flattened, over-large "everything is 1.0" region.
    //
    // The final blit is therefore the one and only place that needs to reconcile that with 8-bit display
    // output. For non-HDR scenes it stays a pure passthrough (unchanged, full parity). For HDR scenes an
    // exponential knee starting at k (< 1.0) compresses everything above k into the remaining (1 - k)
    // headroom, asymptotically approaching (never reaching/clipping at) 1.0. Values below k pass through
    // untouched, so mid-tone parity is preserved (the scene's water tone sits well below k). The knee must
    // start BELOW 1.0: a knee anchored exactly at 1.0 has a gain term of (1 - low) = 0 for any input >= 1.0,
    // which silently degenerates into a hard clip — every overbright pixel lands on a flat 255 plateau and
    // star-glint ray falloffs render as solid white puffballs instead of crisp cores with fading rays.
    // With k < 1.0 a gradient survives across the whole overbright region and only true peaks read as white.
    //
    // This stays per-channel rather than luminance-based. A hue-preserving luminance knee was tried and
    // measured: it made the known magenta glint-core cast *worse* (core R-G went from a mild +1.9 to +37.8
    // on this scene), which only makes sense if the true un-clamped HDR color feeding this blit is itself
    // significantly red/magenta-biased - an upstream color-authoring/compositing property, not something
    // introduced by this knee's math. (An 8-bit --dump-passes capture of the pass right before this blit
    // looked green/neutral at first glance, but glReadPixels there reads back as GL_UNSIGNED_BYTE, which
    // itself hard-clamps to [0,1] before the knee ever runs - exactly the overbright range this bug is
    // about - so that capture cannot be trusted to reveal true relative channel magnitudes above 1.0.) Since
    // the per-channel knee's incidental desaturation happens to land closer to the reference render for this
    // scene, and the hue-preserving alternative demonstrably does not fix the root cause, it is kept as-is.
    sourcePointer = this->isHdr ()
	? "#version 330\n"
	  "precision highp float;\n"
	  "uniform sampler2D g_Texture0;\n"
	  "in vec2 v_TexCoord;\n"
	  "out vec4 out_FragColor;\n"
	  "void main () {\n"
	  "vec4 hdr = texture (g_Texture0, v_TexCoord);\n"
	  "const float k = 0.6;\n"
	  "vec3 low = min (hdr.rgb, vec3 (k));\n"
	  "vec3 over = max (hdr.rgb - vec3 (k), vec3 (0.0));\n"
	  "vec3 mapped = low + (1.0 - k) * (vec3 (1.0) - exp (-over / (1.0 - k)));\n"
	  "out_FragColor = vec4 (clamp (mapped, 0.0, 1.0), hdr.a);\n"
	  "}"
	: "#version 330\n"
	  "precision highp float;\n"
	  "uniform sampler2D g_Texture0;\n"
	  "in vec2 v_TexCoord;\n"
	  "out vec4 out_FragColor;\n"
	  "void main () {\n"
	  "out_FragColor = texture (g_Texture0, v_TexCoord);\n"
	  "}";

    glShaderSource (fragmentShaderID, 1, &sourcePointer, nullptr);
    glCompileShader (fragmentShaderID);

    result = GL_FALSE;
    infoLogLength = 0;

    // ensure the vertex shader was correctly compiled
    glGetShaderiv (fragmentShaderID, GL_COMPILE_STATUS, &result);
    glGetShaderiv (fragmentShaderID, GL_INFO_LOG_LENGTH, &infoLogLength);

    if (infoLogLength > 0) {
	const auto logBuffer = new char[infoLogLength + 1];
	// ensure logBuffer ends with a \0
	memset (logBuffer, 0, infoLogLength + 1);
	// get information about the error
	glGetShaderInfoLog (fragmentShaderID, infoLogLength, nullptr, logBuffer);
	// throw an exception about the issue
	const std::string message = logBuffer;
	// free the buffer
	delete[] logBuffer;
	// throw an exception
	sLog.exception (message);
    }

    // create the final program
    this->m_shader = glCreateProgram ();
    // link the shaders together
    glAttachShader (this->m_shader, vertexShaderID);
    glAttachShader (this->m_shader, fragmentShaderID);
    glLinkProgram (this->m_shader);
    // check that the shader was properly linked
    result = GL_FALSE;
    infoLogLength = 0;

    glGetProgramiv (this->m_shader, GL_LINK_STATUS, &result);
    glGetProgramiv (this->m_shader, GL_INFO_LOG_LENGTH, &infoLogLength);

    if (infoLogLength > 0) {
	const auto logBuffer = new char[infoLogLength + 1];
	// ensure logBuffer ends with a \0
	memset (logBuffer, 0, infoLogLength + 1);
	// get information about the error
	glGetProgramInfoLog (this->m_shader, infoLogLength, nullptr, logBuffer);
	// throw an exception about the issue
	const std::string message = logBuffer;
	// free the buffer
	delete[] logBuffer;
	// throw an exception
	sLog.exception (message);
    }

    // after being liked shaders can be dettached and deleted
    glDetachShader (this->m_shader, vertexShaderID);
    glDetachShader (this->m_shader, fragmentShaderID);

    glDeleteShader (vertexShaderID);
    glDeleteShader (fragmentShaderID);

    // get textures
    this->g_Texture0 = glGetUniformLocation (this->m_shader, "g_Texture0");
    this->a_Position = glGetAttribLocation (this->m_shader, "a_Position");
    this->a_TexCoord = glGetAttribLocation (this->m_shader, "a_TexCoord");
}

void CWallpaper::setDestinationFramebuffer (GLuint framebuffer) { this->m_destFramebuffer = framebuffer; }

void CWallpaper::setSpanInfo (const SpanInfo& spanInfo) { this->m_spanInfo = spanInfo; }

const CWallpaper::SpanInfo* CWallpaper::getSpanInfo () const {
    return this->m_spanInfo.has_value () ? &this->m_spanInfo.value () : nullptr;
}

void CWallpaper::updateUVs (const glm::ivec4& viewport, const bool vflip) {
    // update UVs if something has changed, otherwise use old values
    if (this->m_state.hasChanged (viewport, vflip, this->getWidth (), this->getHeight ())) {
	// Update wallpaper state
	this->m_state.updateState (viewport, vflip, this->getWidth (), this->getHeight ());
    }
}

void CWallpaper::render (
    const glm::ivec4& viewport, const bool vflip, const glm::ivec2& globalPosition, const glm::ivec2& logicalSize
) {
    // Get current frame counter from the driver to avoid redundant scene renders
    const uint32_t currentFrame = this->getContext ().getDriver ().getFrameCounter ();
    const bool needsSceneRender = (currentFrame != this->m_lastRenderedFrame);
    const glm::ivec4 sceneViewport = this->m_spanInfo.has_value ()
	? glm::ivec4 { 0, 0, this->m_spanInfo->totalBounds.z, this->m_spanInfo->totalBounds.w }
	: viewport;

#if !NDEBUG
    glPushDebugGroup (GL_DEBUG_SOURCE_APPLICATION, 0, -1, "Rendering scene");
#endif /* !NDEBUG */
    if (needsSceneRender) {
	this->renderFrame (sceneViewport);
	this->m_lastRenderedFrame = currentFrame;
    }
#if !NDEBUG
    glPopDebugGroup ();
    glPushDebugGroup (GL_DEBUG_SOURCE_APPLICATION, 0, -1, "Rendering scene to output");
#endif /* !NDEBUG */

    float ustart, uend, vstart, vend;

    if (this->m_spanInfo.has_value ()) {
	// Span mode: treat bounding box as virtual viewport, scale wallpaper using
	// the normal scaling rules (fill/fit/stretch/default), then slice per monitor.
	const auto& span = this->m_spanInfo.value ();
	const float spanW = static_cast<float> (span.totalBounds.z);
	const float spanH = static_cast<float> (span.totalBounds.w);
	const float spanX = static_cast<float> (span.totalBounds.x);
	const float spanY = static_cast<float> (span.totalBounds.y);

	// Compute base UVs for the wallpaper scaled to the bounding box
	this->updateUVs (span.totalBounds, vflip);
	auto [baseUstart, baseUend, baseVstart, baseVend] = this->m_state.getTextureUVs ();

	// This viewport's relative position within the bounding box [0..1]
	// Use logicalSize (same coordinate space as globalPosition and totalBounds)
	const float relLeft = (static_cast<float> (globalPosition.x) - spanX) / spanW;
	const float relRight = (static_cast<float> (globalPosition.x + logicalSize.x) - spanX) / spanW;
	const float relTop = (static_cast<float> (globalPosition.y) - spanY) / spanH;
	const float relBottom = (static_cast<float> (globalPosition.y + logicalSize.y) - spanY) / spanH;

	// Interpolate within the base UVs to get this viewport's slice
	const float baseURange = baseUend - baseUstart;
	const float baseVRange = baseVend - baseVstart;

	ustart = baseUstart + relLeft * baseURange;
	uend = baseUstart + relRight * baseURange;
	vstart = baseVstart + relTop * baseVRange;
	vend = baseVstart + relBottom * baseVRange;

	// Log span debug info only on first few frames
	if (this->m_lastRenderedFrame < 5) {
	    sLog.debug (
		"SPAN DEBUG: viewport=", viewport.z, "x", viewport.w, " globalPos=(", globalPosition.x, ",",
		globalPosition.y, ")", " span=(", span.totalBounds.x, ",", span.totalBounds.y, ",", span.totalBounds.z,
		",", span.totalBounds.w, ")", " rel=[", relLeft, ",", relRight, "]x[", relTop, ",", relBottom, "]",
		" baseUV=[", baseUstart, ",", baseUend, "]x[", baseVstart, ",", baseVend, "]", " finalUV=[", ustart,
		",", uend, "]x[", vstart, ",", vend, "]"
	    );
	}
    } else {
	// Normal mode: compute UVs based on viewport dimensions and wallpaper resolution
	updateUVs (viewport, vflip);
	auto uvs = this->m_state.getTextureUVs ();
	ustart = uvs.ustart;
	uend = uvs.uend;
	vstart = uvs.vstart;
	vend = uvs.vend;
    }

    // The "default" (and span) scaling math above picks a single scale factor from one dimension
    // (e.g. match-by-width) and derives the other axis's crop from it; it does not verify that the
    // result actually covers the viewport, so at aspect-ratio combinations where that assumption
    // doesn't hold, it can under-fit and hand back a UV range that overshoots the texture's valid
    // [0,1] bounds instead of a proper inward crop. Sampling outside that range against a
    // CLAMP_TO_EDGE texture then repeats a single source row/column across every output row/column
    // in the overshoot band - and since that edge row is ordinary high-frequency scene content
    // (e.g. water ripples), the repeated copies read back as vertical/horizontal stripe garbage,
    // worst right at the top/bottom (or left/right) edges. Clamping here guarantees we only ever
    // sample real, distinct texture rows/columns, so at worst the crop is very slightly less
    // aggressive than intended instead of smearing one row across a whole edge band.
    ustart = std::clamp (ustart, 0.0f, 1.0f);
    uend = std::clamp (uend, 0.0f, 1.0f);
    vstart = std::clamp (vstart, 0.0f, 1.0f);
    vend = std::clamp (vend, 0.0f, 1.0f);

    const GLfloat texCoords[] = {
	ustart, vstart, uend, vstart, ustart, vend, ustart, vend, uend, vstart, uend, vend,
    };

    glViewport (viewport.x, viewport.y, viewport.z, viewport.w);

    glBindFramebuffer (GL_FRAMEBUFFER, this->m_destFramebuffer);

    glBindVertexArray (this->m_vaoBuffer);

    glDisable (GL_BLEND);
    glDisable (GL_DEPTH_TEST);
    glDisable (GL_CULL_FACE);
    // do not use any shader
    glUseProgram (this->m_shader);
    // activate scene texture
    glActiveTexture (GL_TEXTURE0);
    glBindTexture (GL_TEXTURE_2D, this->getWallpaperTexture ());
    // set uniforms and attribs
    glEnableVertexAttribArray (this->a_TexCoord);
    glBindBuffer (GL_ARRAY_BUFFER, this->m_texCoordBuffer);
    glBufferData (GL_ARRAY_BUFFER, sizeof (texCoords), texCoords, GL_STATIC_DRAW);
    glVertexAttribPointer (this->a_TexCoord, 2, GL_FLOAT, GL_FALSE, 0, nullptr);

    glEnableVertexAttribArray (this->a_Position);
    glBindBuffer (GL_ARRAY_BUFFER, this->m_positionBuffer);
    glVertexAttribPointer (this->a_Position, 3, GL_FLOAT, GL_FALSE, 0, nullptr);

    glUniform1i (this->g_Texture0, 0);
    // write the framebuffer as is to the screen
    glBindBuffer (GL_ARRAY_BUFFER, this->m_texCoordBuffer);
    glDrawArrays (GL_TRIANGLES, 0, 6);

#if !NDEBUG
    glPopDebugGroup ();
#endif /* !NDEBUG */
}

void CWallpaper::setPause (bool newState) { }

void CWallpaper::setupFramebuffers () {
    const uint32_t width = this->getWidth ();
    const uint32_t height = this->getHeight ();
    const uint32_t clamp = this->m_state.getClampingMode ();

    // create framebuffer for the scene. HDR scenes composite in float precision so bloom/shine thresholds see
    // true un-clamped brightness; the final tonemap (setupShaders()) compresses it back to displayable range.
    const TextureFormat mainFormat = this->isHdr () ? TextureFormat_RGBA16161616f : TextureFormat_ARGB8888;

    this->m_sceneFBO = this->create (
	"_rt_FullFrameBuffer", mainFormat, clamp, 1.0, { width, height }, { width, height }
    );

    this->alias ("_rt_MipMappedFrameBuffer", "_rt_FullFrameBuffer");
}

AudioContext& CWallpaper::getAudioContext () const { return this->m_audioContext; }

const WallpaperState& CWallpaper::getState () const { return this->m_state; }

std::shared_ptr<const CFBO> CWallpaper::findFBO (const std::string& name) const {
    const auto fbo = this->find (name);

    if (fbo == nullptr) {
	sLog.exception ("Cannot find FBO ", name);
    }

    return fbo;
}

std::shared_ptr<const CFBO> CWallpaper::getFBO () const { return this->m_sceneFBO; }

std::unique_ptr<CWallpaper> CWallpaper::fromWallpaper (
    const Wallpaper& wallpaper, RenderContext& context, AudioContext& audioContext,
    WebBrowser::WebBrowserContext* browserContext, const WallpaperState::TextureUVsScaling& scalingMode,
    const uint32_t& clampMode
) {
    if (wallpaper.is<Scene> ()) {
	return std::make_unique<WallpaperEngine::Render::Wallpapers::CScene> (
	    wallpaper, context, audioContext, scalingMode, clampMode
	);
    }

    if (wallpaper.is<Video> ()) {
	return std::make_unique<WallpaperEngine::Render::Wallpapers::CVideo> (
	    wallpaper, context, audioContext, scalingMode, clampMode
	);
    }

    if (wallpaper.is<Web> ()) {
#ifdef WPENGINE_SCENE_ONLY
	sLog.exception ("Web wallpapers are not supported in the scene-only renderer");
#else
	return std::make_unique<WallpaperEngine::Render::Wallpapers::CWeb> (
	    wallpaper, context, audioContext, *browserContext, scalingMode, clampMode
	);
#endif
    }

    sLog.exception ("Unsupported wallpaper type");
}
