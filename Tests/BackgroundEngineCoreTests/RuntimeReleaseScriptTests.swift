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

        let rendererDependencyScript = try String(
            repositoryFile: "Scripts/install-renderer-dependencies.sh"
        )
        XCTAssertTrue(
            rendererDependencyScript.contains("229d435d9fc7d166b417e94ce66db01d6b34cf97")
        )
        XCTAssertTrue(rendererDependencyScript.contains("--union --topological"))
        XCTAssertFalse(rendererDependencyScript.contains("--recursive"))
        XCTAssertTrue(rendererDependencyScript.contains("DEPS_ARCH=\"arm\""))
        XCTAssertTrue(rendererDependencyScript.contains("DEPS_ARCH=\"intel\""))
        XCTAssertTrue(rendererDependencyScript.contains("--bottle-tag \"$BOTTLE_TAG\""))
        XCTAssertTrue(rendererDependencyScript.contains("qualified_formula=\"homebrew/core/$formula\""))
        XCTAssertTrue(rendererDependencyScript.contains("brew uninstall --force --ignore-dependencies"))
        XCTAssertTrue(rendererDependencyScript.contains("brew reinstall --no-ask --formula \"$bottle\""))
        XCTAssertTrue(rendererDependencyScript.contains("be_homebrew_installed_keg_count \"$formula\""))
        XCTAssertTrue(rendererDependencyScript.contains("shasum -a 256 \"$bottle\""))
        XCTAssertTrue(rendererDependencyScript.contains("RUNNER_ENVIRONMENT"))
        XCTAssertFalse(rendererDependencyScript.contains("brew upgrade"))
        XCTAssertTrue(rendererDependencyScript.contains("assert_linked ffmpeg 9.0.1"))
        XCTAssertTrue(rendererDependencyScript.contains("assert_linked mpv 0.41.0_8"))
        XCTAssertTrue(rendererDependencyScript.contains("assert_linked pkgconf 3.0.5"))
        XCTAssertTrue(rendererDependencyScript.contains("deployment-target\\tmacos-14"))

        let rendererBundleScript = try String(repositoryFile: "Scripts/bundle-renderer-runtime.sh")
        XCTAssertTrue(
            rendererBundleScript.contains(
                "install_name_tool -id '@executable_path/lib/libSDL3.dylib'"
            )
        )
        XCTAssertFalse(rendererBundleScript.contains("ln -s libSDL3.0.dylib"))
        for workflowPath in [".github/workflows/ci.yml", ".github/workflows/release.yml"] {
            let workflow = try String(repositoryFile: workflowPath)
            XCTAssertTrue(workflow.contains("./Scripts/install-renderer-dependencies.sh"))
            XCTAssertTrue(workflow.contains("-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0"))
            XCTAssertTrue(workflow.contains("renderer-runtime/dependencies.lock.tsv"))
        }

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
        XCTAssertTrue(result.standardOutput.contains("Verified package metadata: version 0.2.0-alpha.1 (6)"))
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

        let invalidVersion = try verifyPackageMetadata(app: app, version: "0.2.0\ninjected")
        XCTAssertNotEqual(invalidVersion.status, 0)
        XCTAssertTrue(invalidVersion.standardError.contains("Refusing invalid marketing version"))

        let invalidBuild = try verifyPackageMetadata(app: app, build: "6.1")
        XCTAssertNotEqual(invalidBuild.status, 0)
        XCTAssertTrue(invalidBuild.standardError.contains("Refusing invalid build number"))

        let relativePath = try run(
            "/bin/bash",
            arguments: [testRepositoryPath("Scripts/verify-package-metadata.sh"), "Background Engine.app", "0.2.0-alpha.1", "6"]
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
        let packageAdapter = try String(
            repositoryFile: "ExternalRenderers/wallpaperengine-mac-renderer/src/WallpaperEngine/FileSystem/Adapters/Package.cpp"
        )
        XCTAssertTrue(rendererContext.contains("--scene-package"))
        XCTAssertTrue(rendererApplication.contains("settings.general.scenePackage"))
        XCTAssertTrue(packageAdapter.contains("hasPackageHeader"))
        XCTAssertTrue(packageAdapter.contains(#"header.starts_with ("PKGV")"#))
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

        let result = try verify(runtime: runtime, architectures: ["arm64", "x86_64"])
        XCTAssertEqual(result.status, 0, result.standardError)
        XCTAssertTrue(result.standardOutput.contains("Verified renderer runtime"))
    }

    func testRendererMergeCanonicalizesVersionDriftAndPreservesAliases() throws {
        let armRuntime = try makeSyntheticRendererRuntime(
            rpaths: ["@executable_path/lib/"],
            architecture: "arm64",
            libraryName: "libFixture.1.8.0.dylib"
        )
        let intelRuntime = try makeSyntheticRendererRuntime(
            rpaths: ["@executable_path/lib/"],
            architecture: "x86_64",
            libraryName: "libFixture.2.1.0.dylib"
        )
        defer {
            try? FileManager.default.removeItem(at: armRuntime.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: intelRuntime.deletingLastPathComponent())
        }
        let dependencyLock = "homebrew-core\tpinned-ref\nformula\tffmpeg\t9.0.1\tchecksum\n"
        try Data(dependencyLock.utf8).write(
            to: armRuntime.appending(path: "dependencies.lock.tsv")
        )
        try Data(dependencyLock.utf8).write(
            to: intelRuntime.appending(path: "dependencies.lock.tsv")
        )

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
        try Data("formula\tffmpeg\t9.0.1\n".utf8)
            .write(to: armRuntime.appending(path: "dependencies.lock.tsv"))
        try Data("formula\tffmpeg\t8.1.2\n".utf8)
            .write(to: intelRuntime.appending(path: "dependencies.lock.tsv"))

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
        deploymentTarget: String = "14.0"
    ) throws -> URL {
        let root = try makeTempDirectory()
        let runtime = root.appending(path: "runtime")
        let libraryDirectory = runtime.appending(path: "lib")
        try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)

        let librarySource = root.appending(path: "fixture.c")
        let mainSource = root.appending(path: "main.c")
        try "void fixture(void) {}\n".write(to: librarySource, atomically: true, encoding: .utf8)
        try "void fixture(void); int main(void) { fixture(); return 0; }\n"
            .write(to: mainSource, atomically: true, encoding: .utf8)

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
        return runtime
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
        let bundles: [(relativePath: String, identifier: String)] = [
            ("", "com.lamppkk.backgroundengine"),
            (
                "Contents/XPCServices/BackgroundEngineSteamCMDRunner.xpc",
                "com.lamppkk.backgroundengine.steamcmd-runner"
            ),
            (
                "Contents/Resources/Background Engine.saver",
                "com.lamppkk.backgroundengine.screensaver"
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
                    "CFBundleShortVersionString": "0.2.0-alpha.1",
                    "CFBundleVersion": "6"
                ],
                to: plist
            )
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
        build: String = "6"
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
