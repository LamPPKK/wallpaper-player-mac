import Foundation
import XCTest

final class RuntimeEmbeddingScriptTests: XCTestCase {
    func testEmbeddingReplacesOnlyManagedRuntimeDirectories() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try writeOldRuntimeMarkers(in: fixture.resources)
        let unrelated = fixture.resources.appending(path: "keep-me.txt")
        try "unrelated\n".write(to: unrelated, atomically: true, encoding: .utf8)

        let result = try run(
            "/bin/bash",
            arguments: [
                testRepositoryPath("Scripts/embed-app-runtimes.sh"),
                fixture.resources.path,
                fixture.ffmpegRuntime.path,
                fixture.rendererRuntime.path,
                fixture.architecture
            ]
        )

        XCTAssertEqual(result.status, 0, result.standardError)
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "unrelated\n")
        XCTAssertTrue(FileManager.default.isExecutableFile(
            atPath: fixture.resources.appending(path: "MediaTools/ffmpeg").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.resources.appending(path: "FFmpeg-Source/ffmpeg-9.0.1.tar.xz").path
        ))
        XCTAssertTrue(FileManager.default.isExecutableFile(
            atPath: fixture.resources
                .appending(path: "Renderers/background-engine-scene-renderer").path
        ))
        for name in ["MediaTools", "FFmpeg-Source", "Renderers"] {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: fixture.resources.appending(path: "\(name)/old-marker").path
            ))
        }
        let remainingNames = try FileManager.default.contentsOfDirectory(atPath: fixture.resources.path)
        XCTAssertFalse(remainingNames.contains { $0.hasPrefix(".background-engine-runtime-") })
    }

    func testEmbeddingRefreshesRendererInventoryAfterAdHocSigning() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let sourceInventory = fixture.rendererRuntime.appending(path: "macho-slice-digests.tsv")
        let sourceManifest = fixture.rendererRuntime.appending(path: "renderer-build-manifest.tsv")
        let originalInventory = try Data(contentsOf: sourceInventory)
        let originalManifest = try Data(contentsOf: sourceManifest)

        let result = try run(
            "/bin/bash",
            arguments: [
                testRepositoryPath("Scripts/embed-app-runtimes.sh"),
                fixture.resources.path,
                fixture.ffmpegRuntime.path,
                fixture.rendererRuntime.path,
                fixture.architecture
            ],
            environment: ["RUNTIME_SIGN_IDENTITY": "-"]
        )
        XCTAssertEqual(result.status, 0, result.standardError)
        guard result.status == 0 else { return }

        let installedRuntime = fixture.resources.appending(path: "Renderers")
        // Adding Hardened Runtime changes the signed slice bytes. The app must
        // receive a newly bound inventory without changing the source artifact.
        XCTAssertNotEqual(
            try Data(contentsOf: installedRuntime.appending(path: "macho-slice-digests.tsv")),
            originalInventory
        )
        XCTAssertNotEqual(
            try Data(contentsOf: installedRuntime.appending(path: "renderer-build-manifest.tsv")),
            originalManifest
        )
        XCTAssertEqual(try Data(contentsOf: sourceInventory), originalInventory)
        XCTAssertEqual(try Data(contentsOf: sourceManifest), originalManifest)

        let verified = try run(
            "/bin/bash",
            arguments: [
                testRepositoryPath("Scripts/verify-renderer-runtime.sh"),
                installedRuntime.path,
                "arm64", "x86_64"
            ]
        )
        XCTAssertEqual(verified.status, 0, verified.standardError)
        let remainingNames = try FileManager.default.contentsOfDirectory(atPath: fixture.resources.path)
        XCTAssertFalse(remainingNames.contains { $0.hasPrefix(".background-engine-runtime-") })
    }

    func testNativeDebugWrapperEmbedsUniversalSceneRenderer() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try run(
            "/bin/bash",
            arguments: [testRepositoryPath("Scripts/embed-app-runtimes-xcode.sh")],
            environment: [
                "ACTION": "build",
                "CONFIGURATION": "Debug",
                "CODE_SIGNING_ALLOWED": "NO",
                "ARCHS": fixture.architecture,
                "TARGET_BUILD_DIR": fixture.root.appending(path: "Product").path,
                "UNLOCALIZED_RESOURCES_FOLDER_PATH": "Background Engine.app/Contents/Resources",
                "BACKGROUND_ENGINE_FFMPEG_RUNTIME_DIR": fixture.ffmpegRuntime.path,
                "BACKGROUND_ENGINE_SCENE_RENDERER_RUNTIME_DIR": fixture.rendererRuntime.path
            ]
        )
        XCTAssertEqual(result.status, 0, result.standardError)
        guard result.status == 0 else { return }
        try requireSuccess(
            "/usr/bin/lipo",
            arguments: [
                fixture.resources.appending(path: "Renderers/background-engine-scene-renderer").path,
                "-verify_arch", "arm64", "x86_64"
            ]
        )
    }

    func testEmbeddingRejectsThinSceneRendererBeforeChangingResources() throws {
        let fixture = try makeFixture(rendererArchitectures: [try nativeArchitecture()])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeOldRuntimeMarkers(in: fixture.resources)

        let result = try run(
            "/bin/bash",
            arguments: [
                testRepositoryPath("Scripts/embed-app-runtimes.sh"),
                fixture.resources.path,
                fixture.ffmpegRuntime.path,
                fixture.rendererRuntime.path,
                fixture.architecture
            ]
        )
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.standardError.contains("architecture mismatch"), result.standardError)
        for name in ["MediaTools", "FFmpeg-Source", "Renderers"] {
            XCTAssertEqual(
                try String(contentsOf: fixture.resources.appending(path: "\(name)/old-marker"), encoding: .utf8),
                "old-\(name)\n"
            )
        }
    }

    func testFFmpegVerifierAcceptsUniversalRuntimeForOneRequestedDebugArchitecture() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let native = try nativeArchitecture()
        let other = native == "arm64" ? "x86_64" : "arm64"
        let runtime = root.appending(path: "universal-ffmpeg-runtime")
        try makeFFmpegRuntime(at: runtime, architectures: [native, other])

        let debugResult = try run(
            "/bin/bash",
            arguments: [
                testRepositoryPath("Scripts/verify-ffmpeg-runtime.sh"),
                runtime.path,
                native
            ]
        )
        XCTAssertEqual(debugResult.status, 0, debugResult.standardError)

        let archiveResult = try run(
            "/bin/bash",
            arguments: [
                testRepositoryPath("Scripts/verify-ffmpeg-runtime.sh"),
                runtime.path,
                "arm64", "x86_64"
            ]
        )
        XCTAssertEqual(archiveResult.status, 0, archiveResult.standardError)
    }

    func testFFmpegVerifierRejectsRuntimeBuiltAboveSupportedDeploymentTarget() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let architecture = try nativeArchitecture()
        let runtime = root.appending(path: "future-ffmpeg-runtime")
        try makeFFmpegRuntime(
            at: runtime,
            architectures: [architecture],
            deploymentTarget: "15.0"
        )

        let result = try run(
            "/bin/bash",
            arguments: [
                testRepositoryPath("Scripts/verify-ffmpeg-runtime.sh"),
                runtime.path,
                architecture
            ]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.standardError.contains("above the supported 14.0 target"), result.standardError)
    }

    func testEmbeddingRejectsMissingAndSymlinkDestinationsWithoutChangingResources() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appending(path: "Fixture.app/Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let sentinel = resources.appending(path: "sentinel")
        try Data("original".utf8).write(to: sentinel)

        let missing = try run(
            "/bin/bash",
            arguments: [
                testRepositoryPath("Scripts/embed-app-runtimes.sh"),
                resources.path,
                root.appending(path: "missing-ffmpeg").path,
                root.appending(path: "missing-renderer").path,
                try nativeArchitecture()
            ]
        )
        XCTAssertNotEqual(missing.status, 0)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("original".utf8))

        let link = root.appending(path: "LinkedResources")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: resources)
        let unsafe = try run(
            "/bin/bash",
            arguments: [
                testRepositoryPath("Scripts/embed-app-runtimes.sh"),
                link.path,
                root.path,
                root.path,
                try nativeArchitecture()
            ]
        )
        XCTAssertNotEqual(unsafe.status, 0)
        XCTAssertTrue(unsafe.standardError.contains("unsafe"), unsafe.standardError)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("original".utf8))
    }

    func testEmbeddingRestoresExistingRuntimeDirectoriesWhenReplacementFails() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeOldRuntimeMarkers(in: fixture.resources)
        let unrelated = fixture.resources.appending(path: "unrelated")
        try Data("preserved".utf8).write(to: unrelated)

        let fakeTools = fixture.root.appending(path: "fake-tools")
        try FileManager.default.createDirectory(at: fakeTools, withIntermediateDirectories: true)
        let fakeMove = fakeTools.appending(path: "mv")
        try """
        #!/bin/bash
        case "${2:-}" in
          *.app/Contents/Resources/FFmpeg-Source)
            if [ ! -e "${FAIL_MV_MARKER:-}" ]; then
              /usr/bin/touch "$FAIL_MV_MARKER"
              exit 73
            fi
            ;;
        esac
        exec /bin/mv "$@"
        """.write(to: fakeMove, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeMove.path
        )
        let marker = fixture.root.appending(path: "move-failed")
        let result = try run(
            "/bin/bash",
            arguments: [
                testRepositoryPath("Scripts/embed-app-runtimes.sh"),
                fixture.resources.path,
                fixture.ffmpegRuntime.path,
                fixture.rendererRuntime.path,
                fixture.architecture
            ],
            environment: [
                "PATH": "\(fakeTools.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "FAIL_MV_MARKER": marker.path
            ]
        )

        XCTAssertNotEqual(result.status, 0)
        for name in ["MediaTools", "FFmpeg-Source", "Renderers"] {
            XCTAssertEqual(
                try String(
                    contentsOf: fixture.resources.appending(path: "\(name)/old-marker"),
                    encoding: .utf8
                ),
                "old-\(name)\n"
            )
        }
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("preserved".utf8))
    }

    func testEmbeddingRetainsRecoveryBackupWhenReplacementRemovalFails() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeOldRuntimeMarkers(in: fixture.resources)
        let fakeTools = fixture.root.appending(path: "fake-removal-tools")
        try FileManager.default.createDirectory(at: fakeTools, withIntermediateDirectories: true)
        let fakeMove = fakeTools.appending(path: "mv")
        try #"""
        #!/bin/bash
        case "${1:-}:${2:-}" in
          *.background-engine-runtime-stage.*/FFmpeg-Source:*.app/Contents/Resources/FFmpeg-Source)
            exit 73 ;;
        esac
        exec /bin/mv "$@"
        """#.write(to: fakeMove, atomically: true, encoding: .utf8)
        let fakeRemove = fakeTools.appending(path: "rm")
        try #"""
        #!/bin/bash
        if [ "${1:-}" = "-rf" ] && [ "${2:-}" = "$REFUSE_REMOVAL" ]; then
          exit 74
        fi
        exec /bin/rm "$@"
        """#.write(to: fakeRemove, atomically: true, encoding: .utf8)
        for tool in [fakeMove, fakeRemove] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }
        let result = try run(
            "/bin/bash",
            arguments: [
                testRepositoryPath("Scripts/embed-app-runtimes.sh"),
                fixture.resources.path,
                fixture.ffmpegRuntime.path,
                fixture.rendererRuntime.path,
                fixture.architecture
            ],
            environment: [
                "PATH": "\(fakeTools.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "REFUSE_REMOVAL": try physicalPath(
                    fixture.resources.appending(path: "MediaTools")
                )
            ]
        )
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.standardError.contains("replacement remains"), result.standardError)
        XCTAssertTrue(result.standardError.contains("Runtime rollback was incomplete"), result.standardError)
        let recoveryDirectories = try FileManager.default.contentsOfDirectory(
            at: fixture.resources, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".background-engine-runtime-backup.") }
        XCTAssertEqual(recoveryDirectories.count, 1)
        let recovery = try XCTUnwrap(recoveryDirectories.first)
        XCTAssertEqual(
            try String(contentsOf: recovery.appending(path: "MediaTools/old-marker"), encoding: .utf8),
            "old-MediaTools\n"
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.resources.appending(path: "MediaTools/MediaTools/old-marker").path
        ), "A failed rollback must not nest the original inside an incomplete replacement.")
        for name in ["FFmpeg-Source", "Renderers"] {
            XCTAssertEqual(
                try String(contentsOf: fixture.resources.appending(path: "\(name)/old-marker"), encoding: .utf8),
                "old-\(name)\n"
            )
        }
    }

    func testEmbeddingRetainsRecoveryBackupWhenRollbackMoveAlsoFails() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeOldRuntimeMarkers(in: fixture.resources)

        let fakeTools = fixture.root.appending(path: "fake-rollback-tools")
        try FileManager.default.createDirectory(at: fakeTools, withIntermediateDirectories: true)
        let fakeMove = fakeTools.appending(path: "mv")
        try """
        #!/bin/bash
        source_path="${1:-}"
        destination_path="${2:-}"
        case "$source_path:$destination_path" in
          *.background-engine-runtime-stage.*/FFmpeg-Source:*.app/Contents/Resources/FFmpeg-Source)
            exit 73
            ;;
          *.background-engine-runtime-backup.*/MediaTools:*.app/Contents/Resources/MediaTools)
            exit 74
            ;;
        esac
        exec /bin/mv "$@"
        """.write(to: fakeMove, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeMove.path
        )

        let result = try run(
            "/bin/bash",
            arguments: [
                testRepositoryPath("Scripts/embed-app-runtimes.sh"),
                fixture.resources.path,
                fixture.ffmpegRuntime.path,
                fixture.rendererRuntime.path,
                fixture.architecture
            ],
            environment: ["PATH": "\(fakeTools.path):/usr/bin:/bin:/usr/sbin:/sbin"]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.standardError.contains("Runtime rollback was incomplete"), result.standardError)
        let recoveryDirectories = try FileManager.default.contentsOfDirectory(
            at: fixture.resources,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".background-engine-runtime-backup.") }
        XCTAssertEqual(recoveryDirectories.count, 1)
        let preservedRuntime = try XCTUnwrap(recoveryDirectories.first)
            .appending(path: "MediaTools/old-marker")
        XCTAssertEqual(
            try String(contentsOf: preservedRuntime, encoding: .utf8),
            "old-MediaTools\n"
        )
        for name in ["FFmpeg-Source", "Renderers"] {
            XCTAssertEqual(
                try String(
                    contentsOf: fixture.resources.appending(path: "\(name)/old-marker"),
                    encoding: .utf8
                ),
                "old-\(name)\n"
            )
        }
    }

    func testXcodeWrapperSkipsDebugOnlyWhenBothSettingsAreAbsentAndFailsClosedOtherwise() throws {
        let wrapper = testRepositoryPath("Scripts/embed-app-runtimes-xcode.sh")
        let debug = try run(
            "/bin/bash",
            arguments: [wrapper],
            environment: wrapperEnvironment(configuration: "Debug")
        )
        XCTAssertEqual(debug.status, 0, debug.standardError)
        XCTAssertTrue(debug.standardError.contains("warning:"), debug.standardError)

        let release = try run(
            "/bin/bash",
            arguments: [wrapper],
            environment: wrapperEnvironment(configuration: "Release")
        )
        XCTAssertNotEqual(release.status, 0)
        XCTAssertTrue(release.standardError.contains("required"), release.standardError)

        var debugArchiveEnvironment = wrapperEnvironment(configuration: "Debug")
        debugArchiveEnvironment["ACTION"] = "archive"
        let debugArchive = try run(
            "/bin/bash",
            arguments: [wrapper],
            environment: debugArchiveEnvironment
        )
        XCTAssertNotEqual(debugArchive.status, 0)

        var partialEnvironment = wrapperEnvironment(configuration: "Debug")
        partialEnvironment["BACKGROUND_ENGINE_FFMPEG_RUNTIME_DIR"] = "/private/tmp/ffmpeg"
        let partial = try run(
            "/bin/bash",
            arguments: [wrapper],
            environment: partialEnvironment
        )
        XCTAssertNotEqual(partial.status, 0)
        XCTAssertTrue(partial.standardError.contains("configured together"), partial.standardError)

        var analyzeEnvironment = partialEnvironment
        analyzeEnvironment["CONFIGURATION"] = "Release"
        analyzeEnvironment["ACTION"] = "analyze"
        let analyze = try run(
            "/bin/bash",
            arguments: [wrapper],
            environment: analyzeEnvironment
        )
        XCTAssertEqual(analyze.status, 0, analyze.standardError)
        XCTAssertTrue(analyze.standardOutput.contains("Analyze"), analyze.standardOutput)

        analyzeEnvironment["ACTION"] = "indexbuild"
        let indexBuild = try run(
            "/bin/bash",
            arguments: [wrapper],
            environment: analyzeEnvironment
        )
        XCTAssertEqual(indexBuild.status, 0, indexBuild.standardError)
        XCTAssertTrue(indexBuild.standardOutput.contains("indexing"), indexBuild.standardOutput)
    }

    func testXcodeWrapperRemovesOnlyStaleManagedDebugRuntimes() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let resourcesRelativePath = "Fixture.app/Contents/Resources"
        let resources = root.appending(path: resourcesRelativePath)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        for name in ["MediaTools", "FFmpeg-Source", "Renderers"] {
            let managed = resources.appending(path: name)
            try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
            try Data("stale".utf8).write(to: managed.appending(path: "marker"))
        }
        let unrelated = resources.appending(path: "BackgroundEngine_BackgroundEngineApp.bundle")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data("preserved".utf8).write(to: unrelated.appending(path: "marker"))

        var environment = wrapperEnvironment(configuration: "Debug")
        environment["TARGET_BUILD_DIR"] = root.path
        environment["UNLOCALIZED_RESOURCES_FOLDER_PATH"] = resourcesRelativePath
        let result = try run(
            "/bin/bash",
            arguments: [testRepositoryPath("Scripts/embed-app-runtimes-xcode.sh")],
            environment: environment
        )

        XCTAssertEqual(result.status, 0, result.standardError)
        for name in ["MediaTools", "FFmpeg-Source", "Renderers"] {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: resources.appending(path: name).path
            ))
        }
        XCTAssertEqual(
            try Data(contentsOf: unrelated.appending(path: "marker")),
            Data("preserved".utf8)
        )
    }

    private func makeFixture(rendererArchitectures: [String] = ["arm64", "x86_64"]) throws -> RuntimeEmbeddingFixture {
        let root = try makeTempDirectory()
        let resources = root.appending(path: "Product/Background Engine.app/Contents/Resources")
        let ffmpegRuntime = root.appending(path: "ffmpeg-runtime")
        let rendererRuntime = root.appending(path: "renderer-runtime")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let architecture = try nativeArchitecture()
        try makeFFmpegRuntime(at: ffmpegRuntime, architectures: [architecture])
        try makeRendererRuntime(at: rendererRuntime, architectures: rendererArchitectures, root: root)
        return RuntimeEmbeddingFixture(
            root: root,
            resources: resources,
            ffmpegRuntime: ffmpegRuntime,
            rendererRuntime: rendererRuntime,
            architecture: architecture
        )
    }

    private func makeFFmpegRuntime(
        at runtime: URL,
        architectures: [String],
        deploymentTarget: String = "14.0"
    ) throws {
        let mediaTools = runtime.appending(path: "MediaTools")
        let source = runtime.appending(path: "Source")
        try FileManager.default.createDirectory(at: mediaTools, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let sourceFile = runtime.deletingLastPathComponent().appending(path: "fake-ffmpeg.c")
        try """
        #include <stdio.h>
        #include <string.h>
        #ifndef PROGRAM_NAME
        #define PROGRAM_NAME "ffmpeg"
        #endif
        int main(int argc, char **argv) {
          for (int index = 1; index < argc; index += 1) {
            if (strcmp(argv[index], "-version") == 0) {
              printf("%s version 9.0.1 fixture\\n", PROGRAM_NAME);
              return 0;
            }
            if (strcmp(argv[index], "-protocols") == 0) {
              printf("Supported file protocols:\\nInput:\\n  file\\n  pipe\\n  fd\\n");
              return 0;
            }
          }
          return 0;
        }
        """.write(to: sourceFile, atomically: true, encoding: .utf8)
        for program in ["ffmpeg", "ffprobe"] {
            let output = mediaTools.appending(path: program)
            let thinBinaries = try architectures.map { architecture in
                let thin = runtime.deletingLastPathComponent()
                    .appending(path: "\(program)-\(architecture)")
                try requireSuccess(
                    "/usr/bin/clang",
                    arguments: [
                        "-arch", architecture,
                        "-mmacosx-version-min=\(deploymentTarget)",
                        "-DPROGRAM_NAME=\"\(program)\"",
                        sourceFile.path,
                        "-o", thin.path
                    ]
                )
                return thin
            }
            if thinBinaries.count == 1 {
                try FileManager.default.moveItem(at: thinBinaries[0], to: output)
            } else {
                try requireSuccess(
                    "/usr/bin/lipo",
                    arguments: ["-create"] + thinBinaries.map(\.path) + ["-output", output.path]
                )
                for thin in thinBinaries {
                    try FileManager.default.removeItem(at: thin)
                }
            }
        }
        try Data("fixture archive".utf8).write(to: source.appending(path: "ffmpeg-9.0.1.tar.xz"))
        try Data("fixture license".utf8).write(to: source.appending(path: "FFmpeg-LICENSE.md"))
        try """
        Build-ID: ffmpeg-9.0.1-background-engine-1
        Source: https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz
        Architectures: \(architectures.joined(separator: " "))
        Configure flags:
          --disable-protocols
          --enable-protocol=file,pipe,fd
        """.write(to: source.appending(path: "build-flags.txt"), atomically: true, encoding: .utf8)
    }

    private func makeRendererRuntime(at runtime: URL, architectures: [String], root: URL) throws {
        let libraryDirectory = runtime.appending(path: "lib")
        try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        let librarySource = root.appending(path: "fixture-library.c")
        let executableSource = root.appending(path: "fixture-renderer.c")
        try "void fixture(void) {}\n".write(
            to: librarySource,
            atomically: true,
            encoding: .utf8
        )
        let provenance = try run(
            "/usr/bin/perl",
            arguments: [
                testRepositoryPath("Scripts/renderer-source-fingerprint.pl"),
                testRepositoryPath("ExternalRenderers/wallpaperengine-mac-renderer"),
                "--binding"
            ]
        )
        guard provenance.status == 0 else {
            throw RuntimeEmbeddingTestError.commandFailed(provenance.standardError)
        }
        let provenanceLiteral = provenance.standardOutput
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
          return 0;
        }
        """.write(to: executableSource, atomically: true, encoding: .utf8)
        let library = libraryDirectory.appending(path: "libFixture.dylib")
        let renderer = runtime.appending(path: "background-engine-scene-renderer")
        var librarySlices: [URL] = []
        var rendererSlices: [URL] = []
        for architecture in architectures {
            let librarySlice = root.appending(path: "fixture-library-\(architecture).dylib")
            let rendererSlice = root.appending(path: "fixture-renderer-\(architecture)")
            try requireSuccess(
                "/usr/bin/clang",
                arguments: [
                    "-arch", architecture,
                    "-mmacosx-version-min=14.0",
                    "-dynamiclib", librarySource.path,
                    "-install_name", "@executable_path/lib/libFixture.dylib",
                    "-Wl,-rpath,@executable_path/lib/",
                    "-o", librarySlice.path
                ]
            )
            try requireSuccess(
                "/usr/bin/clang",
                arguments: [
                    "-arch", architecture,
                    "-mmacosx-version-min=14.0",
                    executableSource.path, librarySlice.path,
                    "-Wl,-rpath,@executable_path/lib/",
                    "-o", rendererSlice.path
                ]
            )
            librarySlices.append(librarySlice)
            rendererSlices.append(rendererSlice)
        }
        for (slices, destination) in [(librarySlices, library), (rendererSlices, renderer)] {
            if slices.count == 1 {
                try FileManager.default.copyItem(at: slices[0], to: destination)
            } else {
                try requireSuccess(
                    "/usr/bin/lipo",
                    arguments: ["-create"] + slices.map(\.path) + ["-output", destination.path]
                )
            }
        }
        for binary in [library, renderer] {
            try requireSuccess(
                "/usr/bin/codesign",
                arguments: ["--force", "--sign", "-", binary.path]
            )
        }
        try """
        homebrew-brew\t0942cac2eda7648d4857f4e5da60f1de303b6818
        homebrew-core\t229d435d9fc7d166b417e94ce66db01d6b34cf97
        deployment-target\tmacos-14
        formula\tfixture\t1.0\t\(String(repeating: "a", count: 64))
        bottle\tfixture\tarm64\tarm64_sonoma\t\(String(repeating: "b", count: 64))
        bottle\tfixture\tx86_64\tsonoma\t\(String(repeating: "c", count: 64))

        """.write(
            to: runtime.appending(path: "dependencies.lock.tsv"),
            atomically: true,
            encoding: .utf8
        )
        try requireSuccess(
            "/bin/bash",
            arguments: [
                testRepositoryPath("Scripts/write-renderer-build-manifest.sh"),
                runtime.path,
                architectures.sorted().joined(separator: ",")
            ]
        )
    }

    private func writeOldRuntimeMarkers(in resources: URL) throws {
        for name in ["MediaTools", "FFmpeg-Source", "Renderers"] {
            let directory = resources.appending(path: name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "old-\(name)\n".write(
                to: directory.appending(path: "old-marker"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    private func wrapperEnvironment(configuration: String) -> [String: String] {
        [
            "ACTION": "build",
            "CONFIGURATION": configuration,
            "BACKGROUND_ENGINE_FFMPEG_RUNTIME_DIR": "",
            "BACKGROUND_ENGINE_SCENE_RENDERER_RUNTIME_DIR": ""
        ]
    }

    private func nativeArchitecture() throws -> String {
        let result = try run("/usr/bin/uname", arguments: ["-m"])
        guard result.status == 0 else {
            throw RuntimeEmbeddingTestError.commandFailed(result.standardError)
        }
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeTempDirectory() throws -> URL {
        let requested = FileManager.default.temporaryDirectory
            .appending(path: "Background-Engine-embedding-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true)
        return requested.resolvingSymlinksInPath()
    }

    private func requireSuccess(_ executable: String, arguments: [String]) throws {
        let result = try run(executable, arguments: arguments)
        guard result.status == 0 else {
            XCTFail("Command failed: \(executable) \(arguments.joined(separator: " "))\n\(result.standardError)")
            throw RuntimeEmbeddingTestError.commandFailed(result.standardError)
        }
    }

    private func run(
        _ executable: String,
        arguments: [String],
        environment additions: [String: String] = [:]
    ) throws -> RuntimeEmbeddingProcessResult {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(additions) { _, addition in addition }
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        return RuntimeEmbeddingProcessResult(
            status: process.terminationStatus,
            standardOutput: String(
                decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ),
            standardError: String(
                decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }

    private func physicalPath(_ url: URL) throws -> String {
        let result = try run("/bin/realpath", arguments: [url.path])
        guard result.status == 0 else {
            throw RuntimeEmbeddingTestError.commandFailed(result.standardError)
        }
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct RuntimeEmbeddingFixture {
    let root: URL
    let resources: URL
    let ffmpegRuntime: URL
    let rendererRuntime: URL
    let architecture: String
}

private struct RuntimeEmbeddingProcessResult {
    let status: Int32
    let standardOutput: String
    let standardError: String
}

private enum RuntimeEmbeddingTestError: Error {
    case commandFailed(String)
}
