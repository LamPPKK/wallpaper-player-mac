import Foundation
import AVFoundation
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
        let mediaTools = resources.appending(path: "MediaTools")
        try FileManager.default.createDirectory(at: mediaTools, withIntermediateDirectories: true)
        let ffprobe = mediaTools.appending(path: "ffprobe")
        try Data("#!/bin/sh\ntrap '' TERM\nwhile :; do printf 'noisy-probe-output' >&2; done\n".utf8)
            .write(to: ffprobe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffprobe.path)
        let input = resources.appending(path: "input.bin")
        try Data([0]).write(to: input)
        let resolver = MediaToolResolver(
            bundleResourceURL: resources,
            environment: [:],
            allowDevelopmentFallback: false
        )

        XCTAssertThrowsError(try MediaProbe(resolver: resolver).inspect(input, timeout: 0.1)) { error in
            guard case ConversionError.ffprobeTimedOut = error else {
                return XCTFail("Expected ffprobeTimedOut, got \(error)")
            }
        }
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
}
