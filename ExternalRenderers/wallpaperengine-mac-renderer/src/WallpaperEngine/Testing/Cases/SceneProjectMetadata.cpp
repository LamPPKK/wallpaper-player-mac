#include <catch2/catch_test_macros.hpp>

#include <chrono>
#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <string>

#include "WallpaperEngine/Application/SceneProjectMetadata.h"

using WallpaperEngine::Application::SceneProjectMetadata::loadForExplicitPackage;

namespace {
class TemporaryDirectory {
public:
    explicit TemporaryDirectory (const std::string& name) {
	const auto suffix = std::chrono::steady_clock::now ().time_since_epoch ().count ();
	path = std::filesystem::temp_directory_path () / (name + "-" + std::to_string (suffix));
	std::filesystem::create_directories (path);
    }

    ~TemporaryDirectory () {
	std::error_code ignored;
	std::filesystem::remove_all (path, ignored);
    }

    std::filesystem::path path;
};

void writeText (const std::filesystem::path& path, const std::string& contents) {
    std::ofstream output (path, std::ios::binary);
    REQUIRE (output.is_open ());
    output << contents;
    REQUIRE (output.good ());
}
}

TEST_CASE ("Explicit standalone Scene packages synthesize project metadata") {
    TemporaryDirectory project ("background-engine-standalone-scene");

    const auto metadata = loadForExplicitPackage (project.path);

    CHECK (metadata.at ("title").get<std::string> () == project.path.filename ().string ());
    CHECK (metadata.at ("type").get<std::string> () == "scene");
    CHECK (metadata.at ("file").get<std::string> () == "scene.json");
}

TEST_CASE ("Explicit Scene packages preserve metadata while selecting the packaged document") {
    TemporaryDirectory project ("background-engine-metadata-scene");
    writeText (
	project.path / "project.json",
	R"({"title":"Authored title","type":"scene","file":"scene.pkg","workshopid":"123","general":{"supportsaudioprocessing":true}})"
    );

    const auto metadata = loadForExplicitPackage (project.path);

    CHECK (metadata.at ("title").get<std::string> () == "Authored title");
    CHECK (metadata.at ("type").get<std::string> () == "scene");
    CHECK (metadata.at ("file").get<std::string> () == "scene.json");
    CHECK (metadata.at ("workshopid").get<std::string> () == "123");
    CHECK (metadata.at ("general").at ("supportsaudioprocessing").get<bool> ());
}

TEST_CASE ("Explicit Scene metadata rejects symbolic links") {
    TemporaryDirectory project ("background-engine-symlink-scene");
    TemporaryDirectory outside ("background-engine-outside-scene");
    writeText (outside.path / "project.json", R"({"title":"Outside","type":"scene","file":"scene.pkg"})");
    std::filesystem::create_symlink (outside.path / "project.json", project.path / "project.json");

    CHECK_THROWS_AS (loadForExplicitPackage (project.path), std::runtime_error);
}

TEST_CASE ("Explicit Scene metadata rejects malformed JSON instead of hiding corruption") {
    TemporaryDirectory project ("background-engine-malformed-scene");
    writeText (project.path / "project.json", "{broken");

    CHECK_THROWS (loadForExplicitPackage (project.path));
}

TEST_CASE ("Explicit Scene metadata rejects empty and oversized files") {
    TemporaryDirectory emptyProject ("background-engine-empty-metadata-scene");
    writeText (emptyProject.path / "project.json", "");
    CHECK_THROWS_AS (loadForExplicitPackage (emptyProject.path), std::runtime_error);

    TemporaryDirectory oversizedProject ("background-engine-oversized-metadata-scene");
    writeText (oversizedProject.path / "project.json", std::string ((1024 * 1024) + 1, 'x'));
    CHECK_THROWS_AS (loadForExplicitPackage (oversizedProject.path), std::runtime_error);
}

TEST_CASE ("Explicit Scene metadata rejects non-regular files") {
    TemporaryDirectory project ("background-engine-directory-metadata-scene");
    std::filesystem::create_directory (project.path / "project.json");

    CHECK_THROWS_AS (loadForExplicitPackage (project.path), std::runtime_error);
}
