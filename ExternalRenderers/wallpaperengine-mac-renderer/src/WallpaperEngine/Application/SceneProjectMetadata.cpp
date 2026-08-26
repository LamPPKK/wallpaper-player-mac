#include "SceneProjectMetadata.h"

#include <cerrno>
#include <cstring>
#include <stdexcept>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

using WallpaperEngine::Data::JSON::JSON;

namespace WallpaperEngine::Application::SceneProjectMetadata {
namespace {
constexpr std::uintmax_t maximumProjectMetadataBytes = 1024 * 1024;

class FileDescriptor {
public:
    explicit FileDescriptor (int value) : m_value (value) { }
    FileDescriptor (const FileDescriptor&) = delete;
    FileDescriptor& operator= (const FileDescriptor&) = delete;
    ~FileDescriptor () {
	if (m_value >= 0) {
	    ::close (m_value);
	}
    }

    [[nodiscard]] int get () const { return m_value; }

private:
    int m_value;
};

JSON synthesizedMetadata (const std::filesystem::path& backgroundPath) {
    auto title = backgroundPath.lexically_normal ().filename ().string ();
    if (title.empty ()) {
	title = "Imported Scene";
    }

    return JSON {
	{ "title", title },
	{ "type", "scene" },
	{ "file", "scene.json" },
    };
}
}

JSON loadForExplicitPackage (const std::filesystem::path& backgroundPath) {
    const auto metadataPath = backgroundPath / "project.json";
    const auto rawDescriptor = ::open (metadataPath.c_str (), O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (rawDescriptor < 0 && errno == ENOENT) {
	return synthesizedMetadata (backgroundPath);
    }
    if (rawDescriptor < 0 && errno == ELOOP) {
	throw std::runtime_error ("project.json for an explicit Scene package must be a regular file");
    }
    if (rawDescriptor < 0) {
	throw std::runtime_error (
	    "Cannot open project.json for an explicit Scene package: " + std::string (std::strerror (errno))
	);
    }
    const FileDescriptor descriptor (rawDescriptor);

    struct stat metadataStat { };
    if (::fstat (descriptor.get (), &metadataStat) != 0) {
	throw std::runtime_error (
	    "Cannot inspect project.json for an explicit Scene package: " + std::string (std::strerror (errno))
	);
    }
    if (!S_ISREG (metadataStat.st_mode)) {
	throw std::runtime_error ("project.json for an explicit Scene package must be a regular file");
    }
    if (metadataStat.st_size <= 0
	|| static_cast<std::uintmax_t> (metadataStat.st_size) > maximumProjectMetadataBytes) {
	throw std::runtime_error ("project.json for an explicit Scene package must be between 1 byte and 1 MiB");
    }

    std::string contents (static_cast<std::size_t> (metadataStat.st_size), '\0');
    std::size_t offset = 0;
    while (offset < contents.size ()) {
	const auto count = ::pread (
	    descriptor.get (),
	    contents.data () + offset,
	    contents.size () - offset,
	    static_cast<off_t> (offset)
	);
	if (count < 0 && errno == EINTR) {
	    continue;
	}
	if (count <= 0) {
	    throw std::runtime_error ("Cannot read project.json for an explicit Scene package");
	}
	offset += static_cast<std::size_t> (count);
    }

    auto metadata = JSON::parse (contents);
    if (!metadata.is_object ()) {
	throw std::runtime_error ("project.json for an explicit Scene package must contain a JSON object");
    }

    // The explicit package is mounted at the project root. Its authored Scene
    // document is scene.json; pointing ProjectParser at scene.pkg would ask the
    // JSON parser to parse the PKGV container bytes themselves.
    metadata["file"] = "scene.json";
    return metadata;
}

} // namespace WallpaperEngine::Application::SceneProjectMetadata
