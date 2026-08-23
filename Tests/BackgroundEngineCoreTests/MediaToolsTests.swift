import Foundation
import AVFoundation
import Darwin
import XCTest
@testable import BackgroundEngineCore

final class MediaToolsTests: XCTestCase {
    func testResolverPrefersBundledToolsAndReportsReady() throws {
        let resources = try Fixture.makeTempDirectory()
        let mediaTools = resources.appending(path: "MediaTools")
        try FileManager.default.createDirectory(at: mediaTools, withIntermediateDirectories: true)
        for name in ["ffmpeg", "ffprobe"] {
            let tool = mediaTools.appending(path: name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: tool)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }
        let resolver = MediaToolResolver(
            bundleResourceURL: resources,
            environment: [:],
            allowDevelopmentFallback: false
        )

        XCTAssertEqual(resolver.resolve(.ffmpeg).source, .bundled)
        XCTAssertEqual(resolver.resolve(.ffprobe).source, .bundled)
        XCTAssertEqual(resolver.runtimeHealth().availability, .available)
    }

    func testReleasePolicyDoesNotFallBackToHomebrew() {
        let resolver = MediaToolResolver(
            bundleResourceURL: nil,
            environment: ["BACKGROUND_ENGINE_FFMPEG": "/opt/homebrew/bin/ffmpeg"],
            allowDevelopmentFallback: false
        )

        XCTAssertEqual(resolver.resolve(.ffmpeg).source, .unavailable)
        XCTAssertNil(resolver.resolve(.ffmpeg).path)
    }

    func testFFprobeJSONDecodingClassifiesStreams() throws {
        let json = #"""
        {
          "streams": [
            {"index": 0, "codec_name": "h264", "codec_type": "video", "width": 1920, "height": 1080},
            {"index": 1, "codec_name": "aac", "codec_type": "audio", "sample_rate": "48000", "channels": 2}
          ],
          "format": {"format_name": "mov,mp4", "duration": "20.250", "size": "1024"}
        }
        """#

        let report = try JSONDecoder().decode(MediaProbeReport.self, from: Data(json.utf8))

        XCTAssertTrue(report.hasVideo)
        XCTAssertTrue(report.hasAudio)
        XCTAssertEqual(report.durationSeconds, 20.25)
    }

    func testAttachedPictureStreamIsNotPlayableVideoContent() throws {
        let json = #"""
        {
          "streams": [
            {
              "index": 0,
              "codec_name": "mp3",
              "codec_type": "audio",
              "sample_rate": "44100",
              "channels": 2
            },
            {
              "index": 1,
              "codec_name": "mjpeg",
              "codec_type": "video",
              "width": 600,
              "height": 600,
              "disposition": {"attached_pic": 1}
            }
          ],
          "format": {"format_name": "mp3", "duration": "180.0"}
        }
        """#

        let report = try JSONDecoder().decode(MediaProbeReport.self, from: Data(json.utf8))

        XCTAssertFalse(report.hasVideo)
        XCTAssertTrue(report.hasAudio)
    }

    func testContentProbeRejectsAudioWhoseOnlyVideoStreamIsCoverArt() throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mediaTools = root.appending(path: "MediaTools", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mediaTools, withIntermediateDirectories: true)
        let ffprobe = mediaTools.appending(path: "ffprobe")
        try Data(#"""
        #!/bin/sh
        printf '%s' '{"streams":[{"index":0,"codec_name":"mp3","codec_type":"audio"},{"index":1,"codec_name":"mjpeg","codec_type":"video","width":600,"height":600,"disposition":{"attached_pic":1}}],"format":{"format_name":"mp3","duration":"180.0"}}'
        """#.utf8).write(to: ffprobe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffprobe.path)
        let input = root.appending(path: "audio-with-cover.mp3")
        try Data("not-a-video".utf8).write(to: input)
        let resolver = MediaToolResolver(
            bundleResourceURL: root,
            environment: [:],
            allowDevelopmentFallback: false
        )

        let classification = MediaContentProbe(mediaProbe: MediaProbe(resolver: resolver))
            .classify(input, metadataType: "video")

        XCTAssertEqual(classification.kind, .unknown)
        XCTAssertEqual(classification.supportStatus, .unsupported)
    }

    func testContentProbeRunsFFprobeOnlyOncePerVideoClassification() throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mediaTools = root.appending(path: "MediaTools")
        try FileManager.default.createDirectory(at: mediaTools, withIntermediateDirectories: true)
        let invocationLog = root.appending(path: "ffprobe-invocations")
        let ffprobe = mediaTools.appending(path: "ffprobe")
        try Data("""
        #!/bin/sh
        printf 'probe\\n' >> "\(invocationLog.path)"
        printf '%s' '{"streams":[{"index":0,"codec_name":"vp9","codec_type":"video","width":64,"height":64}],"format":{"format_name":"matroska","duration":"1.0"}}'
        """.utf8).write(to: ffprobe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffprobe.path)
        let input = root.appending(path: "wallpaper.asset")
        try Data("video fixture".utf8).write(to: input)
        let resolver = MediaToolResolver(
            bundleResourceURL: root,
            environment: [:],
            allowDevelopmentFallback: false
        )

        let classification = MediaContentProbe(mediaProbe: MediaProbe(resolver: resolver)).classify(input)

        XCTAssertEqual(classification.kind, .video)
        XCTAssertEqual(classification.supportStatus, .needsConversion)
        let invocations = try String(contentsOf: invocationLog, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
        XCTAssertEqual(invocations.count, 1)
    }

    func testVideoConversionUsesVideoToolboxAndPreservesOptionalAudio() {
        let input = URL(filePath: "/tmp/input.mkv")
        let output = URL(filePath: "/tmp/output.mp4")
        let arguments = VideoConverter.conversionArguments(input: input, output: output)

        XCTAssertTrue(arguments.contains("h264_videotoolbox"))
        XCTAssertTrue(arguments.contains("0:a?"))
        XCTAssertTrue(arguments.contains("+faststart"))
        XCTAssertFalse(arguments.contains("libx264"))
    }

    func testVideoConversionCacheKeyIncludesToolBuildAndResolution() {
        let key = VideoConversionCacheKey(
            contentHash: "0123456789abcdef0123456789abcdef",
            mediaBuildID: "ffmpeg-test",
            width: 1920,
            height: 1080
        )

        XCTAssertEqual(key.fileName, "0123456789abcdef01234567-ffmpeg-test-1920x1080.mp4")
    }

    func testMediaProbeTimesOutAndKillsNoisyChild() throws {
        let resources = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: resources) }
        let mediaTools = resources.appending(path: "MediaTools")
        try FileManager.default.createDirectory(at: mediaTools, withIntermediateDirectories: true)
        let ffprobe = mediaTools.appending(path: "ffprobe")
        let parentPIDFile = resources.appending(path: "ffprobe-parent.pid")
        let childPIDFile = resources.appending(path: "ffprobe-child.pid")
        try Data("""
        #!/bin/sh
        trap '' TERM
        echo $$ > "\(parentPIDFile.path)"
        /bin/sh -c 'trap "" TERM; while :; do /bin/sleep 1; done' child &
        echo $! > "\(childPIDFile.path)"
        while :; do printf 'noisy-probe-output' >&2; /bin/sleep 0.01; done
        """.utf8)
            .write(to: ffprobe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffprobe.path)
        let input = resources.appending(path: "input.bin")
        try Data([0]).write(to: input)
        let resolver = MediaToolResolver(
            bundleResourceURL: resources,
            environment: [:],
            allowDevelopmentFallback: false
        )

        XCTAssertThrowsError(try MediaProbe(resolver: resolver).inspect(input, timeout: 5)) { error in
            guard case ConversionError.ffprobeTimedOut = error else {
                return XCTFail("Expected ffprobeTimedOut, got \(error)")
            }
        }
        let parentPID = try processIdentifier(at: parentPIDFile)
        let childPID = try processIdentifier(at: childPIDFile)
        XCTAssertEqual(Darwin.kill(parentPID, 0), -1)
        XCTAssertEqual(Darwin.kill(childPID, 0), -1)
    }

    func testVideoConversionTimeoutKillsProcessGroupAndLeavesNoPartialOutput() async throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let parentPIDFile = root.appending(path: "ffmpeg-parent.pid")
        let childPIDFile = root.appending(path: "ffmpeg-child.pid")
        let converter = try makeFakeVideoConverter(
            root: root,
            ffmpegScript: """
            #!/bin/sh
            trap '' TERM
            for argument do output=$argument; done
            printf partial > "$output"
            echo $$ > "\(parentPIDFile.path)"
            /bin/sh -c 'trap "" TERM; echo $$ > "$1"; while :; do /bin/sleep 1; done' child "\(childPIDFile.path)" &
            while :; do printf 'noisy-ffmpeg-output' >&2; /bin/sleep 0.01; done
            """
        )
        let input = root.appending(path: "input.mkv")
        let output = root.appending(path: "output.mp4")
        try Data([0]).write(to: input)

        do {
            try await converter.convertToPlayableVideo(
                input: input,
                output: output,
                timeout: .milliseconds(200)
            )
            XCTFail("Expected FFmpeg conversion timeout")
        } catch ConversionError.ffmpegTimedOut {
            // Expected.
        } catch {
            XCTFail("Expected ffmpegTimedOut, got \(error)")
        }

        let parentPID = try processIdentifier(at: parentPIDFile)
        let childPID = try processIdentifier(at: childPIDFile)
        await assertProcessExited(parentPID)
        await assertProcessExited(childPID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(try incomingConversionFiles(in: root).isEmpty)
    }

    func testCancellingVideoConversionReapsDescendantsAndPreservesExistingOutput() async throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let parentPIDFile = root.appending(path: "ffmpeg-parent.pid")
        let childPIDFile = root.appending(path: "ffmpeg-child.pid")
        let converter = try makeFakeVideoConverter(
            root: root,
            ffmpegScript: """
            #!/bin/sh
            trap '' TERM
            for argument do output=$argument; done
            printf partial > "$output"
            echo $$ > "\(parentPIDFile.path)"
            /bin/sh -c 'trap "" TERM; echo $$ > "$1"; while :; do /bin/sleep 1; done' child "\(childPIDFile.path)" &
            while :; do /bin/sleep 1; done
            """
        )
        let input = root.appending(path: "input.avi")
        let output = root.appending(path: "output.mp4")
        try Data([0]).write(to: input)
        try Data("known-good".utf8).write(to: output)

        let conversion = Task {
            try await converter.convertToPlayableVideo(
                input: input,
                output: output,
                timeout: .seconds(30)
            )
        }
        defer { conversion.cancel() }
        try await waitForFile(parentPIDFile)
        try await waitForFile(childPIDFile)
        let parentPID = try processIdentifier(at: parentPIDFile)
        let childPID = try processIdentifier(at: childPIDFile)
        conversion.cancel()
        do {
            try await conversion.value
            XCTFail("Expected conversion cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        await assertProcessExited(parentPID)
        await assertProcessExited(childPID)
        XCTAssertEqual(try Data(contentsOf: output), Data("known-good".utf8))
        XCTAssertTrue(try incomingConversionFiles(in: root).isEmpty)
    }

    func testAsyncVideoConversionValidatesThenInstallsOutput() async throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let converter = try makeFakeVideoConverter(
            root: root,
            ffmpegScript: """
            #!/bin/sh
            for argument do output=$argument; done
            printf converted-video > "$output"
            """
        )
        let input = root.appending(path: "input.mkv")
        let output = root.appending(path: "output.mp4")
        try Data([0]).write(to: input)
        try Data("previous-video".utf8).write(to: output)

        try await converter.convertToPlayableVideo(
            input: input,
            output: output,
            timeout: .seconds(5)
        )

        XCTAssertEqual(try Data(contentsOf: output), Data("converted-video".utf8))
        XCTAssertTrue(try incomingConversionFiles(in: root).isEmpty)
    }

    func testSynchronousVideoConversionDoesNotDependOnCooperativeExecutor() async throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let converter = try makeFakeVideoConverter(
            root: root,
            ffmpegScript: """
            #!/bin/sh
            for argument do output=$argument; done
            printf synchronous-video > "$output"
            """
        )
        let input = root.appending(path: "input.avi")
        let output = root.appending(path: "output.mp4")
        try Data([0]).write(to: input)

        // This deliberately blocks the current cooperative-executor task. The
        // legacy CLI API must rely only on its dedicated process waiter thread.
        try converter.convertToPlayableVideo(input: input, output: output)

        XCTAssertEqual(try Data(contentsOf: output), Data("synchronous-video".utf8))
        XCTAssertTrue(try incomingConversionFiles(in: root).isEmpty)
    }

    func testCancellingVideoConversionDuringProbeReapsProbeGroupAndPreservesOutput() async throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let parentPIDFile = root.appending(path: "ffprobe-parent.pid")
        let childPIDFile = root.appending(path: "ffprobe-child.pid")
        let converter = try makeFakeVideoConverter(
            root: root,
            ffmpegScript: """
            #!/bin/sh
            for argument do output=$argument; done
            printf converted-video > "$output"
            """,
            ffprobeScript: """
            #!/bin/sh
            trap '' TERM
            echo $$ > "\(parentPIDFile.path)"
            /bin/sh -c 'trap "" TERM; echo $$ > "$1"; while :; do /bin/sleep 1; done' child "\(childPIDFile.path)" &
            while :; do /bin/sleep 1; done
            """
        )
        let input = root.appending(path: "input.mkv")
        let output = root.appending(path: "output.mp4")
        try Data([0]).write(to: input)
        try Data("known-good".utf8).write(to: output)

        let conversion = Task {
            try await converter.convertToPlayableVideo(
                input: input,
                output: output,
                timeout: .seconds(30)
            )
        }
        defer { conversion.cancel() }
        try await waitForFile(parentPIDFile)
        try await waitForFile(childPIDFile)
        let parentPID = try processIdentifier(at: parentPIDFile)
        let childPID = try processIdentifier(at: childPIDFile)
        conversion.cancel()
        do {
            try await conversion.value
            XCTFail("Expected conversion cancellation during ffprobe")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        await assertProcessExited(parentPID)
        await assertProcessExited(childPID)
        XCTAssertEqual(try Data(contentsOf: output), Data("known-good".utf8))
        XCTAssertTrue(try incomingConversionFiles(in: root).isEmpty)
    }

    func testAudioOnlyAssetIsNotClassifiedAsVideo() throws {
        let root = try Fixture.makeTempDirectory()
        let audioURL = root.appending(path: "audio-only.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
            buffer.frameLength = 4_410
            try file.write(from: buffer)
        }
        let resolver = MediaToolResolver(
            bundleResourceURL: nil,
            environment: [:],
            allowDevelopmentFallback: false
        )

        let classification = MediaContentProbe(mediaProbe: MediaProbe(resolver: resolver))
            .classify(audioURL, metadataType: "video")

        XCTAssertEqual(classification.kind, .unknown)
        XCTAssertEqual(classification.supportStatus, .unsupported)
    }

    func testContentProbeRecognizesHTMLAfterLongPreambleWithoutKnownExtension() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "wallpaper.asset")
        let source = String(repeating: "<!-- license -->\n", count: 512)
            + "<!doctype html><html><body>Wallpaper</body></html>"
        try Data(source.utf8).write(to: entrypoint)

        let classification = contentProbeWithoutExternalTools().classify(entrypoint)

        XCTAssertEqual(classification.kind, .web)
        XCTAssertEqual(classification.supportStatus, .playable)
    }

    func testContentProbeRecognizesUTF16WebWallpaper() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "wallpaper.data")
        var encoded = Data([0xFF, 0xFE])
        encoded.append(try XCTUnwrap(
            "<!doctype html><html><body>Wallpaper</body></html>".data(using: .utf16LittleEndian)
        ))
        try encoded.write(to: entrypoint)

        let classification = contentProbeWithoutExternalTools().classify(entrypoint)

        XCTAssertEqual(classification.kind, .web)
        XCTAssertEqual(classification.supportStatus, .playable)
    }

    func testDeclaredWebWallpaperAcceptsTextPreambleBeyondProbeWindow() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        let source = String(repeating: " ", count: WebWallpaperValidation.maximumProbeBytes + 1)
            + "<html><body>Wallpaper</body></html>"
        try Data(source.utf8).write(to: entrypoint)

        let classification = contentProbeWithoutExternalTools().classify(entrypoint, metadataType: "web")

        XCTAssertEqual(classification.kind, .web)
        XCTAssertEqual(classification.supportStatus, .playable)
    }

    func testDeclaredWebWallpaperAcceptsHTMLCommentBeyondProbeWindow() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "index.html")
        let source = "<!--" + String(repeating: " license ", count: 40_000)
            + "--><html><body>Wallpaper</body></html>"
        try Data(source.utf8).write(to: entrypoint)

        let classification = contentProbeWithoutExternalTools().classify(entrypoint, metadataType: "web")

        XCTAssertEqual(classification.kind, .web)
        XCTAssertEqual(classification.supportStatus, .playable)
    }

    func testDeclaredWebWallpaperRejectsCompleteJavaScriptFileWithoutMarkup() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "wallpaper.js")
        try Data("window.wallpaperPropertyListener = {};".utf8).write(to: entrypoint)

        let classification = contentProbeWithoutExternalTools().classify(entrypoint, metadataType: "web")

        XCTAssertEqual(classification.kind, .unknown)
        XCTAssertEqual(classification.supportStatus, .unsupported)
    }

    func testDeclaredWebWallpaperRejectsBinaryContentAndSymlink() throws {
        let root = try Fixture.makeTempDirectory()
        let binary = root.appending(path: "binary.html")
        var bytes = Data(repeating: 0, count: 512)
        bytes.append(Data("<html><body>not text</body></html>".utf8))
        try bytes.write(to: binary)
        let validHTML = root.appending(path: "valid.html")
        try Data("<!doctype html><html><body>valid</body></html>".utf8).write(to: validHTML)
        let symlink = root.appending(path: "linked.html")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: validHTML)
        let probe = contentProbeWithoutExternalTools()

        XCTAssertEqual(probe.classify(binary, metadataType: "web").kind, .unknown)
        XCTAssertEqual(probe.classify(validHTML, metadataType: "web").kind, .web)
        XCTAssertEqual(probe.classify(symlink, metadataType: "web").kind, .unknown)
    }

    func testDeclaredWebWallpaperRejectsForbiddenControlBytes() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "control.html")
        try Data([0x01]).write(to: entrypoint)

        let classification = contentProbeWithoutExternalTools().classify(entrypoint, metadataType: "web")

        XCTAssertEqual(classification.kind, .unknown)
        XCTAssertEqual(classification.supportStatus, .unsupported)
    }

    func testContentProbeIgnoresMarkupEmbeddedInJSON() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "metadata.json")
        try Data(#"{"template":"<div>not an entrypoint</div>"}"#.utf8).write(to: entrypoint)

        let classification = contentProbeWithoutExternalTools().classify(entrypoint)

        XCTAssertEqual(classification.kind, .unknown)
        XCTAssertEqual(classification.supportStatus, .unsupported)
    }

    func testContentProbeToleratesUTF8ScalarSplitAtProbeBoundary() throws {
        let root = try Fixture.makeTempDirectory()
        let entrypoint = root.appending(path: "boundary.html")
        let prefix = Data([0xEF, 0xBB, 0xBF]) + Data("<html><body>".utf8)
        let paddingCount = WebWallpaperValidation.maximumProbeBytes - prefix.count - 1
        var data = prefix
        data.append(Data(repeating: 0x61, count: paddingCount))
        data.append(Data("é</body></html>".utf8))
        try data.write(to: entrypoint)

        let classification = contentProbeWithoutExternalTools().classify(entrypoint)

        XCTAssertEqual(classification.kind, .web)
        XCTAssertEqual(classification.supportStatus, .playable)
    }

    func testContentBasedImportChecksAVFoundationBeforeRequiringFFprobe() throws {
        let source = try String(contentsOf: repositoryFile("Sources/BackgroundEngineCore/MediaContentProbe.swift"))
        let start = try XCTUnwrap(source.range(of: "public func videoClassification"))
        let end = try XCTUnwrap(source.range(of: "private func isImage", range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("AVURLAsset(url: url)"))
        XCTAssertTrue(body.contains("tracks(withMediaType: .video)"))
        XCTAssertLessThan(
            try XCTUnwrap(body.range(of: "AVURLAsset")).lowerBound,
            try XCTUnwrap(body.range(of: "mediaProbe.inspect")).lowerBound
        )
    }
}

private extension MediaToolsTests {
    func makeFakeVideoConverter(
        root: URL,
        ffmpegScript: String,
        ffprobeScript: String = """
        #!/bin/sh
        printf '%s' '{"streams":[{"index":0,"codec_type":"video"}],"format":{"format_name":"mov,mp4","size":"15"}}'
        """
    ) throws -> VideoConverter {
        let mediaTools = root.appending(path: "MediaTools", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mediaTools, withIntermediateDirectories: true)
        let ffmpeg = mediaTools.appending(path: "ffmpeg")
        let ffprobe = mediaTools.appending(path: "ffprobe")
        try Data(ffmpegScript.utf8).write(to: ffmpeg)
        try Data(ffprobeScript.utf8).write(to: ffprobe)
        for executable in [ffmpeg, ffprobe] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
        }
        return VideoConverter(resolver: MediaToolResolver(
            bundleResourceURL: root,
            environment: [:],
            allowDevelopmentFallback: false
        ))
    }

    func waitForFile(_ url: URL) async throws {
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(url.lastPathComponent)")
    }

    func processIdentifier(at url: URL) throws -> Int32 {
        for _ in 0..<1_000 {
            if let source = try? String(contentsOf: url, encoding: .utf8),
               let processIdentifier = Int32(
                source.trimmingCharacters(in: .whitespacesAndNewlines)
               ),
               processIdentifier > 1 {
                return processIdentifier
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("Timed out waiting for a valid process identifier in \(url.lastPathComponent)")
        throw CocoaError(.fileReadUnknown)
    }

    func assertProcessExited(_ processIdentifier: Int32) async {
        for _ in 0..<100 where Darwin.kill(processIdentifier, 0) == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(Darwin.kill(processIdentifier, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func incomingConversionFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".incoming-") }
    }
}

private func contentProbeWithoutExternalTools() -> MediaContentProbe {
    let resolver = MediaToolResolver(
        bundleResourceURL: nil,
        environment: [:],
        allowDevelopmentFallback: false
    )
    return MediaContentProbe(mediaProbe: MediaProbe(resolver: resolver))
}

private func repositoryFile(_ relativePath: String) -> URL {
    URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: relativePath)
}
