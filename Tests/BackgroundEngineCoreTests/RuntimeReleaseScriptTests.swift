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
            XCTAssertTrue(workflow.contains("actions/checkout@v7.0.1"))
            XCTAssertTrue(workflow.contains("actions/upload-artifact@v7.0.1"))
            XCTAssertTrue(workflow.contains("actions/download-artifact@v8.0.1"))
            XCTAssertTrue(workflow.contains("brew install gnupg nasm"))
            XCTAssertTrue(workflow.contains("chmod 755 ffmpeg-runtime/MediaTools/ffmpeg ffmpeg-runtime/MediaTools/ffprobe"))
        }

        let ffmpegBuildScript = try String(repositoryFile: "Scripts/build-ffmpeg-runtime.sh")
        XCTAssertTrue(ffmpegBuildScript.contains("be_require_tools nasm"))
        XCTAssertTrue(ffmpegBuildScript.contains("--retry-all-errors"))
        XCTAssertTrue(ffmpegBuildScript.contains("--retry 5"))
        XCTAssertTrue(ffmpegBuildScript.contains("--retry-max-time 300"))
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

    private func makeSyntheticRendererRuntime(
        rpaths: [String],
        rewrittenRpaths: [(String, String)] = [],
        architecture: String? = nil
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

        let library = libraryDirectory.appending(path: "libFixture.dylib")
        let renderer = runtime.appending(path: "background-engine-scene-renderer")
        let architectureArguments = architecture.map { ["-arch", $0] } ?? []
        var libraryArguments = architectureArguments + [
            "-dynamiclib",
            librarySource.path,
            "-install_name",
            "@executable_path/lib/libFixture.dylib",
            "-o",
            library.path
        ]
        var rendererArguments = architectureArguments + [mainSource.path, library.path, "-o", renderer.path]
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
