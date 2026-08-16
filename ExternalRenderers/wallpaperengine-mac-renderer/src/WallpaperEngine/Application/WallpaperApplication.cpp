#include "WallpaperApplication.h"

#include "Steam/FileSystem/FileSystem.h"
#include "WallpaperEngine/Application/ApplicationState.h"
#include "WallpaperEngine/Assets/AssetLoadException.h"
#include "WallpaperEngine/FileSystem/Container.h"
#include "WallpaperEngine/Logging/Log.h"
#include "WallpaperEngine/Render/Drivers/VideoFactories.h"
#include "WallpaperEngine/Render/RenderContext.h"
#include "WallpaperEngine/Render/Shaders/GLSLContext.h"

#include "WallpaperEngine/Data/Dumpers/StringPrinter.h"
#include "WallpaperEngine/Data/Parsers/ProjectParser.h"

#include "WallpaperEngine/Data/Model/Property.h"
#include "WallpaperEngine/Data/Model/Wallpaper.h"
#include "WallpaperEngine/Debugging/CallStack.h"
#include "WallpaperEngine/FileSystem/Adapters/MediaCover.h"
#ifndef WPENGINE_SCENE_ONLY
#include "WallpaperEngine/Audio/Drivers/Detectors/PulseAudioPlayingDetector.h"
#include "WallpaperEngine/Media/DBusMediaSource.h"
#endif

#if DEMOMODE
#include "recording.h"
#endif /* DEMOMODE */

#include <algorithm>
#include <climits>
#include <cmath>
#include <cstring>
#include <numeric>
#include <sstream>
#include <unistd.h>
#include <vector>

#include <atomic>
#include <condition_variable>
#include <cerrno>
#include <mutex>
#include <queue>
#include <fcntl.h>
#include <sys/stat.h>
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include <stb_image_write.h>
#define STB_IMAGE_RESIZE_IMPLEMENTATION
#include <stb_image_resize2.h>
#include <thread>

#define FULLSCREEN_CHECK_WAIT_TIME 250

float g_Time;
float g_TimeLast;
float g_Daytime;

using namespace WallpaperEngine::Assets;
using namespace WallpaperEngine::Application;
using namespace WallpaperEngine::Data::Model;
using namespace WallpaperEngine::FileSystem;

#ifdef WPENGINE_SCENE_ONLY
namespace {
class NullMediaSource final : public WallpaperEngine::Media::MediaSource {
public:
    NullMediaSource () : MediaSource (std::chrono::milliseconds (2000)) { }

private:
    void performUpdate () override { }
};

/**
 * Streams tightly packed raw frames to a file or FIFO from a dedicated writer thread.
 *
 * The render loop calls acquire()/buffer()/submit() to hand off a freshly captured frame; the
 * writer thread performs the (potentially blocking, e.g. on a slow FIFO consumer) write() call
 * on its own thread so the render loop only stalls once every ring slot is full, rather than on
 * every single frame.
 */
class RawFrameWriter {
public:
    RawFrameWriter (const std::filesystem::path& path, size_t frameBytes, size_t ringSize = 3) :
	m_frameBytes (frameBytes), m_ring (ringSize, std::vector<uint8_t> (frameBytes)) {
	struct stat st { };
	const bool isFifo = ::stat (path.c_str (), &st) == 0 && S_ISFIFO (st.st_mode);

	m_fd = isFifo ? ::open (path.c_str (), O_WRONLY) : ::open (path.c_str (), O_WRONLY | O_CREAT | O_TRUNC, 0644);

	if (m_fd < 0) {
	    sLog.exception ("Cannot open raw record output ", path.string (), ": ", std::strerror (errno));
	}

	for (size_t i = 0; i < ringSize; i++) {
	    m_freeSlots.push (i);
	}

	m_thread = std::thread (&RawFrameWriter::run, this);
    }

    RawFrameWriter (const RawFrameWriter&) = delete;
    RawFrameWriter& operator= (const RawFrameWriter&) = delete;

    ~RawFrameWriter () { finish (); }

    /** Blocks until a ring slot is free, then returns its index. */
    size_t acquire () {
	std::unique_lock lock (m_mutex);
	m_freeCv.wait (lock, [this] { return !m_freeSlots.empty (); });
	const size_t slot = m_freeSlots.front ();
	m_freeSlots.pop ();
	return slot;
    }

    std::vector<uint8_t>& buffer (size_t slot) { return m_ring[slot]; }

    /** Hands the filled slot off to the writer thread. */
    void submit (size_t slot) {
	{
	    std::lock_guard lock (m_mutex);
	    m_readySlots.push (slot);
	}
	m_readyCv.notify_one ();
    }

    /** Flushes remaining frames, joins the writer thread, and closes the output. */
    void finish () {
	if (m_finished.exchange (true)) {
	    return;
	}

	{
	    std::lock_guard lock (m_mutex);
	    m_done = true;
	}
	m_readyCv.notify_one ();

	if (m_thread.joinable ()) {
	    m_thread.join ();
	}

	if (m_fd >= 0) {
	    ::close (m_fd);
	    m_fd = -1;
	}
    }

private:
    void run () {
	while (true) {
	    std::unique_lock lock (m_mutex);
	    m_readyCv.wait (lock, [this] { return !m_readySlots.empty () || m_done; });

	    if (m_readySlots.empty ()) {
		if (m_done) {
		    break;
		}
		continue;
	    }

	    const size_t slot = m_readySlots.front ();
	    m_readySlots.pop ();
	    lock.unlock ();

	    const uint8_t* data = m_ring[slot].data ();
	    size_t remaining = m_frameBytes;

	    while (remaining > 0) {
		const ssize_t written = ::write (m_fd, data, remaining);

		if (written < 0) {
		    if (errno == EINTR) {
			continue;
		    }
		    sLog.error ("Error writing raw record frame: ", std::strerror (errno));
		    break;
		}

		data += written;
		remaining -= static_cast<size_t> (written);
	    }

	    {
		std::lock_guard freeLock (m_mutex);
		m_freeSlots.push (slot);
	    }
	    m_freeCv.notify_one ();
	}
    }

    size_t m_frameBytes;
    std::vector<std::vector<uint8_t>> m_ring;
    std::queue<size_t> m_freeSlots;
    std::queue<size_t> m_readySlots;
    std::mutex m_mutex;
    std::condition_variable m_freeCv;
    std::condition_variable m_readyCv;
    bool m_done = false;
    std::atomic<bool> m_finished { false };
    std::thread m_thread;
    int m_fd = -1;
};

const std::vector<std::filesystem::path>& requiredEngineAssetPaths () {
    static const std::vector<std::filesystem::path> paths = {
	"models/util/composelayer.json",
	"materials/util/composelayer.json",
	"materials/util/effectpassthrough.json",
	"materials/util/downsample_quarter_bloom.json",
	"materials/util/downsample_eighth_blur_v.json",
	"materials/util/blur_h_bloom.json",
	"materials/util/combine.json",
	"shaders/genericimage2.frag",
	"shaders/genericimage2.vert",
	"shaders/common_blur.h",
	"shaders/genericparticle.vert",
	"shaders/genericparticle.frag",
    };
    return paths;
}

std::vector<std::filesystem::path> missingEngineAssetPaths (const Container& container) {
    std::vector<std::filesystem::path> missing;

    for (const auto& relativePath : requiredEngineAssetPaths ()) {
	try {
	    [[maybe_unused]] const auto asset = container.read (relativePath);
	} catch (std::runtime_error&) {
	    missing.emplace_back (relativePath);
	}
    }

    return missing;
}

std::string missingEngineAssetsMessage (
    const std::filesystem::path& assetsPath, const std::vector<std::filesystem::path>& missing
) {
    std::ostringstream output;
    output << "Wallpaper Engine assets are required at " << assetsPath.string () << "; missing ";
    for (std::size_t i = 0; i < missing.size (); ++i) {
	if (i != 0) {
	    output << ", ";
	}
	output << missing[i].string ();
    }
    output << ". Provide the real Wallpaper Engine assets folder with --assets-dir /path/to/wallpaper_engine/assets";
    return output.str ();
}
}
#endif

void CustomGLDebugCallback (
    GLenum source, GLenum type, GLuint id, GLenum severity, GLsizei length, const GLchar* message, const void* userParam
) {
    if (severity != GL_DEBUG_SEVERITY_HIGH) {
	return;
    }

    sLog.error ("OpenGL error: ", message, ", type: ", type, ", id: ", id);

    std::vector<WallpaperEngine::Debugging::CallStack::CallInfo> callInfo;

    WallpaperEngine::Debugging::CallStack::GetCalls (callInfo);

    for (std::vector<WallpaperEngine::Debugging::CallStack::CallInfo>::size_type i = 0; i < callInfo.size (); ++i) {
	fprintf (
	    stderr, "[%3lu] %15lu: %s in %s\n", callInfo.size () - i, callInfo[i].offset, callInfo[i].function.c_str (),
	    callInfo[i].module.c_str ()
	);
    }
}

WallpaperApplication::WallpaperApplication (ApplicationContext& context) : m_context (context) {
    this->initializeSubsystems ();
    this->loadBackgrounds ();
    this->setupProperties ();
    this->setupBrowser ();
    this->initializePlaylists ();
}

void WallpaperApplication::initializeSubsystems () {
#ifdef WPENGINE_SCENE_ONLY
    m_mediaSource = std::make_unique<NullMediaSource> ();
#else
    // initialize player dbus (update every 2 seconds)
    m_mediaSource = std::make_unique<WallpaperEngine::Media::DBusMediaSource> (std::chrono::milliseconds (2000));
#endif
}

AssetLocatorUniquePtr WallpaperApplication::setupAssetLocator (const std::string& bg) const {
    auto container = std::make_unique<Container> ();

    const std::filesystem::path path = bg;

    container->registerAdapterFactory (std::make_unique<MediaCoverFactory> (*this->m_mediaSource));
    container->mount ("$mediaThumbnail", "$mediaThumbnail");
    container->mount (path, "/");

    try {
	container->mount (path / "scene.pkg", "/");
    } catch (std::runtime_error&) { }

    try {
	container->mount (path / "gifscene.pkg", "/");
    } catch (std::runtime_error&) { }

    try {
	container->mount (this->m_context.settings.general.assets, "/");
    } catch (std::runtime_error&) {
#ifdef WPENGINE_SCENE_ONLY
	throw std::runtime_error (
	    missingEngineAssetsMessage (this->m_context.settings.general.assets, requiredEngineAssetPaths ())
	);
#else
	sLog.exception ("Cannot find a valid assets folder, resolved to ", this->m_context.settings.general.assets);
#endif
    }

#ifdef WPENGINE_SCENE_ONLY
    const auto missingEngineAssets = missingEngineAssetPaths (*container);
    if (!missingEngineAssets.empty ()) {
	throw std::runtime_error (missingEngineAssetsMessage (this->m_context.settings.general.assets, missingEngineAssets));
    }
#endif

    // mount the current directory as root
    try {
	container->mount (std::filesystem::current_path (), "/");
    } catch (std::runtime_error&) { }

    auto& vfs = container->getVFS ();

    //
    // Had to get a little creative with the effects to achieve the same bloom effect without any custom code
    // these virtual files are loaded by an image in the scene that takes current _rt_FullFrameBuffer and
    // applies the bloom effect to render it out to the screen
    //

    // add the effect file for screen bloom

    // add some model for the image element even if it's going to waste rendering cycles
    vfs.add (
	"effects/wpenginelinux/bloomeffect.json",
	{ { "name", "camerabloom_wpengine_linux" },
	  { "group", "wpengine_linux_camera" },
	  { "dependencies", JSON::array () },
	  {
	      "passes",
	      JSON::array (
		  { { { "material", "materials/util/hdr_knee.json" },
		      { "target", "_rt_FullFrameBufferBloomSrc" },
		      { "bind", JSON::array ({ { { "name", "_rt_FullFrameBuffer" }, { "index", 0 } } }) } },
		    { { "material", "materials/util/downsample_quarter_bloom.json" },
		      { "target", "_rt_4FrameBuffer" },
		      { "bind", JSON::array ({ { { "name", "_rt_FullFrameBufferBloomSrc" }, { "index", 0 } } }) } },
		    { { "material", "materials/util/downsample_eighth_blur_v.json" },
		      { "target", "_rt_8FrameBuffer" },
		      { "bind", JSON::array ({ { { "name", "_rt_4FrameBuffer" }, { "index", 0 } } }) } },
		    { { "material", "materials/util/blur_h_bloom.json" },
		      { "target", "_rt_Bloom" },
		      { "bind", JSON::array ({ { { "name", "_rt_8FrameBuffer" }, { "index", 0 } } }) } },
		    { { "material", "materials/util/combine.json" },
		      { "target", "_rt_FullFrameBuffer" },
		      { "bind",
			JSON::array (
			    { { { "name", "_rt_imageLayerComposite_-1_a" }, { "index", 0 } },
			      { { "name", "_rt_Bloom" }, { "index", 1 } } }
			) } } }
	      ),
	  } }
    );

    vfs.add ("models/wpenginelinux.json", R"({"material":"materials/wpenginelinux.json","passthrough":true})");
    vfs.add (
	"models/util/composelayer.json",
	R"({"material":"materials/util/composelayer.json","passthrough":true})"
    );
    vfs.add (
	"materials/util/composelayer.json",
	R"({"passes":[{"shader":"composelayer","depthtest":"disabled","depthwrite":"disabled","blending":"translucent","cullmode":"nocull","textures":["_rt_FullFrameBuffer"]}]})"
    );
    vfs.add (
	"materials/util/effectpassthrough.json",
	R"({"passes":[{"shader":"genericimage3","blending":"normal","depthtest":"disabled","depthwrite":"disabled","cullmode":"nocull"}]})"
    );
    vfs.add (
	"materials/util/downsample_quarter_bloom.json",
	R"({"passes":[{"shader":"downsample_quarter_bloom","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","textures":["_rt_FullFrameBufferBloomSrc"]}]})"
    );
    vfs.add (
	"materials/util/hdr_knee.json",
	R"({"passes":[{"shader":"commands/hdr_knee","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","textures":["_rt_FullFrameBuffer"]}]})"
    );
    vfs.add (
	"materials/util/downsample_eighth_blur_v.json",
	R"({"passes":[{"shader":"downsample_eighth_blur_v","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","textures":["_rt_4FrameBuffer"]}]})"
    );
    vfs.add (
	"materials/util/blur_h_bloom.json",
	R"({"passes":[{"shader":"blur_h_bloom","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","textures":["_rt_8FrameBuffer"]}]})"
    );
    vfs.add (
	"materials/util/combine.json",
	R"({"passes":[{"shader":"combine","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","textures":["_rt_FullFrameBuffer","util/black"]}]})"
    );

    vfs.add (
	"materials/wpenginelinux.json",
	{ { "passes",
	    JSON::array (
		{ { { "blending", "normal" },
		    { "cullmode", "nocull" },
		    { "depthtest", "disabled" },
		    { "depthwrite", "disabled" },
		    { "shader", "genericimage2" },
		    { "textures", JSON::array ({ "_rt_FullFrameBuffer" }) } } }
	) } }
    );

    vfs.add (
	"shaders/commands/copy.frag",
	"uniform sampler2D g_Texture0;\n"
	"in vec2 v_TexCoord;\n"
	"void main () {\n"
	"out_FragColor = texture (g_Texture0, v_TexCoord);\n"
	"}"
    );
    vfs.add (
	"shaders/commands/copy.vert",
	"in vec3 a_Position;\n"
	"in vec2 a_TexCoord;\n"
	"out vec2 v_TexCoord;\n"
	"void main () {\n"
	"gl_Position = vec4 (a_Position, 1.0);\n"
	"v_TexCoord = a_TexCoord;\n"
	"}"
    );

    // Bright-pass input conditioner for the bloom chain (see setup of "_rt_FullFrameBufferBloomSrc" in CScene).
    // Unlike the final on-screen tonemap (which must land in [0,1] for 8-bit display), this soft ceiling keeps
    // a wide overbright headroom: values up to "k" pass through untouched, values above it compress
    // asymptotically towards k + headroom instead of towards 1.0. This bounds the unbounded HDR pileup our
    // composite can otherwise accumulate (stacked emissive/shine layers reaching 10-50x) while still letting
    // genuinely bright glint/shine sources read comfortably above an authored bloomthreshold of 1.0, which a
    // display-range clamp cannot do (it would make bloom vanish whenever threshold >= 1.0).
    vfs.add (
	"shaders/commands/hdr_knee.frag",
	"uniform sampler2D g_Texture0;\n"
	"in vec2 v_TexCoord;\n"
	"void main () {\n"
	"vec4 hdr = texture (g_Texture0, v_TexCoord);\n"
	"const float k = 1.5;\n"
	"const float headroom = 2.5;\n"
	"vec3 low = min (hdr.rgb, vec3 (k));\n"
	"vec3 over = max (hdr.rgb - vec3 (k), vec3 (0.0));\n"
	"vec3 mapped = low + headroom * (vec3 (1.0) - exp (-over / headroom));\n"
	"out_FragColor = vec4 (max (mapped, vec3 (0.0)), hdr.a);\n"
	"}"
    );
    vfs.add (
	"shaders/commands/hdr_knee.vert",
	"in vec3 a_Position;\n"
	"in vec2 a_TexCoord;\n"
	"out vec2 v_TexCoord;\n"
	"void main () {\n"
	"gl_Position = vec4 (a_Position, 1.0);\n"
	"v_TexCoord = a_TexCoord;\n"
	"}"
    );

    return std::make_unique<AssetLocator> (std::move (container));
}

void WallpaperApplication::loadBackgrounds () {
    if (this->m_context.settings.render.mode == ApplicationContext::NORMAL_WINDOW
	|| this->m_context.settings.render.mode == ApplicationContext::EXPLICIT_WINDOW) {
	auto path = this->m_context.settings.general.defaultBackground;

	if (this->m_context.settings.general.defaultPlaylist.has_value ()
	    && !this->m_context.settings.general.defaultPlaylist->items.empty ()) {
	    path = this->m_context.settings.general.defaultPlaylist->items.front ();
	}

	this->m_backgrounds["default"] = this->loadBackground (path);
	return;
    }

    for (const auto& [screen, path] : this->m_context.settings.general.screenBackgrounds) {
	// skip span group synthetic keys here, they're handled below
	if (screen.rfind ("span:", 0) == 0) {
	    continue;
	}
	// screens with no path should use the default
	if (path.empty ()) {
	    this->m_backgrounds[screen] = this->loadBackground (this->m_context.settings.general.defaultBackground);
	} else {
	    this->m_backgrounds[screen] = this->loadBackground (path);
	}
    }

    // Load one background per span group
    for (const auto& spanGroup : this->m_context.settings.general.spanGroups) {
	if (spanGroup.screens.empty ()) {
	    continue;
	}

	std::filesystem::path bgPath = spanGroup.background;
	if (bgPath.empty ()) {
	    bgPath = this->m_context.settings.general.defaultBackground;
	}

	// use the first screen's name as the group key for the loaded project
	const std::string groupKey = "span:" + spanGroup.screens.front ();
	this->m_backgrounds[groupKey] = this->loadBackground (bgPath);
    }
}

ProjectUniquePtr WallpaperApplication::loadBackground (const std::string& bg) {
    auto container = this->setupAssetLocator (bg);
    auto json = WallpaperEngine::Data::JSON::JSON::parse (container->readString ("project.json"));

    // when a background is loaded, reset the screenshot variables
    // this allows taking screenshots after a background changes
    // useful for playlists
    if (this->m_context.settings.screenshot.take) {
	this->m_nextFrameScreenshot = this->m_context.settings.screenshot.delay;

	if (this->m_videoDriver != nullptr) {
	    this->m_nextFrameScreenshot += this->m_videoDriver->getFrameCounter ();
	}

	this->m_screenShotTaken = false;
    }

    return WallpaperEngine::Data::Parsers::ProjectParser::parse (json, std::move (container));
}

std::vector<std::size_t>
WallpaperApplication::buildPlaylistOrder (const ApplicationContext::PlaylistDefinition& definition) {
    std::vector<std::size_t> order (definition.items.size ());
    std::iota (order.begin (), order.end (), 0);

    if (definition.settings.order == "random") {
	std::shuffle (order.begin (), order.end (), this->m_playlistRng);
    }

    return order;
}

void WallpaperApplication::initializePlaylists () {
    const bool hasDefaultPlaylist = this->m_context.settings.general.defaultPlaylist.has_value ();
    const bool hasScreenPlaylists = !this->m_context.settings.general.screenPlaylists.empty ();

    if (!hasDefaultPlaylist && !hasScreenPlaylists) {
	return;
    }

    const auto now = std::chrono::steady_clock::now ();

    auto registerPlaylist = [this, now] (
				const std::string& key, const ApplicationContext::PlaylistDefinition& playlist,
				std::optional<std::filesystem::path> currentPath
			    ) {
	if (playlist.items.empty ()) {
	    return;
	}

	ActivePlaylist state;

	state.definition = playlist;
	state.order = this->buildPlaylistOrder (playlist);

	if (state.order.empty ()) {
	    return;
	}

	if (currentPath.has_value ()) {
	    state.orderIndex = 0;

	    for (std::size_t i = 0; i < state.order.size (); i++) {
		if (playlist.items[state.order[i]] == currentPath.value ()) {
		    state.orderIndex = i;
		    break;
		}
	    }
	}

	const uint32_t delayMinutes = std::max<uint32_t> (1, state.definition.settings.delayMinutes);
	state.nextSwitch = now + std::chrono::minutes (delayMinutes);
	state.lastUpdate = now;

	this->m_activePlaylists.insert_or_assign (key, std::move (state));
    };

    if (hasDefaultPlaylist
	&& (this->m_context.settings.render.mode == ApplicationContext::NORMAL_WINDOW
	    || this->m_context.settings.render.mode == ApplicationContext::EXPLICIT_WINDOW)) {
	const auto& playlist = this->m_context.settings.general.defaultPlaylist.value ();
	const auto currentPath = playlist.items.empty ()
	    ? std::optional<std::filesystem::path> { this->m_context.settings.general.defaultBackground }
	    : std::optional<std::filesystem::path> { playlist.items.front () };
	registerPlaylist ("default", playlist, currentPath);
    }

    for (const auto& [screen, playlist] : this->m_context.settings.general.screenPlaylists) {
	const auto current = this->m_context.settings.general.screenBackgrounds.find (screen);
	const auto currentPath = current != this->m_context.settings.general.screenBackgrounds.end ()
	    ? std::optional<std::filesystem::path> { current->second }
	    : std::nullopt;
	registerPlaylist (screen, playlist, currentPath);
    }
}

void WallpaperApplication::ensureBrowserForProject (const Project& project) {
#ifdef WPENGINE_SCENE_ONLY
    (void) project;
#else
    if (!project.wallpaper->is<Web> ()) {
	return;
    }

    if (!this->m_browserContext) {
	this->m_browserContext = std::make_unique<WebBrowser::WebBrowserContext> (*this);
    }
#endif
}

bool WallpaperApplication::makeAnyViewportCurrent () const {
    if (!this->m_renderContext) {
	return false;
    }

    const auto& viewports = this->m_renderContext->getOutput ().getViewports ();

    if (viewports.empty ()) {
	return false;
    }

    viewports.begin ()->second->makeCurrent ();
    return true;
}

bool WallpaperApplication::preflightWallpaper (const std::string& path) {
    try {
	// avoid mutating state, just ensure project.json parses
	auto container = this->setupAssetLocator (path);
	const auto json = WallpaperEngine::Data::JSON::JSON::parse (container->readString ("project.json"));
	if (!json.contains ("type") || !json.contains ("file")) {
	    sLog.error ("Preflight failed for ", path, ": missing required fields");
	    return false;
	}
	return true;
    } catch (const std::exception& e) {
	sLog.error ("Preflight failed for ", path, ": ", e.what ());
	return false;
    }
}

bool WallpaperApplication::selectNextCandidate (ActivePlaylist& playlist, std::size_t& outOrderIndex) {
    if (playlist.order.empty ()) {
	return false;
    }

    std::size_t attempts = 0;
    std::size_t candidateOrderIndex = outOrderIndex;

    while (attempts < playlist.order.size ()) {
	const auto candidateIndex = playlist.order[candidateOrderIndex];

	if (!playlist.failedIndices.contains (candidateIndex)) {
	    outOrderIndex = candidateOrderIndex;
	    return true;
	}

	attempts++;
	candidateOrderIndex = (candidateOrderIndex + 1) % playlist.order.size ();
    }

    return false;
}

void WallpaperApplication::advancePlaylist (
    const std::string& screen, ActivePlaylist& playlist, const std::chrono::steady_clock::time_point& now
) {
    if (playlist.order.empty ()) {
	return;
    }

    playlist.orderIndex = (playlist.orderIndex + 1) % playlist.order.size ();

    if (playlist.orderIndex == 0 && playlist.definition.settings.order == "random") {
	std::shuffle (playlist.order.begin (), playlist.order.end (), this->m_playlistRng);
    }

    std::size_t candidateOrderIndex = playlist.orderIndex;

    if (!this->selectNextCandidate (playlist, candidateOrderIndex)) {
	sLog.error ("All playlist items failed for ", screen, ", keeping current wallpaper");
	const uint32_t delayMinutes = std::max<uint32_t> (1, playlist.definition.settings.delayMinutes);
	playlist.nextSwitch = now + std::chrono::minutes (delayMinutes);
	return;
    }

    const auto candidateIndex = playlist.order[candidateOrderIndex];
    const auto& candidatePath = playlist.definition.items[candidateIndex];

    if (!this->preflightWallpaper (candidatePath.string ())) {
	playlist.failedIndices.insert (candidateIndex);

	if (!this->selectNextCandidate (playlist, candidateOrderIndex)) {
	    sLog.error ("All playlist items failed for ", screen, ", keeping current wallpaper");
	    const uint32_t delayMinutes = std::max<uint32_t> (1, playlist.definition.settings.delayMinutes);
	    playlist.nextSwitch = now + std::chrono::minutes (delayMinutes);
	    return;
	}
    }

    playlist.orderIndex = candidateOrderIndex;
    const auto& nextPath = playlist.definition.items[playlist.order[playlist.orderIndex]];

    bool loaded = false;

    try {
	if (!this->makeAnyViewportCurrent ()) {
	    sLog.error ("Cannot switch playlist on ", screen, ": no active viewport");
	    throw std::runtime_error ("No viewport available");
	}

	auto project = this->loadBackground (nextPath.string ());

	this->setupPropertiesForProject (*project);
	this->ensureBrowserForProject (*project);

	this->m_backgrounds[screen] = std::move (project);

	const auto scalingIt = this->m_context.settings.general.screenScalings.find (screen);
	const auto clampIt = this->m_context.settings.general.screenClamps.find (screen);
	const auto scaling = scalingIt != this->m_context.settings.general.screenScalings.end ()
	    ? scalingIt->second
	    : this->m_context.settings.render.window.scalingMode;
	const auto clamp = clampIt != this->m_context.settings.general.screenClamps.end ()
	    ? clampIt->second
	    : this->m_context.settings.render.window.clamp;

	if (this->m_renderContext) {
	    this->m_renderContext->setWallpaper (
		    screen,
		    WallpaperEngine::Render::CWallpaper::fromWallpaper (
			*this->m_backgrounds[screen]->wallpaper, *this->m_renderContext, *this->m_audioContext,
#ifdef WPENGINE_SCENE_ONLY
			nullptr,
#else
			this->m_browserContext.get (),
#endif
			scaling, clamp
		    )
		);
	}

	this->m_context.settings.general.screenBackgrounds[screen] = nextPath;
	loaded = true;
    } catch (const std::exception& e) {
	sLog.error ("Failed to advance playlist on ", screen, ": ", e.what ());
    }

    if (!loaded) {
	playlist.failedIndices.insert (playlist.order[playlist.orderIndex]);

	// Keep current position; next timer tick will retry advancement
	sLog.error ("Failed to load wallpaper for ", screen, ", will retry on next cycle");
    }

    const uint32_t delayMinutes = std::max<uint32_t> (1, playlist.definition.settings.delayMinutes);
    playlist.nextSwitch = now + std::chrono::minutes (delayMinutes);
}

void WallpaperApplication::updatePlaylists () {
    if (this->m_activePlaylists.empty ()) {
	return;
    }

    const auto now = std::chrono::steady_clock::now ();

    for (auto& [screen, playlist] : this->m_activePlaylists) {
	playlist.lastUpdate = now;

	if (playlist.definition.settings.mode != "timer") {
	    continue;
	}

	if (playlist.definition.items.size () <= 1) {
	    continue;
	}

	if (now < playlist.nextSwitch) {
	    continue;
	}

	this->advancePlaylist (screen, playlist, now);
    }
}

void WallpaperApplication::setupPropertiesForProject (const Project& project) {
    // show properties if required
    for (const auto& [key, cur] : project.properties) {
	// update the value of the property
	auto override = this->m_context.settings.general.properties.find (key);

	if (override != this->m_context.settings.general.properties.end ()) {
	    sLog.out ("Applying override value for ", key);

	    cur->update (override->second, DynamicValue::UpdateSource::User);
	}

	if (this->m_context.settings.general.onlyListProperties) {
	    sLog.out (cur->dump ());
	}
    }
}

void WallpaperApplication::setupProperties () {
    for (const auto& [background, info] : this->m_backgrounds) {
	this->setupPropertiesForProject (*info);
    }
}

void WallpaperApplication::setupBrowser () {
#ifdef WPENGINE_SCENE_ONLY
    return;
#else
    bool anyWebProject = std::any_of (
	this->m_backgrounds.begin (), this->m_backgrounds.end (),
	[] (const std::pair<const std::string, ProjectUniquePtr>& pair) -> bool {
	    return pair.second->wallpaper->is<Web> ();
	}
    );

    // do not perform any initialization if no web background is present
    if (!anyWebProject || this->m_browserContext) {
	return;
    }

    this->m_browserContext = std::make_unique<WebBrowser::WebBrowserContext> (*this);
#endif
}

void WallpaperApplication::takeScreenshot (const std::filesystem::path& filename, bool async) const {
    const int width = this->m_renderContext->getOutput ().getFullWidth ();
    const int height = this->m_renderContext->getOutput ().getFullHeight ();
    const bool vflip = this->m_renderContext->getOutput ().renderVFlip ();
    const auto& wallpapers = this->m_renderContext->getWallpapers ();

    struct ViewportCapture {
	uint8_t* buffer;
	int readWidth;
	int readHeight;
	int vpWidth;
	int vpHeight;
	int xoffset;
	float ustart, uend, vstart, vend;
    };

    std::vector<ViewportCapture> captures;
    int currentXOffset = 0;

    for (const auto& [screen, viewport] : this->m_renderContext->getOutput ().getViewports ()) {
	// activate opengl context so we can read from the framebuffer
	viewport->makeCurrent ();

	// find the wallpaper for this screen to read from its FBO
	const auto wallpaperIt = wallpapers.find (screen);
	if (wallpaperIt == wallpapers.end ()) {
	    sLog.error ("Cannot find wallpaper for screen ", screen);
	    continue;
	}

	const auto& wallpaper = wallpaperIt->second;
	const int vpWidth = viewport->viewport.z - viewport->viewport.x;
	const int vpHeight = viewport->viewport.w - viewport->viewport.y;

	// bind the wallpaper's FBO to read from it directly
	// this is more reliable than the default framebuffer on some drivers (NVIDIA/Wayland)
	glBindFramebuffer (GL_FRAMEBUFFER, wallpaper->getWallpaperFramebuffer ());

	// ensure rendering is complete before reading
	glFinish ();

	// make room for storing the pixel of this viewport
	const int readWidth = wallpaper->getWidth ();
	const int readHeight = wallpaper->getHeight ();
	const auto bufferSize = readWidth * readHeight * 3;
	auto* buffer = new uint8_t[bufferSize];

	// read the FBO data into the pixel buffer
	glPixelStorei (GL_PACK_ALIGNMENT, 1);
	if (GLEW_VERSION_4_5) {
	    glReadnPixels (0, 0, readWidth, readHeight, GL_RGB, GL_UNSIGNED_BYTE, bufferSize, buffer);
	} else {
	    glReadPixels (0, 0, readWidth, readHeight, GL_RGB, GL_UNSIGNED_BYTE, buffer);
	}

	// restore default framebuffer
	glBindFramebuffer (GL_FRAMEBUFFER, 0);

	if (const GLenum error = glGetError (); error != GL_NO_ERROR) {
	    sLog.error ("Cannot obtain pixel data for screen ", screen, ". OpenGL error: ", error);
	    delete[] buffer;
	    continue;
	}

	// Get the UV coordinates which define the visible portion based on scaling mode
	const auto [ustart, uend, vstart, vend] = wallpaper->getState ().getTextureUVs ();

	captures.push_back (
	    { buffer, readWidth, readHeight, vpWidth, vpHeight, currentXOffset, ustart, uend, vstart, vend }
	);

	if (viewport->single) {
	    currentXOffset += vpWidth;
	}
    }

    const auto extension = filename.extension ();
    const std::string extStr = extension.string ();

    // Offload pixel processing and saving to a background thread to avoid hitches
    std::thread worker ([captures, width, height, vflip, extStr, filename] () {
	auto* bitmap = new uint8_t[width * height * 3] { 0 };

	for (const auto& capture : captures) {
	    // The UV range can slightly overshoot [0,1] (the scaling code intentionally
	    // overscans so that, when sampled on the GPU with GL_CLAMP_TO_EDGE + bilinear
	    // filtering, the crop looks seamless). Naively converting UV -> nearest source
	    // pixel and clamping the index reproduces that overscan region by repeating a
	    // single source row/column across many destination rows/columns, which looks
	    // like a solid band of garbage/stripes wherever that single row/column contains
	    // fine detail (e.g. wave ripples). Use a proper filtered resize (stb_image_resize2)
	    // with clamp-to-edge sampling instead, so out-of-range UVs smoothly extend the
	    // edge pixel exactly like the GPU-rendered version does.
	    const bool flipX = capture.uend < capture.ustart;
	    const bool flipY = capture.vend < capture.vstart;
	    const double s0 = std::min (capture.ustart, capture.uend);
	    const double s1 = std::max (capture.ustart, capture.uend);
	    const double t0 = std::min (capture.vstart, capture.vend);
	    const double t1 = std::max (capture.vstart, capture.vend);

	    // stb_image_resize2 can crash when the requested input subrect extends far
	    // outside [0,1] combined with a large downsample ratio (an internal filter-
	    // width overflow in its region-clipping code). The overscan itself only
	    // exists so that, when sampled on the GPU with GL_CLAMP_TO_EDGE + bilinear
	    // filtering, the crop looks seamless -- there is no actual image data beyond
	    // UV [0,1], since that range already spans the entire captured FBO. So simply
	    // clamp the subrect to the valid [0,1] input range and resize it across the
	    // *entire* destination viewport. This is equivalent to the intended crop
	    // minus its edge-clamp margin (a small, imperceptible difference in zoom),
	    // and avoids both the crash and the alternative of duplicating/aliasing a
	    // single raw source row or column across a large destination band.
	    const double clampedS0 = std::clamp (s0, 0.0, 1.0);
	    const double clampedS1 = std::clamp (s1, 0.0, 1.0);
	    const double clampedT0 = std::clamp (t0, 0.0, 1.0);
	    const double clampedT1 = std::clamp (t1, 0.0, 1.0);

	    std::vector<uint8_t> resized (static_cast<size_t> (capture.vpWidth) * capture.vpHeight * 3);

	    if (clampedS1 > clampedS0 && clampedT1 > clampedT0) {
		STBIR_RESIZE resize;
		stbir_resize_init (
		    &resize, capture.buffer, capture.readWidth, capture.readHeight, 0, resized.data (), capture.vpWidth,
		    capture.vpHeight, 0, STBIR_RGB, STBIR_TYPE_UINT8
		);
		stbir_set_input_subrect (&resize, clampedS0, clampedT0, clampedS1, clampedT1);
		stbir_resize_extended (&resize);
	    }

	    // undo the ordering flip (reversed UV range) that stbir_set_input_subrect cannot
	    // express directly, since it always samples from s0/t0 towards s1/t1
	    if (flipX) {
		for (int y = 0; y < capture.vpHeight; y++) {
		    uint8_t* row = &resized[static_cast<size_t> (y) * capture.vpWidth * 3];
		    for (int x = 0; x < capture.vpWidth / 2; x++) {
			const int otherX = capture.vpWidth - 1 - x;
			for (int c = 0; c < 3; c++) {
			    std::swap (row[x * 3 + c], row[otherX * 3 + c]);
			}
		    }
		}
	    }
	    if (flipY) {
		for (int y = 0; y < capture.vpHeight / 2; y++) {
		    const int otherY = capture.vpHeight - 1 - y;
		    uint8_t* rowA = &resized[static_cast<size_t> (y) * capture.vpWidth * 3];
		    uint8_t* rowB = &resized[static_cast<size_t> (otherY) * capture.vpWidth * 3];
		    std::swap_ranges (rowA, rowA + capture.vpWidth * 3, rowB);
		}
	    }

	    // copy the resized viewport into the final bitmap
	    for (int y = 0; y < capture.vpHeight; y++) {
		const int xfinal = capture.xoffset;
		// FBO content is not flipped like default framebuffer, so invert vflip logic
		const int yfinal = vflip ? y : (capture.vpHeight - y - 1);

		if (yfinal < 0 || yfinal >= height) {
		    continue;
		}

		for (int x = 0; x < capture.vpWidth; x++) {
		    if (xfinal + x < 0 || xfinal + x >= width) {
			continue;
		    }

		    const size_t srcIdx = (static_cast<size_t> (y) * capture.vpWidth + x) * 3;
		    const size_t dstIdx = (static_cast<size_t> (yfinal) * width + xfinal + x) * 3;

		    bitmap[dstIdx] = resized[srcIdx];
		    bitmap[dstIdx + 1] = resized[srcIdx + 1];
		    bitmap[dstIdx + 2] = resized[srcIdx + 2];
		}
	    }

	    delete[] capture.buffer;
	}

	if (extStr == ".bmp") {
	    stbi_write_bmp (filename.c_str (), width, height, 3, bitmap);
	} else if (extStr == ".png") {
	    stbi_write_png (filename.c_str (), width, height, 3, bitmap, width * 3);
	} else if (extStr == ".jpg" || extStr == ".jpeg") {
	    stbi_write_jpg (filename.c_str (), width, height, 3, bitmap, 100);
	}

	delete[] bitmap;
    });

    if (async) {
	worker.detach ();
    } else {
	worker.join ();
    }
}

void WallpaperApplication::writeRecordedFrame (
    const std::filesystem::path& filename, const std::vector<uint8_t>& pixels
) const {
    const int width = this->m_renderContext->getOutput ().getFullWidth ();
    const int height = this->m_renderContext->getOutput ().getFullHeight ();
    const size_t rowBytes = static_cast<size_t> (width) * 3;

    std::vector<uint8_t> flipped (pixels.size ());

    for (int y = 0; y < height; y++) {
	std::memcpy (
	    &flipped[static_cast<size_t> (y) * rowBytes], &pixels[static_cast<size_t> (height - y - 1) * rowBytes],
	    rowBytes
	);
    }

    stbi_write_png (filename.c_str (), width, height, 3, flipped.data (), static_cast<int> (rowBytes));
}

void WallpaperApplication::setupOutput () {
    const char* XDG_SESSION_TYPE = getenv ("XDG_SESSION_TYPE");

    if (!XDG_SESSION_TYPE && this->m_context.settings.render.mode == ApplicationContext::DESKTOP_BACKGROUND) {
	sLog.exception (
	    "Cannot read environment variable XDG_SESSION_TYPE, window server detection failed. Please ensure proper "
	    "values are set"
	);
    }
    const std::string sessionType = XDG_SESSION_TYPE ? XDG_SESSION_TYPE : DEFAULT_WINDOW_NAME;

    sLog.debug ("Checking for window servers: ");

    for (const auto& windowServer : sVideoFactories.getRegisteredDrivers ()) {
	sLog.debug ("\t", windowServer);
    }

    this->m_videoDriver = sVideoFactories.createVideoDriver (
	this->m_context.settings.render.mode, sessionType, this->m_context, *this
    );
    this->m_fullScreenDetector
	= sVideoFactories.createFullscreenDetector (sessionType, this->m_context, *this->m_videoDriver);
}

void WallpaperApplication::setupAudio () {
    // ensure audioprocessing is required by any background, and we have it enabled
    const bool audioProcessingRequired = std::ranges::any_of (
	this->m_backgrounds, [] (const std::pair<const std::string, ProjectUniquePtr>& pair) -> bool {
	    return pair.second->supportsAudioProcessing;
	}
    );

    if (audioProcessingRequired && this->m_context.settings.audio.audioprocessing) {
#ifdef WPENGINE_SCENE_ONLY
	this->m_audioRecorder = std::make_unique<WallpaperEngine::Audio::Drivers::Recorders::PlaybackRecorder> ();
#else
	this->m_audioRecorder
	    = std::make_unique<WallpaperEngine::Audio::Drivers::Recorders::PulseAudioPlaybackRecorder> ();
#endif
    } else {
	this->m_audioRecorder = std::make_unique<WallpaperEngine::Audio::Drivers::Recorders::PlaybackRecorder> ();
    }

    if (this->m_context.settings.audio.automute) {
#ifdef WPENGINE_SCENE_ONLY
	m_audioDetector = std::make_unique<WallpaperEngine::Audio::Drivers::Detectors::AudioPlayingDetector> (
	    this->m_context, *this->m_fullScreenDetector
	);
#else
	m_audioDetector = std::make_unique<WallpaperEngine::Audio::Drivers::Detectors::PulseAudioPlayingDetector> (
	    this->m_context, *this->m_fullScreenDetector
	);
#endif
    } else {
	m_audioDetector = std::make_unique<WallpaperEngine::Audio::Drivers::Detectors::AudioPlayingDetector> (
	    this->m_context, *this->m_fullScreenDetector
	);
    }

    // initialize sdl audio driver
    m_audioDriver = std::make_unique<WallpaperEngine::Audio::Drivers::SDLAudioDriver> (
	this->m_context, *this->m_audioDetector, *this->m_audioRecorder
    );
    // initialize audio context
    m_audioContext = std::make_unique<WallpaperEngine::Audio::AudioContext> (*m_audioDriver);
}

void WallpaperApplication::prepareOutputs () {
    // initialize render context
    m_renderContext
	= std::make_unique<WallpaperEngine::Render::RenderContext> (*m_videoDriver, *this, *this->m_mediaSource);
    // create a new background for each screen

    // set all the specific wallpapers required (skip span group synthetic keys)
    for (const auto& [background, info] : this->m_backgrounds) {
	if (background.rfind ("span:", 0) == 0) {
	    continue;
	}
	const auto scalingIt = this->m_context.settings.general.screenScalings.find (background);
	const auto clampIt = this->m_context.settings.general.screenClamps.find (background);
	const auto scaling = scalingIt != this->m_context.settings.general.screenScalings.end ()
	    ? scalingIt->second
	    : this->m_context.settings.render.window.scalingMode;
	const auto clamp = clampIt != this->m_context.settings.general.screenClamps.end ()
	    ? clampIt->second
	    : this->m_context.settings.render.window.clamp;

	m_renderContext->setWallpaper (
	    background,
	    WallpaperEngine::Render::CWallpaper::fromWallpaper (
		*info->wallpaper, *m_renderContext, *m_audioContext,
#ifdef WPENGINE_SCENE_ONLY
		nullptr,
#else
		m_browserContext.get (),
#endif
		scaling, clamp
	    )
	);
    }

    // Set up span groups: one shared wallpaper per group, registered for each viewport
    for (const auto& spanGroup : this->m_context.settings.general.spanGroups) {
	if (spanGroup.screens.empty ()) {
	    continue;
	}

	const std::string groupKey = "span:" + spanGroup.screens.front ();
	const auto bgIt = this->m_backgrounds.find (groupKey);
	if (bgIt == this->m_backgrounds.end ()) {
	    continue;
	}

	// Compute the bounding box of all viewports in this span group
	const auto& viewports = m_renderContext->getOutput ().getViewports ();
	int minX = INT_MAX, minY = INT_MAX, maxX = INT_MIN, maxY = INT_MIN;
	bool anyFound = false;

	for (const auto& screenName : spanGroup.screens) {
	    const auto vpIt = viewports.find (screenName);
	    if (vpIt == viewports.end ()) {
		sLog.error ("Span group screen not found: ", screenName);
		continue;
	    }
	    anyFound = true;
	    const auto& vp = vpIt->second;
	    const int x = vp->globalPosition.x;
	    const int y = vp->globalPosition.y;
	    const int w = vp->logicalSize.x;
	    const int h = vp->logicalSize.y;
	    sLog.debug (
		"SPAN DEBUG prepareOutputs: screen '", screenName, "' globalPos=(", x, ",", y, ") logicalSize=", w, "x",
		h
	    );
	    minX = std::min (minX, x);
	    minY = std::min (minY, y);
	    maxX = std::max (maxX, x + w);
	    maxY = std::max (maxY, y + h);
	}

	if (!anyFound) {
	    sLog.error ("No viewports found for span group, skipping");
	    continue;
	}

	sLog.debug (
	    "SPAN DEBUG prepareOutputs: bounding box=(", minX, ",", minY, ",", maxX - minX, ",", maxY - minY, ")"
	);

	WallpaperEngine::Render::CWallpaper::SpanInfo spanInfo;
	spanInfo.totalBounds = { minX, minY, maxX - minX, maxY - minY };

	// Create one shared wallpaper with the span group's scaling mode
	auto sharedWallpaper = WallpaperEngine::Render::CWallpaper::fromWallpaper (
	    *bgIt->second->wallpaper, *m_renderContext, *m_audioContext,
#ifdef WPENGINE_SCENE_ONLY
	    nullptr,
#else
	    m_browserContext.get (),
#endif
	    spanGroup.scaling,
	    spanGroup.clamp
	);

	// Convert to shared_ptr so it can be registered for multiple viewports
	std::shared_ptr<WallpaperEngine::Render::CWallpaper> shared (std::move (sharedWallpaper));
	shared->setSpanInfo (spanInfo);

	// Register the same wallpaper for each screen in the span group
	for (const auto& screenName : spanGroup.screens) {
	    m_renderContext->setWallpaper (screenName, shared);
	}
    }
}

void WallpaperApplication::setupOpenGLDebugging () {
#if !NDEBUG
    glDebugMessageCallback (CustomGLDebugCallback, nullptr);
    glEnable (GL_DEBUG_OUTPUT_SYNCHRONOUS);
#endif
}

void WallpaperApplication::setup () {
    this->setupOutput ();
    this->setupAudio ();
    this->prepareOutputs ();
    this->setupOpenGLDebugging ();

    if (this->m_context.settings.general.dumpStructure) {
	auto prettyPrinter = Data::Dumpers::StringPrinter ();

	for (const auto& [background, info] : this->m_renderContext->getWallpapers ()) {
	    prettyPrinter.printWallpaper (info->getWallpaperData ());
	}

	std::cout << prettyPrinter.str () << std::endl;
    }

#if DEMOMODE
    // ensure only one background is running so everything can be properly caught
    if (this->m_renderContext->getWallpapers ().size () > 1) {
	sLog.exception ("Demo mode only supports one background");
    }

    int width = this->m_renderContext->getWallpapers ().begin ()->second->getWidth ();
    int height = this->m_renderContext->getWallpapers ().begin ()->second->getHeight ();
    std::vector<uint8_t> pixels (width * height * 3);
    bool initialized = false;
    int frame = 0;
#endif /* DEMOMODE */
}

void WallpaperApplication::render () {
    static time_t seconds;
    static struct tm* timeinfo;

    if (this->m_isPaused) {
	usleep (FULLSCREEN_CHECK_WAIT_TIME);
	if (this->m_fullScreenDetector->anythingFullscreen () && this->m_context.state.general.keepRunning) {
	    return;
	}
	m_renderContext->setPause (false);

	// account for paused duration in playlist timers
	const auto pausedNow = std::chrono::steady_clock::now ();
	const auto pausedDuration = pausedNow - this->m_pauseStart;

	for (auto& [_, playlist] : this->m_activePlaylists) {
	    if (!playlist.definition.settings.updateOnPause) {
		playlist.nextSwitch += pausedDuration;
		playlist.lastUpdate += pausedDuration;
	    }
	}

	this->m_isPaused = false;
    } else {
	// update g_Daytime
	time (&seconds);
	timeinfo = localtime (&seconds);
	g_Daytime = static_cast<float> ((timeinfo->tm_hour * 60) + timeinfo->tm_min) / (24.0f * 60.0f);

	// keep track of the previous frame's time
	g_TimeLast = g_Time;
	// calculate the current time value
	g_Time = m_videoDriver->getRenderTime ();
	// update audio recorder
	m_audioDriver->update ();
	// update the media source
	m_mediaSource->update ();
	// update input information
	m_videoDriver->getInputContext ().update ();
	// process driver events
	m_videoDriver->dispatchEventQueue ();

	if (m_videoDriver->closeRequested ()) {
	    sLog.out ("Stop requested by driver");
	    this->m_context.state.general.keepRunning = false;
	}

#if DEMOMODE
	// wait for a full render cycle before actually starting
	// this gives some extra time for video and web decoders to set themselves up
	// because of size changes
	if (m_videoDriver->getFrameCounter () > (uint32_t)this->m_context.settings.render.maximumFPS) {
	    if (!initialized) {
		width = this->m_renderContext->getWallpapers ().begin ()->second->getWidth ();
		height = this->m_renderContext->getWallpapers ().begin ()->second->getHeight ();
		pixels.reserve (width * height * 3);
		init_encoder ("output.webm", width, height);
		initialized = true;
	    }

	    glBindFramebuffer (
		GL_FRAMEBUFFER, this->m_renderContext->getWallpapers ().begin ()->second->getWallpaperFramebuffer ()
	    );

	    glPixelStorei (GL_PACK_ALIGNMENT, 1);
	    glReadPixels (0, 0, width, height, GL_RGB, GL_UNSIGNED_BYTE, pixels.data ());
	    write_video_frame (pixels.data ());
	    frame++;

	    // stop after the given framecount
	    if (frame >= FRAME_COUNT) {
		this->m_context.state.general.keepRunning = false;
	    }
	}
#endif /* DEMOMODE */
	// check for fullscreen windows and wait until there's none fullscreen
	if (this->m_fullScreenDetector->anythingFullscreen () && this->m_context.state.general.keepRunning) {
	    this->m_isPaused = true;
	    this->m_pauseStart = std::chrono::steady_clock::now ();

	    m_renderContext->setPause (true);
	    return;
	}
    }

    this->updatePlaylists ();

    if (!this->m_context.settings.screenshot.take || this->m_screenShotTaken == true) {
	return;
    }

    if (this->m_videoDriver->getFrameCounter () < this->m_nextFrameScreenshot) {
	return;
    }

    this->takeScreenshot (this->m_context.settings.screenshot.path);
    this->m_screenShotTaken = true;
}

void WallpaperApplication::cleanup () {
    sLog.out ("Stopping");

#if DEMOMODE
    close_encoder ();
#endif /* DEMOMODE */

    // Tear down glslang's process-wide state deterministically, while the process
    // is still fully alive. Letting the C++ runtime destroy this static singleton
    // at exit-time is unsafe: glslang keeps its own global init mutex as a separate
    // static object defined in another translation unit, and the standard does not
    // guarantee any destruction order between statics in different translation
    // units. If that mutex were destroyed first, glslang::FinalizeProcess() would
    // try to lock an already-destroyed std::mutex and throw std::system_error,
    // which is uncaught after main() returns and aborts the process.
    WallpaperEngine::Render::Shaders::GLSLContext::shutdown ();

    SDL_Quit ();
}

void WallpaperApplication::show () {
    setup ();

    if (this->m_context.settings.record.enabled) {
	this->recordFrameSequence ();
    } else {
	while (this->m_context.state.general.keepRunning) {
	    render ();
	}
    }

    cleanup ();
}

void WallpaperApplication::recordFrameSequence () {
    if (!this->m_context.settings.record.rawPath.empty ()) {
	this->recordFrameSequenceRaw ();
	return;
    }

    const auto& record = this->m_context.settings.record;

    std::error_code errorCode;
    std::filesystem::create_directories (record.directory, errorCode);

    if (errorCode) {
	sLog.exception ("Cannot create recording directory ", record.directory.string (), ": ", errorCode.message ());
    }

    const float dt = 1.0f / static_cast<float> (record.fps);
    const uint32_t totalFrames = record.seconds * record.fps;

    sLog.out (
	"Recording ", totalFrames, " frames (", record.seconds, "s @ ", record.fps, "fps) to ", record.directory.string ()
    );

    for (uint32_t frame = 0; frame < totalFrames && this->m_context.state.general.keepRunning; frame++) {
	// step the render clock deterministically, independent of wall-clock time,
	// so the resulting sequence is smooth and loopable
	g_TimeLast = static_cast<float> (frame) * dt;
	g_Time = static_cast<float> (frame + 1) * dt;

	this->m_mediaSource->update ();
	this->updatePlaylists ();

	// use the driver's normal frame dispatch (instead of calling update() per viewport
	// directly) so its internal frame counter advances; CWallpaper::render() skips
	// re-rendering the scene when the frame counter hasn't changed, which would
	// otherwise freeze the recording on the first frame
	this->m_videoDriver->dispatchEventQueue ();

	glFinish ();

	char filename[32];
	std::snprintf (filename, sizeof (filename), "frame_%05u.png", frame + 1);

	// Prefer the post-tonemap frame the driver captured from the default framebuffer right
	// before the swap (see GLFWOpenGLDriver::dispatchEventQueue). Falling back to
	// takeScreenshot() here would re-read the wallpaper's raw scene FBO, which for HDR
	// scenes is the pre-tonemap float composite - bypassing the final blit's tonemap shader
	// entirely and clamping overbright values straight to a flat 255 plateau instead of the
	// gradient actually shown on screen.
	if (const auto* recordedFrame = this->m_videoDriver->getRecordedFrameBuffer ()) {
	    this->writeRecordedFrame (record.directory / filename, *recordedFrame);
	} else {
	    // synchronous so every frame is flushed to disk before the process exits
	    this->takeScreenshot (record.directory / filename, false);
	}
    }

    this->m_context.state.general.keepRunning = false;
}

void WallpaperApplication::recordFrameSequenceRaw () {
    const auto& record = this->m_context.settings.record;

    const int width = this->m_renderContext->getOutput ().getFullWidth ();
    const int height = this->m_renderContext->getOutput ().getFullHeight ();
    const size_t rowBytes = static_cast<size_t> (width) * 4;
    const size_t frameBytes = rowBytes * static_cast<size_t> (height);

    const float dt = 1.0f / static_cast<float> (record.fps);
    const uint32_t totalFrames = record.seconds * record.fps;

    // machine-readable header, printed before the first frame so the consumer can size its
    // ffmpeg/rawvideo pipe ahead of time
    std::cout << "RECORD_RAW format=rgba width=" << width << " height=" << height << " fps=" << record.fps
	       << " frames=" << totalFrames << std::endl;
    std::cout.flush ();

    sLog.out (
	"Recording ", totalFrames, " raw frames (", record.seconds, "s @ ", record.fps, "fps) to ",
	record.rawPath.string ()
    );

    RawFrameWriter writer (record.rawPath, frameBytes);

    for (uint32_t frame = 0; frame < totalFrames && this->m_context.state.general.keepRunning; frame++) {
	// step the render clock deterministically, independent of wall-clock time,
	// so the resulting sequence is smooth and loopable
	g_TimeLast = static_cast<float> (frame) * dt;
	g_Time = static_cast<float> (frame + 1) * dt;

	this->m_mediaSource->update ();
	this->updatePlaylists ();

	// use the driver's normal frame dispatch (instead of calling update() per viewport
	// directly) so its internal frame counter advances; CWallpaper::render() skips
	// re-rendering the scene when the frame counter hasn't changed, which would
	// otherwise freeze the recording on the first frame
	this->m_videoDriver->dispatchEventQueue ();

	glFinish ();

	// Prefer the post-tonemap frame the driver captured from the default framebuffer right
	// before the swap (see GLFWOpenGLDriver::dispatchEventQueue); it is captured as RGBA
	// while record.rawPath is set (see the same function).
	const auto* recordedFrame = this->m_videoDriver->getRecordedFrameBuffer ();

	if (recordedFrame == nullptr || recordedFrame->size () != frameBytes) {
	    sLog.exception ("Raw recording requires the video driver's RGBA back-buffer capture");
	}

	const size_t slot = writer.acquire ();
	std::vector<uint8_t>& dest = writer.buffer (slot);

	// the driver captures the default framebuffer bottom-up (OpenGL row order); flip to
	// top-down row order to match rawvideo/ffmpeg expectations
	for (int y = 0; y < height; y++) {
	    std::memcpy (
		&dest[static_cast<size_t> (y) * rowBytes],
		&(*recordedFrame)[static_cast<size_t> (height - y - 1) * rowBytes], rowBytes
	    );
	}

	writer.submit (slot);
    }

    writer.finish ();

    this->m_context.state.general.keepRunning = false;
}

void WallpaperApplication::update (Render::Drivers::Output::OutputViewport* viewport) {
    // render the scene
    m_renderContext->render (viewport);
}

void WallpaperApplication::signal (int signal) {
    sLog.out ("Stop requested by signal ", signal);
    this->m_context.state.general.keepRunning = false;
}

const std::map<std::string, ProjectUniquePtr>& WallpaperApplication::getBackgrounds () const {
    return this->m_backgrounds;
}

ApplicationContext& WallpaperApplication::getContext () const { return this->m_context; }

const WallpaperEngine::Render::Drivers::Output::Output& WallpaperApplication::getOutput () const {
    return this->m_renderContext->getOutput ();
}

void WallpaperApplication::setDestinationFramebuffer (GLuint framebuffer) {
    this->m_destinationFramebuffer = framebuffer;
    // Update all wallpapers with the new destination framebuffer
    for (const auto& [screen, wallpaper] : this->m_renderContext->getWallpapers ()) {
	wallpaper->setDestinationFramebuffer (framebuffer);
    };
}

GLuint WallpaperApplication::getDestinationFramebuffer () const { return this->m_destinationFramebuffer; }
