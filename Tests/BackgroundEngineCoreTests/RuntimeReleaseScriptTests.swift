import Foundation
import XCTest

final class RuntimeReleaseScriptTests: XCTestCase {
    func testReleaseScriptsDoNotRequireRipgrepAndActionsUsePinnedCurrentRuntimes() throws {
        let scriptsRoot = URL(filePath: testRepositoryPath("Scripts"))
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: scriptsRoot,
            includingPropertiesForKeys: nil
        ))
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "sh" {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            XCTAssertNil(
                source.range(of: #"\brg\b"#, options: .regularExpression),
                "\(fileURL.lastPathComponent) must run on a clean GitHub macOS runner without ripgrep."
            )
        }
        for scriptPath in [
            "Scripts/build-ffmpeg-runtime.sh",
            "Scripts/bundle-renderer-runtime.sh",
            "Scripts/merge-ffmpeg-runtime.sh",
            "Scripts/merge-renderer-runtime.sh"
        ] {
            let source = try String(repositoryFile: scriptPath)
            XCTAssertTrue(source.contains("be_resolve_new_output"), "\(scriptPath) must refuse unsafe/existing output.")
        }

        for workflowPath in [".github/workflows/ci.yml", ".github/workflows/release.yml"] {
            let workflow = try String(repositoryFile: workflowPath)
            XCTAssertTrue(workflow.contains("./Scripts/package-app.sh"))
            XCTAssertTrue(workflow.contains("./Scripts/verify-package-metadata.sh"))
            XCTAssertTrue(workflow.contains("./Scripts/verify-source-archive.sh"))
            XCTAssertTrue(workflow.contains("./Scripts/verify-renderer-source-archive.sh"))
            XCTAssertTrue(workflow.contains("actions/checkout@v7.0.1"))
            XCTAssertTrue(workflow.contains("actions/upload-artifact@v7.0.1"))
            XCTAssertTrue(workflow.contains("actions/download-artifact@v8.0.1"))
            XCTAssertTrue(workflow.contains("brew install gnupg nasm"))
            XCTAssertTrue(workflow.contains("chmod 755 ffmpeg-runtime/MediaTools/ffmpeg ffmpeg-runtime/MediaTools/ffprobe"))
            XCTAssertTrue(workflow.contains("-c:v mpeg4 -tag:v mp4v"))
            XCTAssertTrue(workflow.contains("^codec_name=mpeg4$"))
            XCTAssertTrue(workflow.contains("^codec_tag_string=mp4v$"))
            for capability in [
                "h264_videotoolbox",
                "mpeg4",
                "aac",
                "ogg",
                "matroska,webm",
                "avi",
                "vorbis opus theora vp8 vp9 mpeg4",
                "mov"
            ] {
                XCTAssertTrue(
                    workflow.contains(capability),
                    "\(workflowPath) must gate the packaged media capability \(capability)."
                )
            }
            XCTAssertTrue(workflow.contains("Contents/MacOS/be-cli\" -verify_arch arm64 x86_64"))
        }

        let ffmpegBuildScript = try String(repositoryFile: "Scripts/build-ffmpeg-runtime.sh")
        XCTAssertTrue(ffmpegBuildScript.contains("be_require_tools nasm"))
        XCTAssertTrue(ffmpegBuildScript.contains("--retry-all-errors"))
        XCTAssertTrue(ffmpegBuildScript.contains("--retry 5"))
        XCTAssertTrue(ffmpegBuildScript.contains("--retry-max-time 300"))
        XCTAssertTrue(ffmpegBuildScript.contains("--enable-protocol=file,pipe,fd"))
        XCTAssertFalse(ffmpegBuildScript.contains("--enable-protocol=file,pipe,fd,concat"))
        for workflowPath in [".github/workflows/ci.yml", ".github/workflows/release.yml"] {
            let workflow = try String(repositoryFile: workflowPath)
            XCTAssertTrue(
                workflow.contains("(concat|http|https|tcp|udp)"),
                "\(workflowPath) must reject playlist and network protocols from packaged FFmpeg."
            )
        }

        let packageScript = try String(repositoryFile: "Scripts/package-app.sh")
        XCTAssertTrue(packageScript.contains("for binary in BackgroundEngine be-cli BackgroundEngineSteamCMDRunner"))
        XCTAssertTrue(packageScript.contains("lipo \"$BIN_DIR/$binary\" -verify_arch arm64 x86_64"))
        XCTAssertTrue(packageScript.contains("Scripts/embed-app-runtimes.sh"))
        XCTAssertTrue(packageScript.contains("--refresh-after-signing"))

        let embedRuntimeScript = try String(repositoryFile: "Scripts/embed-app-runtimes.sh")
        XCTAssertTrue(embedRuntimeScript.contains("--refresh-after-signing"))

        let projectSpec = try String(repositoryFile: "project.yml")
        XCTAssertTrue(projectSpec.contains("postBuildScripts:"))
        XCTAssertTrue(projectSpec.contains("$SRCROOT/Scripts/embed-app-runtimes-xcode.sh"))
        XCTAssertFalse(projectSpec.contains("${SRCROOT}/Scripts/embed-app-runtimes-xcode.sh"))
        XCTAssertTrue(projectSpec.contains("BACKGROUND_ENGINE_FFMPEG_RUNTIME_DIR"))
        XCTAssertTrue(projectSpec.contains("BACKGROUND_ENGINE_SCENE_RENDERER_RUNTIME_DIR"))
        XCTAssertTrue(projectSpec.contains("ENABLE_USER_SCRIPT_SANDBOXING: NO"))

        let continuousIntegration = try String(repositoryFile: ".github/workflows/ci.yml")
        XCTAssertTrue(continuousIntegration.contains("Archive self-contained Universal Xcode app"))
        XCTAssertTrue(continuousIntegration.contains("Verify Xcode Archive runtime closure"))
        XCTAssertTrue(continuousIntegration.contains("BACKGROUND_ENGINE_FFMPEG_RUNTIME_DIR="))
        XCTAssertTrue(continuousIntegration.contains("BACKGROUND_ENGINE_SCENE_RENDERER_RUNTIME_DIR="))
        XCTAssertTrue(continuousIntegration.contains("Background Engine.xcarchive"))

        let rendererDependencyScript = try String(
            repositoryFile: "Scripts/install-renderer-dependencies.sh"
        )
        XCTAssertTrue(
            rendererDependencyScript.contains("229d435d9fc7d166b417e94ce66db01d6b34cf97")
        )
        XCTAssertTrue(
            rendererDependencyScript.contains("0942cac2eda7648d4857f4e5da60f1de303b6818")
        )
        XCTAssertTrue(rendererDependencyScript.contains("BREW_VERSION=\"6.0.19\""))
        XCTAssertTrue(rendererDependencyScript.contains("refs/tags/$BREW_VERSION:refs/tags/$BREW_VERSION"))
        XCTAssertTrue(rendererDependencyScript.contains("Pinned Homebrew/brew did not report version $BREW_VERSION"))
        XCTAssertTrue(rendererDependencyScript.contains("brew info --json=v2 homebrew/core/openssl@3"))
        XCTAssertTrue(rendererDependencyScript.contains("--union --topological"))
        XCTAssertFalse(rendererDependencyScript.contains("--recursive"))
        XCTAssertTrue(rendererDependencyScript.contains("DEPS_ARCH=\"arm\""))
        XCTAssertTrue(rendererDependencyScript.contains("DEPS_ARCH=\"intel\""))
        XCTAssertTrue(rendererDependencyScript.contains("--bottle-tag \"$BOTTLE_TAG\""))
        XCTAssertTrue(rendererDependencyScript.contains("qualified_formula=\"homebrew/core/$formula\""))
        XCTAssertTrue(rendererDependencyScript.contains("brew uninstall --force --ignore-dependencies"))
        XCTAssertFalse(rendererDependencyScript.contains("brew reinstall"))
        let singleKegStart = try XCTUnwrap(rendererDependencyScript.range(of: "    1)\n"))
        let multipleKegStart = try XCTUnwrap(
            rendererDependencyScript.range(
                of: "    *)\n",
                range: singleKegStart.upperBound..<rendererDependencyScript.endIndex
            )
        )
        let singleKegBranch = rendererDependencyScript[
            singleKegStart.upperBound..<multipleKegStart.lowerBound
        ]
        let singleKegUninstall = try XCTUnwrap(singleKegBranch.range(of: "brew uninstall"))
        let singleKegInstall = try XCTUnwrap(singleKegBranch.range(of: "brew install"))
        XCTAssertLessThan(singleKegUninstall.lowerBound, singleKegInstall.lowerBound)
        XCTAssertTrue(rendererDependencyScript.contains("unset HOMEBREW_FORBID_PACKAGES_FROM_PATHS"))
        XCTAssertTrue(rendererDependencyScript.contains("export HOMEBREW_DEVELOPER=1"))
        XCTAssertFalse(rendererDependencyScript.contains("HOMEBREW_INTERNAL_ALLOW_PACKAGES_FROM_PATHS"))
        XCTAssertFalse(rendererDependencyScript.contains(".built_on.os_version"))
        let localBottleOptIn = try XCTUnwrap(
            rendererDependencyScript.range(of: "export HOMEBREW_DEVELOPER=1")
        )
        let localBottleInstall = try XCTUnwrap(
            rendererDependencyScript.range(of: "brew install --no-ask --formula \"$bottle\"")
        )
        XCTAssertLessThan(localBottleOptIn.lowerBound, localBottleInstall.lowerBound)
        XCTAssertTrue(rendererDependencyScript.contains("be_homebrew_installed_keg_count \"$formula\""))
        XCTAssertTrue(rendererDependencyScript.contains("be_homebrew_installation_matches \"$expected_version\""))
        XCTAssertTrue(rendererDependencyScript.contains("EXPECTED_STABLE_VERSIONS+=(\"$stable_version\")"))
        XCTAssertTrue(
            rendererDependencyScript.contains(
                "be_homebrew_receipt_matches \\\n      \"$RECEIPT_ARCH\" \"$expected_stable_version\" \"$CORE_REF\""
            )
        )
        XCTAssertFalse(rendererDependencyScript.contains("info --json=v2 --installed"))
        XCTAssertTrue(rendererDependencyScript.contains("QUALIFIED_ALL+=(\"homebrew/core/$formula\")"))
        XCTAssertTrue(rendererDependencyScript.contains("brew info --json=v2 \"${QUALIFIED_ALL[@]}\""))
        XCTAssertTrue(rendererDependencyScript.contains("shasum -a 256 \"$bottle\""))
        XCTAssertTrue(rendererDependencyScript.contains("RUNNER_ENVIRONMENT"))
        XCTAssertTrue(
            rendererDependencyScript.contains(
                "be_checkout_pinned_git_commit \"$CORE_REPOSITORY\" \"$CORE_REF\" \"homebrew/core\""
            )
        )
        XCTAssertTrue(
            rendererDependencyScript.contains(
                "be_checkout_pinned_git_commit \"$BREW_REPOSITORY\" \"$BREW_REF\" \"Homebrew/brew\""
            )
        )
        XCTAssertTrue(rendererDependencyScript.contains("homebrew-brew\\t%s"))
        let commonRuntimeScript = try String(repositoryFile: "Scripts/runtime-script-common.sh")
        XCTAssertTrue(commonRuntimeScript.contains("stash push --include-untracked"))
        XCTAssertTrue(commonRuntimeScript.contains("Refusing to alter a dirty local $description checkout"))
        XCTAssertFalse(commonRuntimeScript.contains("git reset --hard"))
        XCTAssertFalse(commonRuntimeScript.contains("git clean"))
        XCTAssertFalse(rendererDependencyScript.contains("brew upgrade"))
        XCTAssertTrue(rendererDependencyScript.contains("assert_linked ffmpeg 9.0.1"))
        XCTAssertTrue(rendererDependencyScript.contains("assert_linked mpv 0.41.0_8"))
        XCTAssertTrue(rendererDependencyScript.contains("assert_linked pkgconf 3.0.5"))
        XCTAssertTrue(rendererDependencyScript.contains("deployment-target\\tmacos-14"))
        XCTAssertTrue(rendererDependencyScript.contains("renderer-bottle-lock-records.sh"))
        XCTAssertTrue(rendererDependencyScript.contains("renderer-formula-lock-records.sh"))
        XCTAssertTrue(rendererDependencyScript.contains("verify-renderer-dependency-lock.sh"))

        let rendererBundleScript = try String(repositoryFile: "Scripts/bundle-renderer-runtime.sh")
        XCTAssertTrue(
            rendererBundleScript.contains(
                "install_name_tool -id '@executable_path/lib/libSDL3.dylib'"
            )
        )
        XCTAssertFalse(rendererBundleScript.contains("ln -s libSDL3.0.dylib"))
        XCTAssertTrue(rendererBundleScript.contains("[arm64|x86_64]"))
        XCTAssertTrue(rendererBundleScript.contains("EXPECTED_ARCHITECTURE"))
        let localRendererBuild = try String(repositoryFile: "Scripts/build-renderer.sh")
        XCTAssertTrue(localRendererBuild.contains("\"$BUILD-arm64/runtime\" arm64"))
        XCTAssertTrue(localRendererBuild.contains("\"$BUILD-x86_64/runtime\" x86_64"))
        let rendererMergeScript = try String(repositoryFile: "Scripts/merge-renderer-runtime.sh")
        XCTAssertTrue(rendererMergeScript.contains("\"$STAGING/background-engine-scene-renderer\" --help"))
        for workflowPath in [".github/workflows/ci.yml", ".github/workflows/release.yml"] {
            let workflow = try String(repositoryFile: workflowPath)
            XCTAssertTrue(workflow.contains("./Scripts/install-renderer-dependencies.sh"))
            XCTAssertTrue(workflow.contains("-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0"))
            XCTAssertTrue(workflow.contains("${{ matrix.arch }} \"$RUNNER_TEMP/renderer-homebrew-lock.tsv\""))
            XCTAssertTrue(workflow.contains("renderer-build-manifest.tsv"))
        }

        let rendererCMake = try String(
            repositoryFile: "ExternalRenderers/wallpaperengine-mac-renderer/CMakeLists.txt"
        )
        let deploymentPolicy = try XCTUnwrap(
            rendererCMake.range(of: "BACKGROUND_ENGINE_MAX_MACOS_DEPLOYMENT_TARGET")
        )
        let projectInitialization = try XCTUnwrap(
            rendererCMake.range(of: "project(linux-wallpaperengine)")
        )
        XCTAssertLessThan(
            deploymentPolicy.lowerBound,
            projectInitialization.lowerBound,
            "The deployment target must be set before CMake initializes compilers and vendored projects."
        )
        XCTAssertNotNil(
            rendererCMake.range(
                of: "CMAKE_OSX_DEPLOYMENT_TARGET VERSION_GREATER",
                range: rendererCMake.startIndex..<projectInitialization.lowerBound
            ),
            "An explicit future deployment target must fail before project initialization."
        )
        XCTAssertNotNil(
            rendererCMake.range(
                of: "CMAKE_OSX_DEPLOYMENT_TARGET VERSION_GREATER",
                range: projectInitialization.upperBound..<rendererCMake.endIndex
            ),
            "A toolchain file must not be able to raise the target during project initialization."
        )
        XCTAssertTrue(
            rendererCMake.contains(
                "CACHE STRING \"Minimum macOS version for the Background Engine Scene renderer\" FORCE"
            ),
            "An explicitly empty CMake cache entry must still resolve to the macOS 14 default."
        )
        XCTAssertTrue(rendererCMake.contains("BackgroundEngineRendererProvenance.pl"))
        XCTAssertTrue(rendererCMake.contains("BackgroundEngineRendererProvenance.h.in"))
        let rendererMain = try String(
            repositoryFile: "ExternalRenderers/wallpaperengine-mac-renderer/src/main.cpp"
        )
        XCTAssertTrue(rendererMain.contains("--background-engine-build-info"))
        XCTAssertTrue(rendererMain.contains("__TEXT,__be_provenance"))
        let rendererBuildVersion = try String(
            repositoryFile: "ExternalRenderers/wallpaperengine-mac-renderer/.background-engine-build-version"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let sceneVideoRenderer = try String(repositoryFile: "Sources/BackgroundEngineApp/SceneVideoRenderer.swift")
        XCTAssertTrue(
            sceneVideoRenderer.contains("static let rendererVersion = \"\(rendererBuildVersion)\""),
            "The app runtime gate and renderer provenance must use the same build version."
        )

    }

    func testReleaseMetadataResolverDefaultsDispatchAndSafelyDerivesTagPush() throws {
        let script = testRepositoryPath("Scripts/resolve-release-metadata.sh")
        let dispatch = try run(
            "/bin/bash",
            arguments: [
                script,
                "workflow_dispatch", "branch", "main", "",
                "v0.2.0-alpha.1-build.23", "", ""
            ]
        )
        XCTAssertEqual(dispatch.status, 0, dispatch.standardError)
        XCTAssertEqual(
            Set(dispatch.standardOutput.split(whereSeparator: \.isNewline).map(String.init)),
            [
                "release_tag=v0.2.0-alpha.1-build.23",
                "marketing_version=0.2.0-alpha.1",
                "build_number=23"
            ]
        )

        let tagPush = try run(
            "/bin/bash",
            arguments: [
                script,
                "push", "tag", "v0.3.0-beta.2", "true", "", "", ""
            ]
        )
        XCTAssertEqual(tagPush.status, 0, tagPush.standardError)
        XCTAssertTrue(tagPush.standardOutput.contains("release_tag=v0.3.0-beta.2"))
        XCTAssertTrue(tagPush.standardOutput.contains("marketing_version=0.3.0-beta.2"))
        XCTAssertTrue(tagPush.standardOutput.contains("build_number=23"))
    }

    func testLivelyResourceBundleVerifierAcceptsBothSwiftPMLayoutsAndRejectsUnsafeShapes() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = testRepositoryPath("Scripts/verify-lively-resource-bundle.sh")
        let identifiers = [
            "lively-the-hill",
            "lively-periodic-table",
            "lively-parallax",
            "lively-music-tv",
            "lively-depth-observatory",
            "lively-chromatic-fluids"
        ]

        func createCollection(in bundle: URL, macOSLayout: Bool) throws -> URL {
            let collection = macOSLayout
                ? bundle.appending(path: "Contents/Resources/LivelyWallpapers")
                : bundle.appending(path: "LivelyWallpapers")
            try FileManager.default.createDirectory(at: collection, withIntermediateDirectories: true)
            try Data("{}\n".utf8).write(to: collection.appending(path: "catalog.json"))
            for identifier in identifiers {
                try FileManager.default.createDirectory(
                    at: collection.appending(path: identifier),
                    withIntermediateDirectories: false
                )
            }
            return collection
        }

        for macOSLayout in [false, true] {
            let bundle = root.appending(path: macOSLayout ? "Universal.bundle" : "Debug.bundle")
            let collection = try createCollection(in: bundle, macOSLayout: macOSLayout)
            let result = try run("/bin/bash", arguments: [script, bundle.path])
            XCTAssertEqual(result.status, 0, result.standardError)
            XCTAssertEqual(
                result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
                collection.path
            )
        }

        let ambiguousBundle = root.appending(path: "Ambiguous.bundle")
        _ = try createCollection(in: ambiguousBundle, macOSLayout: false)
        _ = try createCollection(in: ambiguousBundle, macOSLayout: true)
        let ambiguous = try run("/bin/bash", arguments: [script, ambiguousBundle.path])
        XCTAssertNotEqual(ambiguous.status, 0)
        XCTAssertTrue(ambiguous.standardError.contains("exactly one supported"))

        let extraBundle = root.appending(path: "Extra.bundle")
        let extraCollection = try createCollection(in: extraBundle, macOSLayout: false)
        try FileManager.default.createDirectory(
            at: extraCollection.appending(path: "unexpected-wallpaper"),
            withIntermediateDirectories: false
        )
        let extra = try run("/bin/bash", arguments: [script, extraBundle.path])
        XCTAssertNotEqual(extra.status, 0)
        XCTAssertTrue(extra.standardError.contains("exactly six"))

        let extraFileBundle = root.appending(path: "ExtraFile.bundle")
        let extraFileCollection = try createCollection(in: extraFileBundle, macOSLayout: true)
        try Data("unexpected\n".utf8).write(
            to: extraFileCollection.appending(path: "unexpected.txt")
        )
        let extraFile = try run("/bin/bash", arguments: [script, extraFileBundle.path])
        XCTAssertNotEqual(extraFile.status, 0)
        XCTAssertTrue(extraFile.standardError.contains("only its catalog"))

        let missingBundle = root.appending(path: "Missing.bundle")
        let missingCollection = try createCollection(in: missingBundle, macOSLayout: false)
        try FileManager.default.removeItem(
            at: missingCollection.appending(path: "lively-periodic-table")
        )
        let missing = try run("/bin/bash", arguments: [script, missingBundle.path])
        XCTAssertNotEqual(missing.status, 0)
        XCTAssertTrue(missing.standardError.contains("lively-periodic-table"))

        let symlinkBundle = root.appending(path: "Symlink.bundle")
        let symlinkCollection = try createCollection(in: symlinkBundle, macOSLayout: false)
        let unsafeTarget = root.appending(path: "unsafe-license.txt")
        try Data("unsafe\n".utf8).write(to: unsafeTarget)
        try FileManager.default.createSymbolicLink(
            at: symlinkCollection.appending(path: "unsafe-link"),
            withDestinationURL: unsafeTarget
        )
        let symlink = try run("/bin/bash", arguments: [script, symlinkBundle.path])
        XCTAssertNotEqual(symlink.status, 0)
        XCTAssertTrue(symlink.standardError.contains("unsafe filesystem entry"))
    }

    func testReleaseMetadataResolverRejectsUnsafeOrAmbiguousInputs() throws {
        let script = testRepositoryPath("Scripts/resolve-release-metadata.sh")
        let cases: [([String], String)] = [
            (
                ["push", "branch", "main", "true", "", "", ""],
                "must target a tag"
            ),
            (
                ["push", "tag", "v0.2.0-alpha.1", "false", "", "", ""],
                "moved, deleted, or pre-existing tag push"
            ),
            (
                ["workflow_dispatch", "branch", "main", "", "", "", ""],
                "invalid release tag"
            ),
            (
                ["workflow_dispatch", "branch", "main", "", "v0.2.0/alpha", "", ""],
                "invalid release tag"
            ),
            (
                ["workflow_dispatch", "branch", "main", "", "vfixture", "main", "9"],
                "invalid marketing version"
            ),
            (
                ["workflow_dispatch", "branch", "main", "", "vfixture", "0.2.0-alpha.1", "9.1"],
                "invalid build number"
            )
        ]

        for testCase in cases {
            let result = try run("/bin/bash", arguments: [script] + testCase.0)
            XCTAssertNotEqual(result.status, 0, "Unexpectedly accepted: \(testCase.0)")
            XCTAssertTrue(result.standardError.contains(testCase.1), result.standardError)
        }
    }

    func testReleaseDestinationVerifierFailsClosedForExistingOrUnknownState() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = root.appending(path: "tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let git = tools.appending(path: "git")
        let gh = tools.appending(path: "gh")
        try Data(
            #"""
            #!/bin/bash
            case "$1" in
              check-ref-format) exit 0 ;;
              ls-remote)
                case "$MOCK_REMOTE_TAG" in
                  existing) printf '%s\n' 'fixture refs/tags/vfixture'; exit 0 ;;
                  absent) exit 2 ;;
                  error) exit 128 ;;
                esac
                ;;
            esac
            exit 64
            """#.utf8
        ).write(to: git)
        try Data(
            #"""
            #!/bin/bash
            case "$MOCK_RELEASE" in
              absent) exit 0 ;;
              existing) printf '%s\n' 'R_fixture'; exit 0 ;;
              error) printf '%s\n' 'API unavailable' >&2; exit 1 ;;
            esac
            exit 64
            """#.utf8
        ).write(to: gh)
        for tool in [git, gh] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: tool.path
            )
        }

        func verify(event: String, remoteTag: String, release: String) throws -> ProcessResult {
            try run(
                "/usr/bin/env",
                arguments: [
                    "PATH=\(tools.path):/usr/bin:/bin",
                    "MOCK_REMOTE_TAG=\(remoteTag)",
                    "MOCK_RELEASE=\(release)",
                    "/bin/bash",
                    testRepositoryPath("Scripts/verify-release-destination.sh"),
                    event,
                    "vfixture",
                    "LamPPKK/wallpaper-player-mac"
                ]
            )
        }

        let dispatch = try verify(event: "workflow_dispatch", remoteTag: "absent", release: "absent")
        XCTAssertEqual(dispatch.status, 0, dispatch.standardError)
        XCTAssertTrue(dispatch.standardOutput.contains("release destination is unused"))

        let tagPush = try verify(event: "push", remoteTag: "existing", release: "absent")
        XCTAssertEqual(tagPush.status, 0, tagPush.standardError)
        XCTAssertTrue(tagPush.standardOutput.contains("pushed tag has no existing GitHub Release"))

        let existingTag = try verify(
            event: "workflow_dispatch",
            remoteTag: "existing",
            release: "absent"
        )
        XCTAssertNotEqual(existingTag.status, 0)
        XCTAssertTrue(existingTag.standardError.contains("refusing to move or overwrite"))

        let missingPushedTag = try verify(event: "push", remoteTag: "absent", release: "absent")
        XCTAssertNotEqual(missingPushedTag.status, 0)
        XCTAssertTrue(missingPushedTag.standardError.contains("Pushed release tag is missing"))

        let existingRelease = try verify(event: "push", remoteTag: "existing", release: "existing")
        XCTAssertNotEqual(existingRelease.status, 0)
        XCTAssertTrue(existingRelease.standardError.contains("refusing to update it implicitly"))

        let unknownRemote = try verify(event: "workflow_dispatch", remoteTag: "error", release: "absent")
        XCTAssertNotEqual(unknownRemote.status, 0)
        XCTAssertTrue(unknownRemote.standardError.contains("Unable to verify whether release tag exists"))

        let unknownRelease = try verify(event: "push", remoteTag: "existing", release: "error")
        XCTAssertNotEqual(unknownRelease.status, 0)
        XCTAssertTrue(unknownRelease.standardError.contains("API unavailable"))
    }

    func testSourceArchiveVerifierRejectsPersonalXcodeState() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = testRepositoryPath("Scripts/verify-source-archive.sh")

        let cleanRoot = root.appending(path: "clean")
        let cleanProject = cleanRoot.appending(path: "background-engine")
        try FileManager.default.createDirectory(at: cleanProject, withIntermediateDirectories: true)
        try Data("clean source".utf8).write(to: cleanProject.appending(path: "README.md"))
        let cleanArchive = root.appending(path: "clean.tar.gz")
        try requireSuccess(
            "/usr/bin/tar",
            arguments: ["-czf", cleanArchive.path, "-C", cleanRoot.path, "background-engine"]
        )

        let cleanResult = try run("/bin/bash", arguments: [script, cleanArchive.path])
        XCTAssertEqual(cleanResult.status, 0, cleanResult.standardError)
        XCTAssertTrue(cleanResult.standardOutput.contains("contains no personal Xcode state"))

        let dirtyRoot = root.appending(path: "dirty")
        let personalState = dirtyRoot.appending(
            path: "background-engine/.swiftpm/xcode/xcuserdata/tester.xcuserdatad/xcschemes/xcschememanagement.plist"
        )
        try FileManager.default.createDirectory(
            at: personalState.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("personal state".utf8).write(to: personalState)
        let dirtyArchive = root.appending(path: "dirty.tar.gz")
        try requireSuccess(
            "/usr/bin/tar",
            arguments: ["-czf", dirtyArchive.path, "-C", dirtyRoot.path, "background-engine"]
        )

        let dirtyResult = try run("/bin/bash", arguments: [script, dirtyArchive.path])
        XCTAssertNotEqual(dirtyResult.status, 0)
        XCTAssertTrue(dirtyResult.standardError.contains("Source archive contains personal Xcode state"))
        XCTAssertTrue(dirtyResult.standardError.contains("tester.xcuserdatad"))
    }

    func testRendererSourceArchiveVerifierRejectsProvenanceDrift() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = testRepositoryPath("Scripts/verify-renderer-source-archive.sh")

        func makeSource(in parent: URL, payload: String) throws -> URL {
            let source = parent.appending(path: "wallpaperengine-mac-renderer")
            try FileManager.default.createDirectory(
                at: source.appending(path: "CMakeModules"),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: source.appending(path: "src"),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(
                at: URL(filePath: testRepositoryPath(
                    "ExternalRenderers/wallpaperengine-mac-renderer/CMakeModules/BackgroundEngineRendererProvenance.pl"
                )),
                to: source.appending(path: "CMakeModules/BackgroundEngineRendererProvenance.pl")
            )
            try "7acc6c9-be5\n".write(
                to: source.appending(path: ".background-engine-build-version"),
                atomically: true,
                encoding: .utf8
            )
            try "7acc6c92e0175d53e1cb6b2b2dff52f79faf83e0\n".write(
                to: source.appending(path: ".background-engine-source-ref"),
                atomically: true,
                encoding: .utf8
            )
            try "project(fixture)\n".write(
                to: source.appending(path: "CMakeLists.txt"),
                atomically: true,
                encoding: .utf8
            )
            try payload.write(
                to: source.appending(path: "src/fixture.cpp"),
                atomically: true,
                encoding: .utf8
            )
            return source
        }

        func archive(_ source: URL, to output: URL) throws {
            try requireSuccess(
                "/usr/bin/tar",
                arguments: [
                    "-czf", output.path,
                    "-C", source.deletingLastPathComponent().path,
                    "wallpaperengine-mac-renderer"
                ]
            )
        }

        let expectedSource = try makeSource(
            in: root.appending(path: "expected"),
            payload: "int fixture = 1;\n"
        )
        let matchingArchive = root.appending(path: "matching.tar.gz")
        try archive(expectedSource, to: matchingArchive)
        let matching = try run(
            "/bin/bash",
            arguments: [script, matchingArchive.path, expectedSource.path]
        )
        XCTAssertEqual(matching.status, 0, matching.standardError)
        XCTAssertTrue(matching.standardOutput.contains("Verified renderer source archive provenance"))
        let expectedProvenance = try run(
            "/usr/bin/perl",
            arguments: [
                testRepositoryPath("Scripts/renderer-source-fingerprint.pl"),
                expectedSource.path
            ]
        )
        XCTAssertEqual(expectedProvenance.status, 0, expectedProvenance.standardError)

        let staleSource = try makeSource(
            in: root.appending(path: "stale"),
            payload: "int fixture = 0;\n"
        )
        let maliciousExecutionMarker = root.appending(path: "archive-code-executed")
        try """
        #!/usr/bin/perl
        use strict;
        use warnings;
        open my $marker, '>:raw', q{\(maliciousExecutionMarker.path)} or die $!;
        print {$marker} "archive-controlled code executed\n";
        close $marker or die $!;
        print <<'SPOOFED_PROVENANCE';
        \(expectedProvenance.standardOutput)SPOOFED_PROVENANCE
        """.write(
            to: staleSource.appending(path: "CMakeModules/BackgroundEngineRendererProvenance.pl"),
            atomically: true,
            encoding: .utf8
        )
        let staleArchive = root.appending(path: "stale.tar.gz")
        try archive(staleSource, to: staleArchive)
        let stale = try run(
            "/bin/bash",
            arguments: [script, staleArchive.path, expectedSource.path]
        )
        XCTAssertNotEqual(stale.status, 0)
        XCTAssertTrue(
            stale.standardError.contains("provenance does not match the current canonical source"),
            stale.standardError
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: maliciousExecutionMarker.path),
            "The archive verifier executed provenance code supplied by the untrusted archive."
        )
    }

    func testFFmpegMergeWritesOneUniversalArchitectureMetadataLine() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "media-tool.c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: source)

        var runtimes: [String: URL] = [:]
        for architecture in ["arm64", "x86_64"] {
            let runtime = root.appending(path: architecture)
            let mediaTools = runtime.appending(path: "MediaTools")
            let sourceDirectory = runtime.appending(path: "Source")
            try FileManager.default.createDirectory(at: mediaTools, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
            try Data("same pinned source".utf8).write(
                to: sourceDirectory.appending(path: "ffmpeg-9.0.1.tar.xz")
            )
            try Data("FFmpeg version: 9.0.1\nArchitectures: \(architecture)\nNetwork: disabled\n".utf8)
                .write(to: sourceDirectory.appending(path: "build-flags.txt"))
            for binary in ["ffmpeg", "ffprobe"] {
                try requireSuccess(
                    "/usr/bin/clang",
                    arguments: ["-arch", architecture, source.path, "-o", mediaTools.appending(path: binary).path]
                )
            }
            runtimes[architecture] = runtime
        }

        let output = root.appending(path: "universal")
        let result = try run(
            "/bin/bash",
            arguments: [
                testRepositoryPath("Scripts/merge-ffmpeg-runtime.sh"),
                try XCTUnwrap(runtimes["arm64"]).path,
                try XCTUnwrap(runtimes["x86_64"]).path,
                output.path
            ]
        )
        XCTAssertEqual(result.status, 0, result.standardError)

        let buildFlags = try String(
            contentsOf: output.appending(path: "Source/build-flags.txt"),
            encoding: .utf8
        )
        let architectureLines = buildFlags.split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("Architectures:") }
        XCTAssertEqual(architectureLines, ["Architectures: arm64 x86_64"])
        XCTAssertTrue(buildFlags.contains("Network: disabled"))
        for binary in ["ffmpeg", "ffprobe"] {
            try requireSuccess(
                "/usr/bin/lipo",
                arguments: [output.appending(path: "MediaTools/\(binary)").path, "-verify_arch", "arm64", "x86_64"]
            )
        }
    }

    func testPackageMetadataVerifierAcceptsExactNestedMetadataWithoutMutation() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makePackageMetadataFixture(at: root)
        let before = try packageMetadataSnapshot(at: app)

        let result = try verifyPackageMetadata(app: app)

        XCTAssertEqual(result.status, 0, result.standardError)
        XCTAssertTrue(result.standardOutput.contains("Verified package metadata: version 0.2.0-alpha.1 (9)"))
        XCTAssertEqual(try packageMetadataSnapshot(at: app), before)
    }

    func testPackageMetadataVerifierRejectsEveryBundleMismatchAndUnsafeArguments() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makePackageMetadataFixture(at: root)
        let cases: [(relativePlist: String, key: String, value: String, label: String)] = [
            ("Contents/Info.plist", "CFBundleVersion", "5", "App CFBundleVersion mismatch"),
            (
                "Contents/XPCServices/BackgroundEngineSteamCMDRunner.xpc/Contents/Info.plist",
                "CFBundleIdentifier",
                "com.example.wrong-xpc",
                "SteamCMD XPC CFBundleIdentifier mismatch"
            ),
            (
                "Contents/Resources/Background Engine.saver/Contents/Info.plist",
                "CFBundleShortVersionString",
                "0.1.0",
                "Screen saver CFBundleShortVersionString mismatch"
            )
        ]

        for testCase in cases {
            let plist = app.appending(path: testCase.relativePlist)
            let original = try Data(contentsOf: plist)
            var metadata = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: original, format: nil) as? [String: Any]
            )
            metadata[testCase.key] = testCase.value
            try writeInfoPlist(metadata, to: plist)

            let result = try verifyPackageMetadata(app: app)
            XCTAssertNotEqual(result.status, 0, testCase.label)
            XCTAssertTrue(result.standardError.contains(testCase.label), result.standardError)
            try original.write(to: plist)
        }

        let saverPlist = app.appending(
            path: "Contents/Resources/Background Engine.saver/Contents/Info.plist"
        )
        let saverMetadata = try Data(contentsOf: saverPlist)
        try FileManager.default.removeItem(at: saverPlist)
        let missingPlist = try verifyPackageMetadata(app: app)
        XCTAssertNotEqual(missingPlist.status, 0)
        XCTAssertTrue(missingPlist.standardError.contains("Screen saver Info.plist is missing"))
        try saverMetadata.write(to: saverPlist)

        let saverExecutable = app.appending(
            path: "Contents/Resources/Background Engine.saver/Contents/MacOS/BackgroundEngineScreenSaver"
        )
        let originalSaverPlist = try Data(contentsOf: saverPlist)
        var missingExecutableKey = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: originalSaverPlist, format: nil) as? [String: Any]
        )
        missingExecutableKey.removeValue(forKey: "CFBundleExecutable")
        try writeInfoPlist(missingExecutableKey, to: saverPlist)
        let missingExecutableKeyResult = try verifyPackageMetadata(app: app)
        XCTAssertNotEqual(missingExecutableKeyResult.status, 0)
        XCTAssertTrue(missingExecutableKeyResult.standardError.contains("missing required key CFBundleExecutable"))
        try originalSaverPlist.write(to: saverPlist)

        var unsafeExecutableMetadata = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: originalSaverPlist, format: nil) as? [String: Any]
        )
        unsafeExecutableMetadata["CFBundleExecutable"] = "../BackgroundEngineScreenSaver"
        try writeInfoPlist(unsafeExecutableMetadata, to: saverPlist)
        let unsafeExecutable = try verifyPackageMetadata(app: app)
        XCTAssertNotEqual(unsafeExecutable.status, 0)
        XCTAssertTrue(unsafeExecutable.standardError.contains("CFBundleExecutable must be a safe file name"))
        try originalSaverPlist.write(to: saverPlist)

        let saverExecutableData = try Data(contentsOf: saverExecutable)
        try FileManager.default.removeItem(at: saverExecutable)
        let missingExecutable = try verifyPackageMetadata(app: app)
        XCTAssertNotEqual(missingExecutable.status, 0)
        XCTAssertTrue(missingExecutable.standardError.contains("Screen saver executable is missing"))

        let symlinkTarget = root.appending(path: "screen-saver-symlink-target")
        try saverExecutableData.write(to: symlinkTarget)
        try FileManager.default.createSymbolicLink(at: saverExecutable, withDestinationURL: symlinkTarget)
        let symlinkExecutable = try verifyPackageMetadata(app: app)
        XCTAssertNotEqual(symlinkExecutable.status, 0)
        XCTAssertTrue(symlinkExecutable.standardError.contains("Screen saver executable is missing"))
        try FileManager.default.removeItem(at: saverExecutable)
        try saverExecutableData.write(to: saverExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: saverExecutable.path)
        let nonExecutable = try verifyPackageMetadata(app: app)
        XCTAssertNotEqual(nonExecutable.status, 0)
        XCTAssertTrue(nonExecutable.standardError.contains("Screen saver executable is missing"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: saverExecutable.path)

        let invalidVersion = try verifyPackageMetadata(app: app, version: "0.2.0\ninjected")
        XCTAssertNotEqual(invalidVersion.status, 0)
        XCTAssertTrue(invalidVersion.standardError.contains("Refusing invalid marketing version"))

        let invalidBuild = try verifyPackageMetadata(app: app, build: "6.1")
        XCTAssertNotEqual(invalidBuild.status, 0)
        XCTAssertTrue(invalidBuild.standardError.contains("Refusing invalid build number"))

        let relativePath = try run(
            "/bin/bash",
            arguments: [testRepositoryPath("Scripts/verify-package-metadata.sh"), "Background Engine.app", "0.2.0-alpha.1", "9"]
        )
        XCTAssertNotEqual(relativePath.status, 0)
        XCTAssertTrue(relativePath.standardError.contains("App bundle path must be absolute"))
    }

    func testBundledRendererMountsExplicitContentProbedScenePackage() throws {
        let rendererContext = try String(
            repositoryFile: "ExternalRenderers/wallpaperengine-mac-renderer/src/WallpaperEngine/Application/ApplicationContext.cpp"
        )
        let rendererApplication = try String(
            repositoryFile: "ExternalRenderers/wallpaperengine-mac-renderer/src/WallpaperEngine/Application/WallpaperApplication.cpp"
        )
        let sceneProjectMetadata = try String(
            repositoryFile: "ExternalRenderers/wallpaperengine-mac-renderer/src/WallpaperEngine/Application/SceneProjectMetadata.cpp"
        )
        let packageAdapter = try String(
            repositoryFile: "ExternalRenderers/wallpaperengine-mac-renderer/src/WallpaperEngine/FileSystem/Adapters/Package.cpp"
        )
        let workflow = try String(repositoryFile: ".github/workflows/ci.yml")
        XCTAssertTrue(rendererContext.contains("--scene-package"))
        XCTAssertTrue(rendererApplication.contains("settings.general.scenePackage"))
        XCTAssertTrue(rendererApplication.contains("SceneProjectMetadata::loadForExplicitPackage"))
        XCTAssertTrue(sceneProjectMetadata.contains(#"metadata["file"] = "scene.json""#))
        XCTAssertTrue(sceneProjectMetadata.contains("synthesizedMetadata"))
        XCTAssertTrue(packageAdapter.contains("hasPackageHeader"))
        XCTAssertTrue(packageAdapter.contains(#"header.starts_with ("PKGV")"#))
        XCTAssertTrue(workflow.contains("scene-project-metadata-tests"))
        XCTAssertTrue(workflow.contains("smoke-test-standalone-scene-package.sh"))
        let rendererJobStart = try XCTUnwrap(workflow.range(of: "  renderer-smoke:"))
        let rendererJobEnd = try XCTUnwrap(
            workflow.range(
                of: "\n  media-smoke:",
                range: rendererJobStart.upperBound..<workflow.endIndex
            )
        )
        let rendererJob = String(
            workflow[rendererJobStart.lowerBound..<rendererJobEnd.lowerBound]
        )
        XCTAssertEqual(
            rendererJob.components(separatedBy: "scene_smoke_mode: load-only").count - 1,
            2
        )
        XCTAssertFalse(rendererJob.contains("scene_smoke_mode: render"))
        XCTAssertTrue(rendererJob.contains("GitHub's hosted macOS images"))
        XCTAssertTrue(rendererJob.contains("macos-15-intel"))
        XCTAssertTrue(rendererJob.contains("--load-only"))
        XCTAssertTrue(rendererJob.contains("render)"))

        let readme = try String(repositoryFile: "README.md")
        XCTAssertTrue(readme.contains("do not expose an NSGL pixel format"))
        XCTAssertTrue(readme.contains("produces exactly two non-empty PNG frames"))

        let smokeScript = try String(
            repositoryFile: "Scripts/smoke-test-standalone-scene-package.sh"
        )
        XCTAssertTrue(smokeScript.contains("smoke_mode=${2:-render}"))
        XCTAssertTrue(smokeScript.contains("if [[ \"$smoke_mode\" == \"render\" ]]"))
        XCTAssertTrue(smokeScript.contains("frame rendering was explicitly disabled"))
    }

    func testStandaloneSceneSmokeRejectsTemporaryParentThatCanonicalizesToRoot() throws {
        let script = testRepositoryPath("Scripts/smoke-test-standalone-scene-package.sh")
        let result = try run(
            "/usr/bin/env",
            arguments: ["TMPDIR=///", script, "/usr/bin/true"]
        )

        XCTAssertEqual(result.status, 64)
        XCTAssertTrue(
            result.standardError.contains("Refusing unsafe canonical temporary parent"),
            result.standardError
        )
    }

    func testStandaloneSceneLoadOnlySmokeNeverAttemptsFrameRendering() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let renderer = root.appending(path: "renderer-stub")
        let recordMarker = root.appending(path: "record-invoked")
        try Data(
            #"""
            #!/bin/bash
            has_package=false
            for argument in "$@"; do
              case "$argument" in
                --record-dir)
                  /usr/bin/touch "$MOCK_RECORD_MARKER"
                  exit 99
                  ;;
                --scene-package)
                  has_package=true
                  ;;
              esac
            done
            if "$has_package"; then
              exit 0
            fi
            exit 1
            """#.utf8
        ).write(to: renderer)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: renderer.path
        )

        let script = testRepositoryPath("Scripts/smoke-test-standalone-scene-package.sh")
        let result = try run(
            "/usr/bin/env",
            arguments: [
                "TMPDIR=\(root.path)",
                "MOCK_RECORD_MARKER=\(recordMarker.path)",
                script,
                renderer.path,
                "--load-only"
            ]
        )

        XCTAssertEqual(result.status, 0, result.standardError)
        XCTAssertTrue(result.standardOutput.contains("frame rendering was explicitly disabled"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordMarker.path))

        let invalidMode = try run(
            "/bin/bash",
            arguments: [script, renderer.path, "--unknown-mode"]
        )
        XCTAssertEqual(invalidMode.status, 64)
        XCTAssertTrue(invalidMode.standardError.contains("Unsupported standalone Scene smoke mode"))
    }

    func testRuntimeOutputValidationPreservesExistingDirectoryAndRejectsDotSegments() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appending(path: "runtime")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let marker = output.appending(path: "keep.txt")
        try Data("keep".utf8).write(to: marker)

        let commonScript = testRepositoryPath("Scripts/runtime-script-common.sh")
        let existing = try run(
            "/bin/bash",
            arguments: [
                "-c",
                "source \"$1\"; be_resolve_new_output \"$2\" \"fixture runtime\"",
                "runtime-output-test",
                commonScript,
                output.path
            ]
        )
        XCTAssertNotEqual(existing.status, 0)
        XCTAssertTrue(existing.standardError.contains("Refusing to overwrite"))
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "keep")

        for unsafePath in [".", "..", root.appending(path: "child/../escape").path] {
            let result = try run(
                "/bin/bash",
                arguments: [
                    "-c",
                    "source \"$1\"; be_resolve_new_output \"$2\" \"fixture runtime\"",
                    "runtime-output-test",
                    commonScript,
                    unsafePath
                ]
            )
            XCTAssertNotEqual(result.status, 0, "Expected unsafe output to be rejected: \(unsafePath)")
            XCTAssertTrue(result.standardError.contains("Refusing unsafe"))
        }
    }

    func testHomebrewKegCountTreatsMissingFormulaAsZeroUnderPipefail() throws {
        let result = try run(
            "/bin/bash",
            arguments: [
                "-c",
                #"""
                set -euo pipefail
                source "$1"
                brew() {
                  case "$MOCK_BREW_MODE" in
                    missing) return 1 ;;
                    one) printf '%s\n' 'fixture 1.0' ;;
                    three) printf '%s\n' 'fixture 1.0 2.0 3.0' ;;
                    *) return 2 ;;
                  esac
                }
                MOCK_BREW_MODE=missing
                test "$(be_homebrew_installed_keg_count fixture)" = 0
                MOCK_BREW_MODE=one
                test "$(be_homebrew_installed_keg_count fixture)" = 1
                MOCK_BREW_MODE=three
                test "$(be_homebrew_installed_keg_count fixture)" = 3
                """#,
                "homebrew-keg-count-test",
                testRepositoryPath("Scripts/runtime-script-common.sh")
            ]
        )
        XCTAssertEqual(result.status, 0, result.standardError)
    }

    func testHomebrewInstallationValidationAcceptsKegOnlyFormulaWithoutLinkedKeg() throws {
        let result = try run(
            "/bin/bash",
            arguments: [
                "-c",
                #"""
                set -euo pipefail
                source "$1"
                regular='{"formulae":[{"keg_only":false,"linked_keg":"1.2.3","installed":[{"version":"1.2.3"}]}]}'
                keg_only='{"formulae":[{"keg_only":true,"linked_keg":null,"installed":[{"version":"3.8.9"}]}]}'
                wrong_link='{"formulae":[{"keg_only":false,"linked_keg":null,"installed":[{"version":"1.2.3"}]}]}'
                wrong_version='{"formulae":[{"keg_only":true,"linked_keg":null,"installed":[{"version":"3.8.8"}]}]}'
                multiple='{"formulae":[{"keg_only":true,"linked_keg":null,"installed":[{"version":"3.8.8"},{"version":"3.8.9"}]}]}'
                printf '%s\n' "$regular" | be_homebrew_installation_matches 1.2.3
                printf '%s\n' "$keg_only" | be_homebrew_installation_matches 3.8.9
                if printf '%s\n' "$wrong_link" | be_homebrew_installation_matches 1.2.3; then
                  exit 1
                fi
                if printf '%s\n' "$wrong_version" | be_homebrew_installation_matches 3.8.9; then
                  exit 1
                fi
                if printf '%s\n' "$multiple" | be_homebrew_installation_matches 3.8.9; then
                  exit 1
                fi
                """#,
                "homebrew-installation-validation-test",
                testRepositoryPath("Scripts/runtime-script-common.sh")
            ]
        )
        XCTAssertEqual(result.status, 0, result.standardError)
    }

    func testHomebrewReceiptValidationAllowsMissingPinnedHeadButRejectsConflicts() throws {
        let result = try run(
            "/bin/bash",
            arguments: [
                "-c",
                #"""
                set -euo pipefail
                source "$1"
                pinned=229d435d9fc7d166b417e94ce66db01d6b34cf97
                with_head='{"poured_from_bottle":true,"arch":"arm64","source":{"tap":"homebrew/core","tap_git_head":"229d435d9fc7d166b417e94ce66db01d6b34cf97","versions":{"stable":"1.0"}}}'
                missing_head='{"poured_from_bottle":true,"arch":"arm64","source":{"tap":"homebrew/core","tap_git_head":null,"versions":{"stable":"1.0"}}}'
                wrong_head='{"poured_from_bottle":true,"arch":"arm64","source":{"tap":"homebrew/core","tap_git_head":"different","versions":{"stable":"1.0"}}}'
                wrong_arch='{"poured_from_bottle":true,"arch":"x86_64","source":{"tap":"homebrew/core","tap_git_head":null,"versions":{"stable":"1.0"}}}'
                wrong_version='{"poured_from_bottle":true,"arch":"arm64","source":{"tap":"homebrew/core","tap_git_head":null,"versions":{"stable":"0.99"}}}'
                wrong_tap='{"poured_from_bottle":true,"arch":"arm64","source":{"tap":"example/tap","tap_git_head":null,"versions":{"stable":"1.0"}}}'
                invalid_head_type='{"poured_from_bottle":true,"arch":"arm64","source":{"tap":"homebrew/core","tap_git_head":false,"versions":{"stable":"1.0"}}}'
                source_build='{"poured_from_bottle":false,"arch":"arm64","source":{"tap":"homebrew/core","tap_git_head":null,"versions":{"stable":"1.0"}}}'
                printf '%s\n' "$with_head" | be_homebrew_receipt_matches arm64 1.0 "$pinned"
                printf '%s\n' "$missing_head" | be_homebrew_receipt_matches arm64 1.0 "$pinned"
                revised_keg='{"poured_from_bottle":true,"arch":"arm64","source":{"tap":"homebrew/core","tap_git_head":null,"versions":{"stable":"0.41.0"}}}'
                printf '%s\n' "$revised_keg" | be_homebrew_receipt_matches arm64 0.41.0 "$pinned"
                for invalid in "$wrong_head" "$wrong_arch" "$wrong_version" "$wrong_tap" "$invalid_head_type" "$source_build"; do
                  if printf '%s\n' "$invalid" | be_homebrew_receipt_matches arm64 1.0 "$pinned"; then
                    exit 1
                  fi
                done
                """#,
                "homebrew-receipt-validation-test",
                testRepositoryPath("Scripts/runtime-script-common.sh")
            ]
        )
        XCTAssertEqual(result.status, 0, result.standardError)
    }

    func testPinnedGitCheckoutPreservesHostedChangesAndRefusesDirtyLocalRepository() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appending(path: "homebrew-core")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try requireSuccess("/usr/bin/git", arguments: ["-C", repository.path, "init"])
        try requireSuccess(
            "/usr/bin/git",
            arguments: ["-C", repository.path, "config", "user.email", "ci@example.invalid"]
        )
        try requireSuccess(
            "/usr/bin/git",
            arguments: ["-C", repository.path, "config", "user.name", "CI Fixture"]
        )
        let tracked = repository.appending(path: "tracked.txt")
        let untracked = repository.appending(path: "untracked.txt")
        try Data("base\n".utf8).write(to: tracked)
        try requireSuccess("/usr/bin/git", arguments: ["-C", repository.path, "add", "tracked.txt"])
        try requireSuccess("/usr/bin/git", arguments: ["-C", repository.path, "commit", "-m", "base"])
        let commit = try run(
            "/usr/bin/git",
            arguments: ["-C", repository.path, "rev-parse", "HEAD"]
        ).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)

        try Data("hosted staged\n".utf8).write(to: tracked)
        try requireSuccess("/usr/bin/git", arguments: ["-C", repository.path, "add", "tracked.txt"])
        try Data("hosted unstaged\n".utf8).write(to: tracked)
        try Data("hosted untracked\n".utf8).write(to: untracked)
        let hostedResult = try run(
            "/usr/bin/env",
            arguments: [
                "GITHUB_ACTIONS=true",
                "RUNNER_ENVIRONMENT=github-hosted",
                "/bin/bash",
                "-c",
                "set -euo pipefail; source \"$1\"; be_checkout_pinned_git_commit \"$2\" \"$3\" \"homebrew/core\"",
                "pinned-git-checkout-test",
                testRepositoryPath("Scripts/runtime-script-common.sh"),
                repository.path,
                commit
            ]
        )
        XCTAssertEqual(hostedResult.status, 0, hostedResult.standardError)
        XCTAssertEqual(try String(contentsOf: tracked, encoding: .utf8), "base\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: untracked.path))
        let cleanStatus = try run(
            "/usr/bin/git",
            arguments: ["-C", repository.path, "status", "--porcelain", "--untracked-files=all"]
        )
        XCTAssertEqual(cleanStatus.status, 0, cleanStatus.standardError)
        XCTAssertTrue(cleanStatus.standardOutput.isEmpty)
        let stashedNames = try run(
            "/usr/bin/git",
            arguments: [
                "-C", repository.path, "stash", "show", "--include-untracked", "--name-only", "stash@{0}"
            ]
        )
        XCTAssertEqual(stashedNames.status, 0, stashedNames.standardError)
        XCTAssertTrue(stashedNames.standardOutput.contains("tracked.txt"))
        XCTAssertTrue(stashedNames.standardOutput.contains("untracked.txt"))
        let stashedWorktree = try run(
            "/usr/bin/git",
            arguments: ["-C", repository.path, "show", "stash@{0}:tracked.txt"]
        )
        XCTAssertEqual(stashedWorktree.status, 0, stashedWorktree.standardError)
        XCTAssertEqual(stashedWorktree.standardOutput, "hosted unstaged\n")
        let stashedIndex = try run(
            "/usr/bin/git",
            arguments: ["-C", repository.path, "show", "stash@{0}^2:tracked.txt"]
        )
        XCTAssertEqual(stashedIndex.status, 0, stashedIndex.standardError)
        XCTAssertEqual(stashedIndex.standardOutput, "hosted staged\n")

        try Data("local change\n".utf8).write(to: tracked)
        try Data("local untracked\n".utf8).write(to: untracked)
        let localResult = try run(
            "/usr/bin/env",
            arguments: [
                "GITHUB_ACTIONS=false",
                "RUNNER_ENVIRONMENT=github-hosted",
                "/bin/bash",
                "-c",
                "set -euo pipefail; source \"$1\"; be_checkout_pinned_git_commit \"$2\" \"$3\" \"homebrew/core\"",
                "pinned-git-checkout-test",
                testRepositoryPath("Scripts/runtime-script-common.sh"),
                repository.path,
                commit
            ]
        )
        XCTAssertNotEqual(localResult.status, 0)
        XCTAssertTrue(localResult.standardError.contains("Refusing to alter a dirty local homebrew/core checkout"))
        XCTAssertEqual(try String(contentsOf: tracked, encoding: .utf8), "local change\n")
        XCTAssertEqual(try String(contentsOf: untracked, encoding: .utf8), "local untracked\n")

        let missingResult = try run(
            "/usr/bin/env",
            arguments: [
                "GITHUB_ACTIONS=true",
                "RUNNER_ENVIRONMENT=github-hosted",
                "/bin/bash",
                "-c",
                "set -euo pipefail; source \"$1\"; be_checkout_pinned_git_commit \"$2\" \"$3\" \"homebrew/core\"",
                "pinned-git-checkout-test",
                testRepositoryPath("Scripts/runtime-script-common.sh"),
                root.appending(path: "missing").path,
                commit
            ]
        )
        XCTAssertNotEqual(missingResult.status, 0)
        XCTAssertTrue(missingResult.standardError.contains("Unable to inspect the homebrew/core checkout"))
    }

    func testDMGCreationRetriesOnlyResourceContentionAndPublishesSuccessfulAttempt() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source")
        let output = root.appending(path: "Background Engine.dmg")
        let fakeHDIUtil = root.appending(path: "fake-hdiutil.sh")
        let state = root.appending(path: "attempt-count.txt")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("app fixture".utf8).write(to: source.appending(path: "Background Engine.app"))

        let fakeHDIUtilSource = """
        #!/usr/bin/env bash
        set -euo pipefail
        if [ "${1:-}" = "verify" ]; then
          exit 0
        fi
        mode="${BACKGROUND_ENGINE_FAKE_HDIUTIL_MODE:-resource-busy-once}"
        state="${BACKGROUND_ENGINE_FAKE_HDIUTIL_STATE:?}"
        count=0
        if [ -f "$state" ]; then
          count="$(cat "$state")"
        fi
        count=$((count + 1))
        printf '%s\\n' "$count" > "$state"
        output="${@: -1}"
        if [ "$mode" = "permanent-failure" ]; then
          printf '%s\\n' 'hdiutil: create failed - Permission denied' >&2
          exit 13
        fi
        if [ "$mode" = "always-busy" ] || [ "$count" -eq 1 ]; then
          printf '%s\\n' 'hdiutil: create failed - Resource busy' >&2
          printf '%s' 'incomplete image' > "$output"
          exit 1
        fi
        printf '%s' 'complete image' > "$output"
        """
        try Data(fakeHDIUtilSource.utf8).write(to: fakeHDIUtil)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: fakeHDIUtil.path
        )

        let result = try run(
            "/usr/bin/env",
            arguments: [
                "BACKGROUND_ENGINE_HDIUTIL=\(fakeHDIUtil.path)",
                "BACKGROUND_ENGINE_FAKE_HDIUTIL_STATE=\(state.path)",
                "BACKGROUND_ENGINE_DMG_RETRY_DELAY_SECONDS=0",
                "/bin/bash",
                testRepositoryPath("Scripts/create-dmg.sh"),
                source.path,
                "Background Engine",
                output.path
            ]
        )

        XCTAssertEqual(result.status, 0, result.standardError)
        XCTAssertTrue(result.standardError.contains("Resource busy"))
        XCTAssertTrue(result.standardError.contains("retrying"))
        XCTAssertTrue(try String(repositoryFile: "Scripts/create-dmg.sh").contains("-nospotlight"))
        XCTAssertTrue(try String(repositoryFile: "Scripts/create-dmg.sh").contains("verify \"$candidate\""))
        XCTAssertEqual(try String(contentsOf: state, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "2")
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "complete image")

        let permanentState = root.appending(path: "permanent-attempt-count.txt")
        let rejectedOutput = root.appending(path: "must-not-exist.dmg")
        let permanentFailure = try run(
            "/usr/bin/env",
            arguments: [
                "BACKGROUND_ENGINE_HDIUTIL=\(fakeHDIUtil.path)",
                "BACKGROUND_ENGINE_FAKE_HDIUTIL_MODE=permanent-failure",
                "BACKGROUND_ENGINE_FAKE_HDIUTIL_STATE=\(permanentState.path)",
                "BACKGROUND_ENGINE_DMG_RETRY_DELAY_SECONDS=0",
                "/bin/bash",
                testRepositoryPath("Scripts/create-dmg.sh"),
                source.path,
                "Background Engine",
                rejectedOutput.path
            ]
        )
        XCTAssertEqual(permanentFailure.status, 13)
        XCTAssertTrue(permanentFailure.standardError.contains("Permission denied"))
        XCTAssertFalse(permanentFailure.standardError.contains("retrying"))
        XCTAssertEqual(
            try String(contentsOf: permanentState, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "1"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejectedOutput.path))

        let exhaustedState = root.appending(path: "exhausted-attempt-count.txt")
        let exhaustedOutput = root.appending(path: "exhausted.dmg")
        let exhausted = try run(
            "/usr/bin/env",
            arguments: [
                "BACKGROUND_ENGINE_HDIUTIL=\(fakeHDIUtil.path)",
                "BACKGROUND_ENGINE_FAKE_HDIUTIL_MODE=always-busy",
                "BACKGROUND_ENGINE_FAKE_HDIUTIL_STATE=\(exhaustedState.path)",
                "BACKGROUND_ENGINE_DMG_MAX_ATTEMPTS=3",
                "BACKGROUND_ENGINE_DMG_RETRY_DELAY_SECONDS=0",
                "/bin/bash",
                testRepositoryPath("Scripts/create-dmg.sh"),
                source.path,
                "Background Engine",
                exhaustedOutput.path
            ]
        )
        XCTAssertNotEqual(exhausted.status, 0)
        XCTAssertEqual(
            try String(contentsOf: exhaustedState, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "3"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: exhaustedOutput.path))

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".background-engine-dmg.") }
        XCTAssertTrue(leftovers.isEmpty, "The helper retained temporary images: \(leftovers)")
    }

    func testSceneGoldenParityRefusesExistingOutputWithoutDeletingIt() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let scene = root.appending(path: "scene.pkg")
        let golden = root.appending(path: "golden")
        let assets = root.appending(path: "assets")
        let output = root.appending(path: "report")
        try Data("PKGV".utf8).write(to: scene)
        try FileManager.default.createDirectory(at: golden, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let marker = output.appending(path: "owned-corpus.txt")
        try Data("keep".utf8).write(to: marker)

        let result = try run(
            "/bin/bash",
            arguments: [
                testRepositoryPath("Scripts/scene-golden-parity.sh"),
                "--scene", scene.path,
                "--golden", golden.path,
                "--out", output.path,
                "--renderer", "/usr/bin/true",
                "--assets", assets.path,
                "--size", "4x4"
            ]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.standardError.contains("Refusing to overwrite existing Scene golden parity report"))
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "keep")
    }

    func testSceneGoldenParityRendersAndComparesSyntheticFrame() throws {
        guard let ffmpegPath = ProcessInfo.processInfo.environment["BACKGROUND_ENGINE_FFMPEG"],
              FileManager.default.isExecutableFile(atPath: ffmpegPath) else {
            throw XCTSkip("FFmpeg is required for the contact-sheet smoke test")
        }
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appending(path: "project")
        let scene = project.appending(path: "scene.pkg")
        let golden = root.appending(path: "golden")
        let assets = root.appending(path: "assets")
        let output = root.appending(path: "report")
        let renderer = root.appending(path: "fake-renderer.sh")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: golden, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data("PKGV".utf8).write(to: scene)

        let goldenFrame = golden.appending(path: "owned-reference.png")
        let unusedFrame = root.appending(path: "unused.png")
        let fixture = try run(
            "/usr/bin/swift",
            arguments: [
                testRepositoryPath("Scripts/scene-frame-diff.swift"),
                "--make-fixtures", goldenFrame.path, unusedFrame.path,
                "--mode", "same"
            ]
        )
        XCTAssertEqual(fixture.status, 0, fixture.standardError)
        try FileManager.default.copyItem(at: goldenFrame, to: project.appending(path: "fixture.png"))

        let rendererSource = """
        #!/usr/bin/env bash
        set -euo pipefail
        record_dir=""
        project_dir="${@: -1}"
        while [[ $# -gt 0 ]]; do
          if [[ "$1" = "--record-dir" ]]; then
            record_dir="$2"
            shift 2
          else
            shift
          fi
        done
        [[ -n "$record_dir" ]]
        cp "$project_dir/fixture.png" "$record_dir/frame_00001.png"
        """
        try Data(rendererSource.utf8).write(to: renderer)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: renderer.path
        )

        let result = try run(
            "/bin/bash",
            arguments: [
                testRepositoryPath("Scripts/scene-golden-parity.sh"),
                "--scene", scene.path,
                "--golden", golden.path,
                "--out", output.path,
                "--renderer", renderer.path,
                "--assets", assets.path,
                "--size", "4x4",
                "--timeout", "10"
            ]
        )
        XCTAssertEqual(result.status, 0, result.standardError)
        let summaryURL = output.appending(path: "summary.json")
        let summary = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: summaryURL)) as? [String: Any]
        )
        XCTAssertEqual(summary["status"] as? String, "compared")
        XCTAssertEqual(summary["frameCount"] as? Int, 1)
        XCTAssertEqual(summary["changedRatioMean"] as? Double, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appending(path: "contact-sheet.png").path))
    }

    func testRendererVerifierRejectsMissingBundledDependency() throws {
        let runtime = try makeSyntheticRendererRuntime(rpaths: ["@executable_path/lib/"])
        defer { try? FileManager.default.removeItem(at: runtime.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: runtime.appending(path: "lib/libFixture.dylib"))

        let result = try verify(runtime: runtime)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.standardError.contains("Renderer dependency is missing"))
    }

    func testRendererSourceFingerprintIsDeterministicAndIncludesCanonicalLocalSources() throws {
        let script = testRepositoryPath("Scripts/renderer-source-fingerprint.pl")
        let source = testRepositoryPath("ExternalRenderers/wallpaperengine-mac-renderer")
        let first = try run("/usr/bin/perl", arguments: [script, source])
        let second = try run("/usr/bin/perl", arguments: [script, source])
        XCTAssertEqual(first.status, 0, first.standardError)
        XCTAssertEqual(second.status, 0, second.standardError)
        XCTAssertEqual(first.standardOutput, second.standardOutput)
        XCTAssertTrue(first.standardOutput.contains("renderer-version\t7acc6c9-be5\n"))
        XCTAssertTrue(first.standardOutput.contains("source-fingerprint\t"))

        let inventory = try run(
            "/bin/bash",
            arguments: [
                "-c",
                """
                /usr/bin/perl "$1" "$2" --inventory \
                  | /usr/bin/grep -E '^src/WallpaperEngine/(Scripting/ScriptValueConverter[.](cpp|h)|Testing/Cases/SceneScriptValueConverter[.]cpp)[[:space:]]'
                """,
                "background-engine-inventory",
                script,
                source
            ]
        )
        XCTAssertEqual(inventory.status, 0, inventory.standardError)
        let records = inventory.standardOutput.split(separator: "\n").map(String.init)
        XCTAssertEqual(records, records.sorted())
        XCTAssertEqual(records.count, 3)
        for intendedLocalSource in [
            "src/WallpaperEngine/Scripting/ScriptValueConverter.cpp\t",
            "src/WallpaperEngine/Scripting/ScriptValueConverter.h\t",
            "src/WallpaperEngine/Testing/Cases/SceneScriptValueConverter.cpp\t"
        ] {
            XCTAssertTrue(
                records.contains { $0.hasPrefix(intendedLocalSource) },
                "Canonical renderer provenance omitted \(intendedLocalSource)"
            )
        }
    }

    func testRendererSourceFingerprintIgnoresKnownUntrackedUpstreamArtifacts() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cmakeModules = root.appending(path: "CMakeModules")
        let source = root.appending(path: "src")
        try FileManager.default.createDirectory(at: cmakeModules, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "fixture-version\n".write(
            to: root.appending(path: ".background-engine-build-version"),
            atomically: true,
            encoding: .utf8
        )
        try String(repeating: "a", count: 40).appending("\n").write(
            to: root.appending(path: ".background-engine-source-ref"),
            atomically: true,
            encoding: .utf8
        )
        try "cmake_minimum_required(VERSION 3.20)\n".write(
            to: root.appending(path: "CMakeLists.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "canonical\n".write(
            to: cmakeModules.appending(path: "fixture.cmake"),
            atomically: true,
            encoding: .utf8
        )
        try "canonical\n".write(
            to: source.appending(path: "fixture.cpp"),
            atomically: true,
            encoding: .utf8
        )
        let script = testRepositoryPath("Scripts/renderer-source-fingerprint.pl")
        let baseline = try run("/usr/bin/perl", arguments: [script, root.path])
        XCTAssertEqual(baseline.status, 0, baseline.standardError)

        for relativePath in [
            "src/External/Catch2/third_party/clara.hpp",
            "src/External/Catch2/tools/misc/SelfTest.vcxproj.user",
            "src/External/stb/tests/oversample/oversample.exe"
        ] {
            let file = root.appending(path: relativePath)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "ignored artifact\n".write(
                to: file,
                atomically: true,
                encoding: .utf8
            )
        }

        let withArtifacts = try run("/usr/bin/perl", arguments: [script, root.path])
        XCTAssertEqual(withArtifacts.status, 0, withArtifacts.standardError)
        XCTAssertEqual(withArtifacts.standardOutput, baseline.standardOutput)
    }

    func testRendererVerifierFailsClosedForMissingMalformedStaleOrTamperedProvenance() throws {
        let runtime = try makeSyntheticRendererRuntime(rpaths: ["@executable_path/lib/"])
        defer { try? FileManager.default.removeItem(at: runtime.deletingLastPathComponent()) }
        let manifestURL = runtime.appending(path: "renderer-build-manifest.tsv")
        let lockURL = runtime.appending(path: "dependencies.lock.tsv")
        let originalManifest = try Data(contentsOf: manifestURL)
        let originalLock = try Data(contentsOf: lockURL)

        try FileManager.default.removeItem(at: manifestURL)
        var result = try verify(runtime: runtime)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.standardError.contains("build manifest is missing"), result.standardError)

        try originalManifest.write(to: manifestURL)
        let staleManifest = try XCTUnwrap(String(data: originalManifest, encoding: .utf8))
            .replacingOccurrences(of: "renderer-version\t7acc6c9-be5", with: "renderer-version\t7acc6c9-be4")
        try Data(staleManifest.utf8).write(to: manifestURL)
        result = try verify(runtime: runtime)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.standardError.contains("does not match the current canonical renderer source"),
            result.standardError
        )

        try Data(originalManifest + Data("unexpected\tvalue\n".utf8)).write(to: manifestURL)
        result = try verify(runtime: runtime)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.standardError.contains("manifest is malformed"), result.standardError)

        try originalManifest.write(to: manifestURL)
        try Data(originalLock + Data("tampered\n".utf8)).write(to: lockURL)
        result = try verify(runtime: runtime)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.standardError.contains("malformed or non-canonical"),
            result.standardError
        )
    }

    func testRendererBottleRecordsAndDependencyLockAreCanonicalForBothArchitectures() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recordScript = testRepositoryPath("Scripts/renderer-bottle-lock-records.sh")
        let formulaRecordScript = testRepositoryPath("Scripts/renderer-formula-lock-records.sh")
        let verifyScript = testRepositoryPath("Scripts/verify-renderer-dependency-lock.sh")
        let armSHA = String(repeating: "a", count: 64)
        let intelSHA = String(repeating: "b", count: 64)
        let allSHA = String(repeating: "c", count: 64)

        func records(files: String) throws -> ProcessResult {
            let metadata = root.appending(path: "metadata.json")
            try """
            {"formulae":[{"full_name":"homebrew/core/fixture","bottle":{"stable":{"files":{\(files)}}}}]}
            """.write(to: metadata, atomically: true, encoding: .utf8)
            return try run(
                "/bin/bash",
                arguments: [
                    "-c", "\"$1\" fixture < \"$2\"",
                    "renderer-bottle-record-test", recordScript, metadata.path
                ]
            )
        }

        let architectureSpecific = try records(
            files: "\"arm64_sonoma\":{\"sha256\":\"\(armSHA)\"},\"sonoma\":{\"sha256\":\"\(intelSHA)\"}"
        )
        XCTAssertEqual(architectureSpecific.status, 0, architectureSpecific.standardError)
        XCTAssertEqual(
            architectureSpecific.standardOutput,
            "bottle\tfixture\tarm64\tarm64_sonoma\t\(armSHA)\n" +
                "bottle\tfixture\tx86_64\tsonoma\t\(intelSHA)\n"
        )

        let fallback = try records(files: "\"all\":{\"sha256\":\"\(allSHA)\"}")
        XCTAssertEqual(fallback.status, 0, fallback.standardError)
        XCTAssertEqual(
            fallback.standardOutput,
            "bottle\tfixture\tarm64\tall\t\(allSHA)\n" +
                "bottle\tfixture\tx86_64\tall\t\(allSHA)\n"
        )

        let formulaMetadata = root.appending(path: "formula-metadata.json")
        try """
        {"formulae":[{"full_name":"homebrew/core/fixture","keg_only":true,"linked_keg":null,"installed":[{"version":"3.8.9"}],"urls":{"stable":{"checksum":null}}}]}
        """.write(to: formulaMetadata, atomically: true, encoding: .utf8)
        let kegOnlyFormula = try run(
            "/bin/bash",
            arguments: [
                "-c", "\"$1\" < \"$2\"",
                "renderer-formula-record-test", formulaRecordScript, formulaMetadata.path
            ]
        )
        XCTAssertEqual(kegOnlyFormula.status, 0, kegOnlyFormula.standardError)
        XCTAssertEqual(kegOnlyFormula.standardOutput, "formula\tfixture\t3.8.9\t-\n")

        let validLock = root.appending(path: "valid.lock.tsv")
        try rendererDependencyLock().write(
            to: validLock,
            atomically: true,
            encoding: .utf8
        )
        var verification = try run("/bin/bash", arguments: [verifyScript, validLock.path])
        XCTAssertEqual(verification.status, 0, verification.standardError)

        let invalidLocks = [
            rendererDependencyLock().replacingOccurrences(
                of: "bottle\tfixture\tx86_64\tsonoma\t\(String(repeating: "c", count: 64))\n",
                with: ""
            ),
            rendererDependencyLock() +
                "bottle\tfixture\tx86_64\tsonoma\t\(String(repeating: "c", count: 64))\n",
            rendererDependencyLock().replacingOccurrences(
                of: "bottle\tfixture\tarm64",
                with: "bottle\tother\tarm64"
            ),
            rendererDependencyLock().replacingOccurrences(
                of: String(repeating: "b", count: 64),
                with: String(repeating: "B", count: 64)
            )
        ]
        for (index, invalidContents) in invalidLocks.enumerated() {
            let invalid = root.appending(path: "invalid-\(index).lock.tsv")
            try invalidContents.write(to: invalid, atomically: true, encoding: .utf8)
            verification = try run("/bin/bash", arguments: [verifyScript, invalid.path])
            XCTAssertNotEqual(verification.status, 0, "Accepted invalid lock #\(index)")
            XCTAssertTrue(
                verification.standardError.contains("malformed or non-canonical"),
                verification.standardError
            )
        }
    }

    func testRendererMachOSliceDigestInventoryBindsPackagedBytesAndRefreshesAfterSigning() throws {
        let runtime = try makeSyntheticRendererRuntime(rpaths: ["@executable_path/lib/"])
        defer { try? FileManager.default.removeItem(at: runtime.deletingLastPathComponent()) }
        let inventoryURL = runtime.appending(path: "macho-slice-digests.tsv")
        let manifestURL = runtime.appending(path: "renderer-build-manifest.tsv")
        let originalInventory = try Data(contentsOf: inventoryURL)
        let inventoryLines = try String(contentsOf: inventoryURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertEqual(inventoryLines, inventoryLines.sorted())
        XCTAssertEqual(inventoryLines.count, 2)
        XCTAssertTrue(inventoryLines[0].hasPrefix("background-engine-scene-renderer\t"))
        XCTAssertTrue(inventoryLines[1].hasPrefix("lib/libFixture.dylib\t"))
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        XCTAssertTrue(manifest.hasPrefix("manifest-version\t2\n"))
        XCTAssertTrue(manifest.contains("macho-slice-digests-line-count\t2\n"))

        var tamperedInventory = originalInventory
        tamperedInventory[tamperedInventory.startIndex] ^= 1
        try tamperedInventory.write(to: inventoryURL)
        var result = try verify(runtime: runtime)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.standardError.contains("does not match its build manifest"))
        try originalInventory.write(to: inventoryURL)

        let library = runtime.appending(path: "lib/libFixture.dylib")
        try requireSuccess(
            "/usr/bin/codesign",
            arguments: [
                "--force", "--sign", "-", "--identifier",
                "com.lamppkk.backgroundengine.fixture.resigned", library.path
            ]
        )
        result = try verify(runtime: runtime)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.standardError.contains("digest inventory does not match the packaged bytes"),
            result.standardError
        )

        let architecture = try run("/usr/bin/uname", arguments: ["-m"])
            .standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let refresh = try run(
            "/bin/bash",
            arguments: [
                testRepositoryPath("Scripts/write-renderer-build-manifest.sh"),
                runtime.path, architecture, "--refresh-after-signing"
            ]
        )
        XCTAssertEqual(refresh.status, 0, refresh.standardError)
        result = try verify(runtime: runtime)
        XCTAssertEqual(result.status, 0, result.standardError)

        let validManifestBeforeFailedRefresh = try Data(contentsOf: manifestURL)
        let validInventoryBeforeFailedRefresh = try Data(contentsOf: inventoryURL)
        let fakeTools = runtime.deletingLastPathComponent().appending(path: "fake-mv-tools")
        try FileManager.default.createDirectory(at: fakeTools, withIntermediateDirectories: true)
        let fakeMove = fakeTools.appending(path: "mv")
        try """
        #!/bin/bash
        count=0
        if [[ -f "$MV_COUNT" ]]; then
          count="$(/bin/cat "$MV_COUNT")"
        fi
        count=$((count + 1))
        printf '%s\n' "$count" > "$MV_COUNT"
        if [[ "$count" -eq 4 && ! -e "$FAIL_MARKER" ]]; then
          /usr/bin/touch "$FAIL_MARKER"
          exit 73
        fi
        exec /bin/mv "$@"
        """.write(to: fakeMove, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeMove.path
        )
        let failedPublishMarker = runtime.deletingLastPathComponent()
            .appending(path: "failed-metadata-publish")
        let moveCount = runtime.deletingLastPathComponent().appending(path: "mv-count")
        let failedRefresh = try run(
            "/usr/bin/env",
            arguments: [
                "PATH=\(fakeTools.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "FAIL_MARKER=\(failedPublishMarker.path)",
                "MV_COUNT=\(moveCount.path)",
                "/bin/bash", testRepositoryPath("Scripts/write-renderer-build-manifest.sh"),
                runtime.path, architecture, "--refresh-after-signing"
            ]
        )
        XCTAssertNotEqual(failedRefresh.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: failedPublishMarker.path))
        XCTAssertEqual(try Data(contentsOf: manifestURL), validManifestBeforeFailedRefresh)
        XCTAssertEqual(try Data(contentsOf: inventoryURL), validInventoryBeforeFailedRefresh)
        result = try verify(runtime: runtime)
        XCTAssertEqual(result.status, 0, result.standardError)

        let replacementSource = runtime.deletingLastPathComponent()
            .appending(path: "replacement.c")
        let replacementLibrary = runtime.deletingLastPathComponent()
            .appending(path: "replacement.dylib")
        try "void fixture(void) { volatile int changed = 1; (void)changed; }\n".write(
            to: replacementSource,
            atomically: true,
            encoding: .utf8
        )
        try requireSuccess(
            "/usr/bin/clang",
            arguments: [
                "-arch", architecture, "-mmacosx-version-min=14.0", "-dynamiclib",
                replacementSource.path, "-install_name",
                "@executable_path/lib/libFixture.dylib",
                "-Wl,-rpath,@executable_path/lib/", "-o", replacementLibrary.path
            ]
        )
        try requireSuccess(
            "/usr/bin/codesign",
            arguments: ["--force", "--sign", "-", replacementLibrary.path]
        )
        try FileManager.default.removeItem(at: library)
        try FileManager.default.moveItem(at: replacementLibrary, to: library)
        result = try verify(runtime: runtime)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.standardError.contains("digest inventory does not match the packaged bytes"),
            result.standardError
        )
    }

    func testRendererMetadataRefreshPreservesRecoveryFilesWhenRollbackCannotFinish() throws {
        for failureMode in ["restore", "remove"] {
            let runtime = try makeSyntheticRendererRuntime(rpaths: ["@executable_path/lib/"])
            let root = runtime.deletingLastPathComponent()
            defer { try? FileManager.default.removeItem(at: root) }
            let inventory = runtime.appending(path: "macho-slice-digests.tsv")
            let manifest = runtime.appending(path: "renderer-build-manifest.tsv")
            let originalInventory = try Data(contentsOf: inventory)
            let originalManifest = try Data(contentsOf: manifest)
            try requireSuccess("/usr/bin/codesign", arguments: [
                "--force", "--sign", "-", "--identifier", "com.lamppkk.fixture.resigned",
                runtime.appending(path: "lib/libFixture.dylib").path
            ])

            let fakeTools = root.appending(path: "rollback-failure-tools")
            try FileManager.default.createDirectory(at: fakeTools, withIntermediateDirectories: true)
            let fakeMove = fakeTools.appending(path: "mv")
            try #"""
            #!/bin/bash
            case "${1:-}:${2:-}" in
              *.renderer-build-metadata.*/renderer-build-manifest.tsv:*/renderer-build-manifest.tsv)
                exit 73 ;;
              *.renderer-build-metadata.*/macho-slice-digests.previous.tsv:*/macho-slice-digests.tsv)
                if [ "$FAILURE_MODE" = "restore" ]; then exit 74; fi ;;
            esac
            exec /bin/mv "$@"
            """#.write(to: fakeMove, atomically: true, encoding: .utf8)
            let fakeRemove = fakeTools.appending(path: "rm")
            try #"""
            #!/bin/bash
            if [ "$FAILURE_MODE" = "remove" ] && [ "${1:-}" = "-f" ] && [ "${2:-}" = "$INVENTORY_TARGET" ]; then
              exit 75
            fi
            exec /bin/rm "$@"
            """#.write(to: fakeRemove, atomically: true, encoding: .utf8)
            for tool in [fakeMove, fakeRemove] {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
            }
            let architecture = try run("/usr/bin/uname", arguments: ["-m"])
                .standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            let refresh = try run("/usr/bin/env", arguments: [
                "PATH=\(fakeTools.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "FAILURE_MODE=\(failureMode)",
                "INVENTORY_TARGET=\(try physicalPath(inventory))",
                "/bin/bash", testRepositoryPath("Scripts/write-renderer-build-manifest.sh"),
                runtime.path, architecture, "--refresh-after-signing"
            ])

            XCTAssertEqual(refresh.status, 73, refresh.standardError)
            XCTAssertTrue(
                refresh.standardError.contains("Renderer metadata rollback was incomplete"),
                refresh.standardError
            )
            let recoveryDirectories = try FileManager.default.contentsOfDirectory(
                at: runtime, includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix(".renderer-build-metadata.") }
            XCTAssertEqual(recoveryDirectories.count, 1, failureMode)
            let recovery = try XCTUnwrap(recoveryDirectories.first)
            XCTAssertEqual(
                try Data(contentsOf: recovery.appending(path: "macho-slice-digests.previous.tsv")),
                originalInventory,
                "The last committed inventory must remain recoverable after \(failureMode) fails."
            )
            XCTAssertEqual(try Data(contentsOf: manifest), originalManifest)
            if failureMode == "restore" {
                XCTAssertFalse(FileManager.default.fileExists(atPath: inventory.path))
            } else {
                XCTAssertNotEqual(try Data(contentsOf: inventory), originalInventory)
                XCTAssertTrue(refresh.standardError.contains("Cannot safely restore renderer digest inventory"))
            }
            let verification = try verify(runtime: runtime)
            XCTAssertNotEqual(verification.status, 0, "An incomplete publication must fail closed.")
        }
    }

    func testRendererBuildManifestCannotRelabelAnOlderBinaryAsCurrentSource() throws {
        let runtime = try makeSyntheticRendererRuntime(
            rpaths: ["@executable_path/lib/"],
            rendererProvenanceVersion: "7acc6c9-be4",
            writesBuildManifest: false
        )
        defer { try? FileManager.default.removeItem(at: runtime.deletingLastPathComponent()) }

        let result = try run(
            "/bin/bash",
            arguments: [
                testRepositoryPath("Scripts/write-renderer-build-manifest.sh"),
                runtime.path,
                try run("/usr/bin/uname", arguments: ["-m"])
                    .standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            ]
        )
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.standardError.contains("binary provenance does not match the current canonical source"),
            result.standardError
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: runtime.appending(path: "renderer-build-manifest.tsv").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: runtime.appending(path: "macho-slice-digests.tsv").path
        ))
    }

    func testRendererBundlerUsesNativeDefaultAndSafeExplicitArchitectureContract() throws {
        let script = testRepositoryPath("Scripts/bundle-renderer-runtime.sh")
        let missingArguments = try run("/bin/bash", arguments: [script])
        XCTAssertEqual(missingArguments.status, 64)
        XCTAssertTrue(missingArguments.standardError.contains("[arm64|x86_64]"))

        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let invalidOutput = root.appending(path: "invalid-output")
        let invalidLock = root.appending(path: "invalid-lock.tsv")
        try Data("formula\tfixture\t1.0\n".utf8).write(to: invalidLock)
        for invalidArchitecture in ["", "powerpc"] {
            let invalid = try run(
                "/bin/bash",
                arguments: [
                    script, "/usr/bin/true", invalidOutput.path,
                    invalidArchitecture, invalidLock.path
                ]
            )
            XCTAssertEqual(invalid.status, 64)
            XCTAssertTrue(
                invalid.standardError.contains("Unsupported renderer runtime architecture"),
                invalid.standardError
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: invalidOutput.path))
        }

        let nativeArchitecture = try run("/usr/bin/uname", arguments: ["-m"])
            .standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let crossArchitecture = nativeArchitecture == "arm64" ? "x86_64" : "arm64"
        let nativeInput = try makeSyntheticRendererRuntime(
            rpaths: ["@executable_path/lib/"],
            architecture: nativeArchitecture
        )
        let crossInput = try makeSyntheticRendererRuntime(
            rpaths: ["@executable_path/lib/"],
            architecture: crossArchitecture,
            rendererExitStatus: 91
        )
        defer {
            try? FileManager.default.removeItem(at: nativeInput.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: crossInput.deletingLastPathComponent())
        }

        let fakeTools = root.appending(path: "fake-tools")
        try FileManager.default.createDirectory(at: fakeTools, withIntermediateDirectories: true)
        let fakeDylibBundler = fakeTools.appending(path: "dylibbundler")
        try Data(
            """
            #!/bin/bash
            set -euo pipefail
            /bin/mkdir -p lib
            /bin/cp "$BACKGROUND_ENGINE_TEST_BUNDLE_LIBRARY" lib/libFixture.dylib
            """.utf8
        ).write(to: fakeDylibBundler)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: fakeDylibBundler.path
        )

        func bundle(_ input: URL, output: URL, architecture: String?) throws -> ProcessResult {
            var arguments = [
                "PATH=\(fakeTools.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "BACKGROUND_ENGINE_TEST_BUNDLE_LIBRARY=\(input.appending(path: "lib/libFixture.dylib").path)",
                "/bin/bash", script,
                input.appending(path: "background-engine-scene-renderer").path,
                output.path
            ]
            if let architecture {
                arguments.append(architecture)
                arguments.append(input.appending(path: "dependencies.lock.tsv").path)
            }
            return try run("/usr/bin/env", arguments: arguments)
        }

        let nativeOutput = root.appending(path: "native-runtime")
        let native = try bundle(nativeInput, output: nativeOutput, architecture: nil)
        XCTAssertEqual(native.status, 0, native.standardError)
        XCTAssertFalse(native.standardOutput.contains("Skipping renderer --help smoke"))
        XCTAssertEqual(
            try verify(runtime: nativeOutput, architectures: [nativeArchitecture]).status,
            0
        )

        let crossOutput = root.appending(path: "cross-runtime")
        let cross = try bundle(crossInput, output: crossOutput, architecture: crossArchitecture)
        XCTAssertEqual(cross.status, 0, cross.standardError)
        XCTAssertTrue(cross.standardError.contains("Skipping renderer --help smoke"))
        XCTAssertEqual(
            try verify(runtime: crossOutput, architectures: [crossArchitecture]).status,
            0
        )
    }

    func testRendererVerifierRejectsTextInPlaceOfMachODependency() throws {
        let runtime = try makeSyntheticRendererRuntime(rpaths: ["@executable_path/lib/"])
        defer { try? FileManager.default.removeItem(at: runtime.deletingLastPathComponent()) }
        try Data("not a Mach-O library".utf8)
            .write(to: runtime.appending(path: "lib/libFixture.dylib"))

        let result = try verify(runtime: runtime)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.standardError.contains("library is not Mach-O"), result.standardError)
    }

    func testRendererVerifierRejectsMachOAboveMacOS14DeploymentTarget() throws {
        let runtime = try makeSyntheticRendererRuntime(
            rpaths: ["@executable_path/lib/"],
            deploymentTarget: "15.0"
        )
        defer { try? FileManager.default.removeItem(at: runtime.deletingLastPathComponent()) }

        let result = try verify(runtime: runtime)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.standardError.contains("above the supported 14.0 target"), result.standardError)
    }

    func testRendererVerifierRejectsNonMacOSMachOPlatform() throws {
        let runtime = try makeSyntheticRendererRuntime(rpaths: ["@executable_path/lib/"])
        defer { try? FileManager.default.removeItem(at: runtime.deletingLastPathComponent()) }
        for binary in [
            runtime.appending(path: "background-engine-scene-renderer"),
            runtime.appending(path: "lib/libFixture.dylib")
        ] {
            try requireSuccess(
                "/usr/bin/vtool",
                arguments: [
                    "-set-build-version", "ios", "14.0", "14.0",
                    "-replace", "-output", binary.path + ".ios", binary.path
                ]
            )
            try FileManager.default.removeItem(at: binary)
            try FileManager.default.moveItem(atPath: binary.path + ".ios", toPath: binary.path)
            try requireSuccess("/usr/bin/codesign", arguments: ["--force", "--sign", "-", binary.path])
        }

        let result = try verify(runtime: runtime)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.standardError.contains("invalid macOS platform or deployment target"),
            result.standardError
        )
    }

    func testRendererVerifierRejectsDuplicateLC_RPATH() throws {
        let runtime = try makeSyntheticRendererRuntime(
            rpaths: ["@loader_path/first", "@loader_path/second"],
            rewrittenRpaths: [
                ("@loader_path/first", "@executable_path/lib/"),
                ("@loader_path/second", "@executable_path/lib/")
            ]
        )
        defer { try? FileManager.default.removeItem(at: runtime.deletingLastPathComponent()) }

        let result = try verify(runtime: runtime)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.standardError.contains("exactly one @executable_path/lib/ LC_RPATH"))
    }

    func testRendererVerifierAcceptsUniversalMachOArchitectureHeaders() throws {
        let armRuntime = try makeSyntheticRendererRuntime(
            rpaths: ["@executable_path/lib/"],
            architecture: "arm64"
        )
        let intelRuntime = try makeSyntheticRendererRuntime(
            rpaths: ["@executable_path/lib/"],
            architecture: "x86_64"
        )
        defer {
            try? FileManager.default.removeItem(at: armRuntime.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: intelRuntime.deletingLastPathComponent())
        }
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appending(path: "runtime")
        try FileManager.default.createDirectory(
            at: runtime.appending(path: "lib"),
            withIntermediateDirectories: true
        )
        for relativePath in ["background-engine-scene-renderer", "lib/libFixture.dylib"] {
            let destination = runtime.appending(path: relativePath)
            try requireSuccess(
                "/usr/bin/lipo",
                arguments: [
                    "-create",
                    armRuntime.appending(path: relativePath).path,
                    intelRuntime.appending(path: relativePath).path,
                    "-output",
                    destination.path
                ]
            )
            try requireSuccess("/usr/bin/codesign", arguments: ["--force", "--sign", "-", destination.path])
        }
        try FileManager.default.copyItem(
            at: armRuntime.appending(path: "dependencies.lock.tsv"),
            to: runtime.appending(path: "dependencies.lock.tsv")
        )
        try requireSuccess(
            "/bin/bash",
            arguments: [
                testRepositoryPath("Scripts/write-renderer-build-manifest.sh"),
                runtime.path, "arm64,x86_64"
            ]
        )

        let result = try verify(runtime: runtime, architectures: ["arm64", "x86_64"])
        XCTAssertEqual(result.status, 0, result.standardError)
        XCTAssertTrue(result.standardOutput.contains("Verified renderer runtime"))
    }

    func testRendererMergeCanonicalizesVersionDriftAndPreservesAliases() throws {
        let dependencyLock = rendererDependencyLock(version: "9.0.1")
        let armRuntime = try makeSyntheticRendererRuntime(
            rpaths: ["@executable_path/lib/"],
            architecture: "arm64",
            libraryName: "libFixture.1.8.0.dylib",
            dependencyLock: dependencyLock
        )
        let intelRuntime = try makeSyntheticRendererRuntime(
            rpaths: ["@executable_path/lib/"],
            architecture: "x86_64",
            libraryName: "libFixture.2.1.0.dylib",
            dependencyLock: dependencyLock
        )
        defer {
            try? FileManager.default.removeItem(at: armRuntime.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: intelRuntime.deletingLastPathComponent())
        }
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appending(path: "universal")
        let merge = try run(
            "/bin/bash",
            arguments: [
                testRepositoryPath("Scripts/merge-renderer-runtime.sh"),
                armRuntime.path,
                intelRuntime.path,
                output.path
            ]
        )
        XCTAssertEqual(merge.status, 0, merge.standardError)

        let renderer = output.appending(path: "background-engine-scene-renderer")
        let canonicalLibrary = output.appending(path: "lib/libFixture.dylib")
        XCTAssertEqual(
            try String(contentsOf: output.appending(path: "dependencies.lock.tsv"), encoding: .utf8),
            dependencyLock
        )
        let universalManifest = try String(
            contentsOf: output.appending(path: "renderer-build-manifest.tsv"),
            encoding: .utf8
        )
        XCTAssertTrue(universalManifest.contains("renderer-version\t7acc6c9-be5\n"))
        XCTAssertTrue(universalManifest.contains("architectures\tarm64,x86_64\n"))
        for binary in [renderer, canonicalLibrary] {
            try requireSuccess(
                "/usr/bin/lipo",
                arguments: [binary.path, "-verify_arch", "arm64", "x86_64"]
            )
        }
        for alias in ["libFixture.1.8.0.dylib", "libFixture.2.1.0.dylib"] {
            let aliasPath = output.appending(path: "lib/\(alias)")
            let destination = try FileManager.default.destinationOfSymbolicLink(atPath: aliasPath.path)
            XCTAssertEqual(destination, "libFixture.dylib")
        }
        for architecture in ["arm64", "x86_64"] {
            let loads = try run(
                "/usr/bin/otool",
                arguments: ["-arch", architecture, "-L", renderer.path]
            )
            XCTAssertEqual(loads.status, 0, loads.standardError)
            XCTAssertTrue(loads.standardOutput.contains("@executable_path/lib/libFixture.dylib"))

            let identifier = try run(
                "/usr/bin/otool",
                arguments: ["-arch", architecture, "-D", canonicalLibrary.path]
            )
            XCTAssertEqual(identifier.status, 0, identifier.standardError)
            XCTAssertTrue(identifier.standardOutput.contains("@executable_path/lib/libFixture.dylib"))
        }
        let verification = try verify(runtime: output, architectures: ["arm64", "x86_64"])
        XCTAssertEqual(verification.status, 0, verification.standardError)
        let smoke = try run(renderer.path, arguments: ["--help"])
        XCTAssertEqual(smoke.status, 0, smoke.standardError)
    }

    func testRendererMergeRejectsDependencyLockDrift() throws {
        let armRuntime = try makeSyntheticRendererRuntime(
            rpaths: ["@executable_path/lib/"],
            architecture: "arm64",
            dependencyLock: rendererDependencyLock(version: "9.0.1")
        )
        let intelRuntime = try makeSyntheticRendererRuntime(
            rpaths: ["@executable_path/lib/"],
            architecture: "x86_64",
            dependencyLock: rendererDependencyLock(version: "8.1.2")
        )
        defer {
            try? FileManager.default.removeItem(at: armRuntime.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: intelRuntime.deletingLastPathComponent())
        }
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appending(path: "universal")
        let merge = try run(
            "/bin/bash",
            arguments: [
                testRepositoryPath("Scripts/merge-renderer-runtime.sh"),
                armRuntime.path,
                intelRuntime.path,
                output.path
            ]
        )
        XCTAssertNotEqual(merge.status, 0)
        XCTAssertTrue(
            merge.standardError.contains("dependency locks differ between architectures"),
            merge.standardError
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testRendererMergeRejectsUnexpectedRuntimeEntries() throws {
        let armRuntime = try makeSyntheticRendererRuntime(
            rpaths: ["@executable_path/lib/"],
            architecture: "arm64"
        )
        let intelRuntime = try makeSyntheticRendererRuntime(
            rpaths: ["@executable_path/lib/"],
            architecture: "x86_64"
        )
        defer {
            try? FileManager.default.removeItem(at: armRuntime.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: intelRuntime.deletingLastPathComponent())
        }
        try Data("must not be silently dropped".utf8)
            .write(to: armRuntime.appending(path: "unexpected.txt"))

        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appending(path: "universal")
        let merge = try run(
            "/bin/bash",
            arguments: [
                testRepositoryPath("Scripts/merge-renderer-runtime.sh"),
                armRuntime.path,
                intelRuntime.path,
                output.path
            ]
        )
        XCTAssertNotEqual(merge.status, 0)
        XCTAssertTrue(merge.standardError.contains("unexpected entry"), merge.standardError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testRendererVerifierRejectsUnsafeSymlinkAndMismatchedInstallID() throws {
        let unsafeRuntime = try makeSyntheticRendererRuntime(rpaths: ["@executable_path/lib/"])
        defer { try? FileManager.default.removeItem(at: unsafeRuntime.deletingLastPathComponent()) }
        try FileManager.default.createSymbolicLink(
            atPath: unsafeRuntime.appending(path: "lib/escape.dylib").path,
            withDestinationPath: "../background-engine-scene-renderer"
        )
        let unsafeResult = try verify(runtime: unsafeRuntime)
        XCTAssertNotEqual(unsafeResult.status, 0)
        XCTAssertTrue(unsafeResult.standardError.contains("unsafe target"), unsafeResult.standardError)

        let wrongIDRuntime = try makeSyntheticRendererRuntime(rpaths: ["@executable_path/lib/"])
        defer { try? FileManager.default.removeItem(at: wrongIDRuntime.deletingLastPathComponent()) }
        let library = wrongIDRuntime.appending(path: "lib/libFixture.dylib")
        try requireSuccess(
            "/usr/bin/install_name_tool",
            arguments: ["-id", "@executable_path/lib/wrong.dylib", library.path]
        )
        try requireSuccess("/usr/bin/codesign", arguments: ["--force", "--sign", "-", library.path])
        let wrongIDResult = try verify(runtime: wrongIDRuntime)
        XCTAssertNotEqual(wrongIDResult.status, 0)
        XCTAssertTrue(
            wrongIDResult.standardError.contains("install ID is not canonical"),
            wrongIDResult.standardError
        )
    }

    private func makeSyntheticRendererRuntime(
        rpaths: [String],
        rewrittenRpaths: [(String, String)] = [],
        architecture: String? = nil,
        libraryName: String = "libFixture.dylib",
        deploymentTarget: String = "14.0",
        rendererExitStatus: Int = 0,
        dependencyLock: String? = nil,
        rendererProvenanceVersion: String = "7acc6c9-be5",
        writesBuildManifest: Bool = true
    ) throws -> URL {
        let root = try makeTempDirectory()
        let runtime = root.appending(path: "runtime")
        let libraryDirectory = runtime.appending(path: "lib")
        try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)

        let librarySource = root.appending(path: "fixture.c")
        let mainSource = root.appending(path: "main.c")
        try "void fixture(void) {}\n".write(to: librarySource, atomically: true, encoding: .utf8)
        let provenance = try run(
            "/usr/bin/perl",
            arguments: [
                testRepositoryPath("Scripts/renderer-source-fingerprint.pl"),
                testRepositoryPath("ExternalRenderers/wallpaperengine-mac-renderer"),
                "--binding"
            ]
        )
        XCTAssertEqual(provenance.status, 0, provenance.standardError)
        let provenanceBinding = provenance.standardOutput.replacingOccurrences(
            of: "|7acc6c9-be5|",
            with: "|\(rendererProvenanceVersion)|"
        )
        let provenanceLiteral = provenanceBinding
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\t", with: "\\t")
        try """
        #include <stdio.h>
        #include <string.h>
        void fixture(void);
        __attribute__((used, section("__TEXT,__be_provenance")))
        static const char provenance[] = "\(provenanceLiteral)";
        int main(int argc, char **argv) {
          if (argc == 2 && strcmp(argv[1], "--background-engine-build-info") == 0) {
            puts(provenance);
            return 0;
          }
          fixture();
          return \(rendererExitStatus);
        }
        """.write(to: mainSource, atomically: true, encoding: .utf8)

        let library = libraryDirectory.appending(path: libraryName)
        let renderer = runtime.appending(path: "background-engine-scene-renderer")
        let architectureArguments = architecture.map { ["-arch", $0] } ?? []
        var libraryArguments = architectureArguments + [
            "-mmacosx-version-min=\(deploymentTarget)",
            "-dynamiclib",
            librarySource.path,
            "-install_name",
            "@executable_path/lib/\(libraryName)",
            "-o",
            library.path
        ]
        var rendererArguments = architectureArguments + [
            "-mmacosx-version-min=\(deploymentTarget)",
            mainSource.path,
            library.path,
            "-o",
            renderer.path
        ]
        for rpath in rpaths {
            libraryArguments.append("-Wl,-rpath,\(rpath)")
            rendererArguments.append("-Wl,-rpath,\(rpath)")
        }
        try requireSuccess("/usr/bin/clang", arguments: libraryArguments)
        try requireSuccess("/usr/bin/clang", arguments: rendererArguments)

        for (old, new) in rewrittenRpaths {
            try requireSuccess("/usr/bin/install_name_tool", arguments: ["-rpath", old, new, library.path])
            try requireSuccess("/usr/bin/install_name_tool", arguments: ["-rpath", old, new, renderer.path])
        }
        try requireSuccess("/usr/bin/codesign", arguments: ["--force", "--sign", "-", library.path])
        try requireSuccess("/usr/bin/codesign", arguments: ["--force", "--sign", "-", renderer.path])
        let resolvedDependencyLock = dependencyLock ?? rendererDependencyLock()
        try Data(resolvedDependencyLock.utf8)
            .write(to: runtime.appending(path: "dependencies.lock.tsv"))
        let manifestArchitecture: String
        if let architecture {
            manifestArchitecture = architecture
        } else {
            manifestArchitecture = try run("/usr/bin/uname", arguments: ["-m"])
                .standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if writesBuildManifest {
            try requireSuccess(
                "/bin/bash",
                arguments: [
                    testRepositoryPath("Scripts/write-renderer-build-manifest.sh"),
                    runtime.path,
                    manifestArchitecture
                ]
            )
        }
        return runtime
    }

    private func rendererDependencyLock(
        version: String = "1.0",
        sourceSHA: String = String(repeating: "a", count: 64),
        armBottleSHA: String = String(repeating: "b", count: 64),
        intelBottleSHA: String = String(repeating: "c", count: 64)
    ) -> String {
        """
        homebrew-brew\t0942cac2eda7648d4857f4e5da60f1de303b6818
        homebrew-core\t229d435d9fc7d166b417e94ce66db01d6b34cf97
        deployment-target\tmacos-14
        formula\tfixture\t\(version)\t\(sourceSHA)
        bottle\tfixture\tarm64\tarm64_sonoma\t\(armBottleSHA)
        bottle\tfixture\tx86_64\tsonoma\t\(intelBottleSHA)

        """
    }

    private func verify(runtime: URL, architectures: [String]? = nil) throws -> ProcessResult {
        let resolvedArchitectures: [String]
        if let architectures {
            resolvedArchitectures = architectures
        } else {
            resolvedArchitectures = [
                try run("/usr/bin/uname", arguments: ["-m"])
                    .standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            ]
        }
        return try run(
            "/bin/bash",
            arguments: [testRepositoryPath("Scripts/verify-renderer-runtime.sh"), runtime.path] + resolvedArchitectures
        )
    }

    private func makePackageMetadataFixture(at root: URL) throws -> URL {
        let app = root.appending(path: "Background Engine.app")
        let bundles: [(relativePath: String, identifier: String, executable: String)] = [
            ("", "com.lamppkk.backgroundengine", "Background Engine"),
            (
                "Contents/XPCServices/BackgroundEngineSteamCMDRunner.xpc",
                "com.lamppkk.backgroundengine.steamcmd-runner",
                "BackgroundEngineSteamCMDRunner"
            ),
            (
                "Contents/Resources/Background Engine.saver",
                "com.lamppkk.backgroundengine.screensaver",
                "BackgroundEngineScreenSaver"
            )
        ]
        for bundle in bundles {
            let bundleURL = bundle.relativePath.isEmpty ? app : app.appending(path: bundle.relativePath)
            let plist = bundleURL.appending(path: "Contents/Info.plist")
            try FileManager.default.createDirectory(
                at: plist.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try writeInfoPlist(
                [
                    "CFBundleIdentifier": bundle.identifier,
                    "CFBundleExecutable": bundle.executable,
                    "CFBundleShortVersionString": "0.2.0-alpha.1",
                    "CFBundleVersion": "9"
                ],
                to: plist
            )
            let executable = bundleURL.appending(path: "Contents/MacOS/\(bundle.executable)")
            try FileManager.default.createDirectory(
                at: executable.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("fixture executable".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        return app
    }

    private func writeInfoPlist(_ metadata: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: metadata,
            format: .xml,
            options: 0
        )
        try data.write(to: url)
    }

    private func packageMetadataSnapshot(at app: URL) throws -> [String: Data] {
        let relativePaths = [
            "Contents/Info.plist",
            "Contents/XPCServices/BackgroundEngineSteamCMDRunner.xpc/Contents/Info.plist",
            "Contents/Resources/Background Engine.saver/Contents/Info.plist"
        ]
        return try Dictionary(uniqueKeysWithValues: relativePaths.map {
            ($0, try Data(contentsOf: app.appending(path: $0)))
        })
    }

    private func verifyPackageMetadata(
        app: URL,
        version: String = "0.2.0-alpha.1",
        build: String = "9"
    ) throws -> ProcessResult {
        try run(
            "/bin/bash",
            arguments: [testRepositoryPath("Scripts/verify-package-metadata.sh"), app.path, version, build]
        )
    }

    private func requireSuccess(_ executable: String, arguments: [String]) throws {
        let result = try run(executable, arguments: arguments)
        guard result.status == 0 else {
            XCTFail("Command failed: \(executable) \(arguments.joined(separator: " "))\n\(result.standardError)")
            throw CocoaError(.executableLoad)
        }
    }

    private func physicalPath(_ url: URL) throws -> String {
        let result = try run("/bin/realpath", arguments: [url.path])
        guard result.status == 0 else {
            throw CocoaError(.executableLoad)
        }
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func run(_ executable: String, arguments: [String]) throws -> ProcessResult {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        return ProcessResult(
            status: process.terminationStatus,
            standardOutput: String(decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            standardError: String(decoding: standardError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "Background-Engine-runtime-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct ProcessResult {
    let status: Int32
    let standardOutput: String
    let standardError: String
}
