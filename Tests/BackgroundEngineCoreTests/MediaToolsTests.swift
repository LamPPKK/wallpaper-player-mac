import Foundation
import AVFoundation
import CoreVideo
import Darwin
import XCTest
@_spi(FFmpegRecovery) @testable import BackgroundEngineCore

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

    func testMediaProbePrefersDefaultVideoThenGreatestPixelArea() throws {
        let preferredJSON = #"""
        {
          "streams": [
            {"index": 0, "codec_type": "video", "width": 640, "height": 480, "disposition": {"attached_pic": 1, "default": 1}},
            {"index": 2, "codec_type": "video", "width": 1920, "height": 1080, "disposition": {"default": 0}},
            {"index": 4, "codec_type": "video", "width": 1280, "height": 720, "disposition": {"default": 1}}
          ]
        }
        """#
        let preferred = try JSONDecoder().decode(
            MediaProbeReport.self,
            from: Data(preferredJSON.utf8)
        )
        XCTAssertEqual(preferred.preferredVideoStreamIndex, 4)

        let fallbackJSON = #"""
        {
          "streams": [
            {"index": 7, "codec_type": "video", "width": 640, "height": 360},
            {"index": 3, "codec_type": "video", "width": 1920, "height": 1080}
          ]
        }
        """#
        let fallback = try JSONDecoder().decode(
            MediaProbeReport.self,
            from: Data(fallbackJSON.utf8)
        )
        XCTAssertEqual(fallback.preferredVideoStreamIndex, 3)
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
        let publicArguments = VideoConverter.conversionArguments(
            input: input,
            output: output
        )
        let arguments = VideoConverter.conversionArguments(
            input: input,
            output: output,
            videoStreamIndex: 7
        )

        XCTAssertTrue(publicArguments.contains("0:v:0"))
        XCTAssertFalse(publicArguments.contains("0:0"))
        XCTAssertTrue(arguments.contains("h264_videotoolbox"))
        XCTAssertTrue(arguments.contains("0:7"))
        XCTAssertFalse(arguments.contains("0:v:0"))
        XCTAssertTrue(arguments.contains("0:a?"))
        XCTAssertTrue(arguments.contains("+faststart"))
        XCTAssertTrue(arguments.contains(VideoConverter.evenDimensionFilter))
        XCTAssertFalse(arguments.contains { $0.contains("trunc(iw/2)") || $0.contains("trunc(ih/2)") })
        XCTAssertFalse(arguments.contains { $0.contains("pad=ceil") })
        XCTAssertFalse(arguments.contains("libx264"))
    }

    func testSoftwareVideoEncoderArgumentsAndVideoToolboxFailureClassification() {
        let fallbackArguments = VideoConverter.conversionArguments(
            input: URL(filePath: "/tmp/input.mkv"),
            output: URL(filePath: "/tmp/output.mp4"),
            videoStreamIndex: 0,
            encoder: .softwareMPEG4
        )

        XCTAssertTrue(fallbackArguments.contains("mpeg4"))
        XCTAssertTrue(fallbackArguments.contains("mp4v"))
        XCTAssertFalse(fallbackArguments.contains("h264_videotoolbox"))
        XCTAssertFalse(fallbackArguments.contains("-allow_sw"))

        for status in [-12903, -12908, -12912, -12915, -17691] {
            XCTAssertTrue(
                FFmpegVideoEncoder.shouldUseSoftwareFallback(
                    stderr: "[h264_videotoolbox] Cannot create compression session: \(status)"
                ),
                "Expected VideoToolbox status \(status) to enable the fallback."
            )
        }
        XCTAssertTrue(
            FFmpegVideoEncoder.shouldUseSoftwareFallback(
                stderr: "Cannot prepare encoder: -12908"
            )
        )
        XCTAssertTrue(
            FFmpegVideoEncoder.shouldUseSoftwareFallback(
                stderr: "Error encoding frame: -12912"
            )
        )
        XCTAssertFalse(
            FFmpegVideoEncoder.shouldUseSoftwareFallback(
                stderr: "Cannot create compression session\nunrelated status -12903"
            )
        )
        XCTAssertFalse(
            FFmpegVideoEncoder.shouldUseSoftwareFallback(
                stderr: "Cannot create compression session: -129030"
            )
        )
        XCTAssertFalse(
            FFmpegVideoEncoder.shouldUseSoftwareFallback(
                stderr: "Decoder failed: -12903"
            )
        )
    }

    func testVideoConversionRetriesOneClassifiedVideoToolboxFailure() async throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let invocationLog = root.appending(path: "ffmpeg-invocations")
        let converter = try makeFakeVideoConverter(
            root: root,
            ffmpegScript: """
            #!/bin/sh
            encoder=unknown
            for argument do
                if [ "$argument" = "h264_videotoolbox" ]; then encoder=videotoolbox; fi
                if [ "$argument" = "mpeg4" ]; then encoder=mpeg4; fi
            done
            printf '%s\n' "$encoder" >> "\(invocationLog.path)"
            if [ "$encoder" = "videotoolbox" ]; then
                printf '%s\n' 'Cannot create compression session: -12903' >&2
                exit 1
            fi
            printf converted-with-mpeg4
            """
        )
        let input = root.appending(path: "input.mkv")
        let output = root.appending(path: "output.mp4")
        try Data([0]).write(to: input)

        try await converter.convertToPlayableVideo(
            input: input,
            output: output,
            timeout: .seconds(5)
        )

        XCTAssertEqual(try Data(contentsOf: output), Data("converted-with-mpeg4".utf8))
        XCTAssertEqual(
            try String(contentsOf: invocationLog, encoding: .utf8)
                .split(whereSeparator: \.isNewline)
                .map(String.init),
            ["videotoolbox", "mpeg4"]
        )
        XCTAssertTrue(try incomingConversionFiles(in: root).isEmpty)
    }

    func testSynchronousVideoConversionRetriesClassifiedVideoToolboxFailure() throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let invocationLog = root.appending(path: "ffmpeg-sync-invocations")
        let converter = try makeFakeVideoConverter(
            root: root,
            ffmpegScript: """
            #!/bin/sh
            encoder=unknown
            for argument do
                if [ "$argument" = "h264_videotoolbox" ]; then encoder=videotoolbox; fi
                if [ "$argument" = "mpeg4" ]; then encoder=mpeg4; fi
            done
            printf '%s\n' "$encoder" >> "\(invocationLog.path)"
            if [ "$encoder" = "videotoolbox" ]; then
                printf '%s\n' 'Cannot create compression session: -12903' >&2
                exit 1
            fi
            printf synchronous-mpeg4
            """
        )
        let input = root.appending(path: "input.avi")
        let output = root.appending(path: "output.mp4")
        try Data([0]).write(to: input)

        try converter.convertToPlayableVideo(input: input, output: output)

        XCTAssertEqual(try Data(contentsOf: output), Data("synchronous-mpeg4".utf8))
        XCTAssertEqual(
            try String(contentsOf: invocationLog, encoding: .utf8)
                .split(whereSeparator: \.isNewline)
                .map(String.init),
            ["videotoolbox", "mpeg4"]
        )
        XCTAssertTrue(try incomingConversionFiles(in: root).isEmpty)
    }

    func testVideoConversionDoesNotRetryUnclassifiedFFmpegFailure() async throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let invocationLog = root.appending(path: "ffmpeg-invocations")
        let converter = try makeFakeVideoConverter(
            root: root,
            ffmpegScript: """
            #!/bin/sh
            printf 'invoked\n' >> "\(invocationLog.path)"
            printf '%s\n' 'Decoder failed: -12903' >&2
            exit 1
            """
        )
        let input = root.appending(path: "input.mkv")
        let output = root.appending(path: "output.mp4")
        try Data([0]).write(to: input)
        try Data("known-good".utf8).write(to: output)

        do {
            try await converter.convertToPlayableVideo(
                input: input,
                output: output,
                timeout: .seconds(5)
            )
            XCTFail("Expected the unclassified FFmpeg failure to propagate.")
        } catch ConversionError.ffmpegFailed(let status, let details) {
            XCTAssertEqual(status, 1)
            XCTAssertTrue(details.contains("Decoder failed"))
        } catch {
            XCTFail("Expected ffmpegFailed, got \(error)")
        }

        XCTAssertEqual(try Data(contentsOf: output), Data("known-good".utf8))
        XCTAssertEqual(
            try String(contentsOf: invocationLog, encoding: .utf8)
                .split(whereSeparator: \.isNewline).count,
            1
        )
        XCTAssertTrue(try incomingConversionFiles(in: root).isEmpty)
    }

    func testVideoConversionFallbackFailurePreservesOutputAndBothDiagnostics() async throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let invocationLog = root.appending(path: "ffmpeg-invocations")
        let converter = try makeFakeVideoConverter(
            root: root,
            ffmpegScript: """
            #!/bin/sh
            encoder=unknown
            for argument do
                if [ "$argument" = "h264_videotoolbox" ]; then encoder=videotoolbox; fi
                if [ "$argument" = "mpeg4" ]; then encoder=mpeg4; fi
            done
            printf '%s\n' "$encoder" >> "\(invocationLog.path)"
            printf partial-output
            if [ "$encoder" = "videotoolbox" ]; then
                printf '%s\n' 'Cannot prepare encoder: -12908 primary-marker' >&2
                exit 1
            fi
            printf '%s\n' 'software fallback failure-marker' >&2
            exit 2
            """
        )
        let input = root.appending(path: "input.mkv")
        let output = root.appending(path: "output.mp4")
        try Data([0]).write(to: input)
        try Data("known-good".utf8).write(to: output)

        do {
            try await converter.convertToPlayableVideo(
                input: input,
                output: output,
                timeout: .seconds(5)
            )
            XCTFail("Expected both FFmpeg attempts to fail.")
        } catch ConversionError.ffmpegFailed(let status, let details) {
            XCTAssertEqual(status, 2)
            XCTAssertTrue(details.contains("primary-marker"))
            XCTAssertTrue(details.contains("fallback failure-marker"))
            XCTAssertTrue(details.contains("VideoToolbox attempt exited with status 1"))
            XCTAssertTrue(details.contains("Software MPEG-4 fallback exited with status 2"))
        } catch {
            XCTFail("Expected ffmpegFailed, got \(error)")
        }

        XCTAssertEqual(try Data(contentsOf: output), Data("known-good".utf8))
        XCTAssertEqual(
            try String(contentsOf: invocationLog, encoding: .utf8)
                .split(whereSeparator: \.isNewline)
                .map(String.init),
            ["videotoolbox", "mpeg4"]
        )
        XCTAssertTrue(try incomingConversionFiles(in: root).isEmpty)
    }

    func testInheritedDescriptorSelectionAvoidsSourceAndSupervisorFD64Collisions() throws {
        let sourceCollision = try XCTUnwrap(
            SupervisedChildProcess.inheritedDescriptorTargets(
                sourceDescriptors: [64, 70],
                reservedDescriptors: [0, 1, 2, 3]
            )
        )
        XCTAssertEqual(sourceCollision, [4, 5])
        XCTAssertFalse(Set(sourceCollision).contains(64))
        XCTAssertTrue(Set(sourceCollision).isDisjoint(with: [64, 70]))

        let supervisorCollision = try XCTUnwrap(
            SupervisedChildProcess.inheritedDescriptorTargets(
                sourceDescriptors: [11],
                reservedDescriptors: [0, 1, 2, 3, 64]
            )
        )
        XCTAssertEqual(supervisorCollision, [4])
        XCTAssertFalse(Set(supervisorCollision).contains(64))
    }

    func testVideoConversionCacheKeyIncludesToolBuildRecipeAndResolution() {
        let key = VideoConversionCacheKey(
            contentHash: "0123456789abcdef0123456789abcdef",
            mediaBuildID: "ffmpeg-test",
            recipeID: "recipe-test",
            width: 1920,
            height: 1080
        )

        XCTAssertEqual(
            key.fileName,
            "0123456789abcdef01234567-ffmpeg-test-recipe-test-1920x1080.mp4"
        )
        XCTAssertEqual(
            key.legacyV1FileName,
            "0123456789abcdef01234567-ffmpeg-test-1920x1080.mp4"
        )
    }

    func testActualConversionPreservesDisplayAspectRatioForOddWidthAndHeight() async throws {
        let tools = try actualMediaTools()
        for (width, height) in [(321, 180), (320, 181)] {
            let root = try Fixture.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let rawFrame = root.appending(path: "input-\(width)x\(height).rgba")
            let input = root.appending(path: "input-\(width)x\(height).mkv")
            let output = root.appending(path: "output-\(width)x\(height).mp4")
            try writeRawRGBAFrame(width: width, height: height, to: rawFrame)
            try runMediaTool(
                tools.ffmpeg,
                arguments: [
                    "-hide_banner", "-loglevel", "error",
                    "-f", "rawvideo", "-pixel_format", "rgba",
                    "-video_size", "\(width)x\(height)", "-framerate", "1",
                    "-i", rawFrame.path, "-frames:v", "1",
                    "-vf", "setsar=4/3", "-c:v", "ffv1", input.path
                ]
            )
            let inputGeometry = try probeGeometry(input, ffprobe: tools.ffprobe)

            try await tools.converter.convertToPlayableVideo(
                input: input,
                output: output,
                timeout: .seconds(30)
            )

            let outputGeometry = try probeGeometry(output, ffprobe: tools.ffprobe)
            XCTAssertEqual(outputGeometry.width, width + width % 2)
            XCTAssertEqual(outputGeometry.height, height + height % 2)
            XCTAssertEqual(outputGeometry.displayAspectRatio, inputGeometry.displayAspectRatio)
            XCTAssertEqual(outputGeometry.width % 2, 0)
            XCTAssertEqual(outputGeometry.height % 2, 0)
            try assertMediaFullyDecodes(output, ffmpeg: tools.ffmpeg)
            try await assertAVFoundationFullyDecodesVideo(output)
        }
    }

    func testActualDescriptorConversionPreservesAudioAndFullyDecodes() async throws {
        let tools = try actualMediaTools()
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let rawVideo = root.appending(path: "input.rgba")
        let rawAudio = root.appending(path: "input.pcm")
        let input = root.appending(path: "input.mkv")
        let output = root.appending(path: "output.mp4")
        try Data(
            repeating: 0xFF,
            count: 64 * 64 * 4 * 30
        ).write(to: rawVideo, options: .atomic)
        try Data(
            repeating: 0,
            count: 44_100 * 2 * MemoryLayout<Int16>.size
        ).write(to: rawAudio, options: .atomic)
        try runMediaTool(
            tools.ffmpeg,
            arguments: [
                "-hide_banner", "-loglevel", "error",
                "-f", "rawvideo", "-pixel_format", "rgba",
                "-video_size", "64x64", "-framerate", "30",
                "-i", rawVideo.path,
                "-f", "s16le", "-ar", "44100", "-ac", "2",
                "-i", rawAudio.path,
                "-frames:v", "30", "-shortest",
                "-c:v", "ffv1", "-c:a", "pcm_s16le", input.path
            ]
        )

        try await tools.converter.convertToPlayableVideo(
            input: input,
            output: output,
            timeout: .seconds(30)
        )

        try assertMediaFullyDecodes(output, ffmpeg: tools.ffmpeg)
        try await assertAVFoundationFullyDecodesVideo(output, requiresAudio: true)
    }

    func testActualConversionSelectsDefaultVideoStreamInsteadOfFirstVideoStream() async throws {
        let tools = try actualMediaTools()
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blackPreview = root.appending(path: "black-preview.rgba")
        let authoredVideo = root.appending(path: "authored-video.rgba")
        let input = root.appending(path: "multi-video.mkv")
        let output = root.appending(path: "output.mp4")
        try Data(repeating: 0, count: 64 * 64 * 4).write(to: blackPreview, options: .atomic)
        var authoredFrames = Data()
        for frame in 0..<12 {
            authoredFrames.append(
                Data(repeating: UInt8(32 + frame * 16), count: 96 * 54 * 4)
            )
        }
        try authoredFrames.write(to: authoredVideo, options: .atomic)
        try runMediaTool(
            tools.ffmpeg,
            arguments: [
                "-hide_banner", "-loglevel", "error",
                "-f", "rawvideo", "-pixel_format", "rgba",
                "-video_size", "64x64", "-framerate", "1",
                "-i", blackPreview.path,
                "-f", "rawvideo", "-pixel_format", "rgba",
                "-video_size", "96x54", "-framerate", "12",
                "-i", authoredVideo.path,
                "-map", "0:v:0", "-map", "1:v:0",
                "-c:v", "ffv1",
                "-disposition:v:0", "0", "-disposition:v:1", "default",
                input.path
            ]
        )
        let inputReport = try MediaProbe(resolver: MediaToolResolver(
            bundleResourceURL: nil,
            environment: [
                "BACKGROUND_ENGINE_FFMPEG": tools.ffmpeg,
                "BACKGROUND_ENGINE_FFPROBE": tools.ffprobe
            ],
            allowDevelopmentFallback: true
        )).inspect(input)
        XCTAssertEqual(inputReport.preferredVideoStreamIndex, 1)

        try await tools.converter.convertToPlayableVideo(
            input: input,
            output: output,
            timeout: .seconds(30)
        )

        let outputGeometry = try probeGeometry(output, ffprobe: tools.ffprobe)
        XCTAssertEqual(outputGeometry.width, 96)
        XCTAssertEqual(outputGeometry.height, 54)
        try assertMediaFullyDecodes(output, ffmpeg: tools.ffmpeg)
        try await assertAVFoundationFullyDecodesVideo(output)
    }

    func testActualConversionAppliesRotationMetadataWithoutChangingVisualOrientation() async throws {
        let tools = try actualMediaTools()
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let rawFrame = root.appending(path: "base.rgba")
        let base = root.appending(path: "base.mp4")
        let rotated = root.appending(path: "rotated.mp4")
        let output = root.appending(path: "output.mp4")
        try writeRawRGBAFrame(width: 320, height: 180, to: rawFrame)
        try runMediaTool(
            tools.ffmpeg,
            arguments: [
                "-hide_banner", "-loglevel", "error",
                "-f", "rawvideo", "-pixel_format", "rgba",
                "-video_size", "320x180", "-framerate", "1",
                "-i", rawFrame.path, "-frames:v", "1",
                "-c:v", "mpeg4", "-tag:v", "mp4v",
                "-b:v", "4M", "-pix_fmt", "yuv420p", base.path
            ]
        )
        try runMediaTool(
            tools.ffmpeg,
            arguments: [
                "-hide_banner", "-loglevel", "error",
                "-display_rotation", "90", "-i", base.path,
                "-c", "copy", rotated.path
            ]
        )
        XCTAssertEqual(try probeGeometry(rotated, ffprobe: tools.ffprobe).rotation, 90)

        try await tools.converter.convertToPlayableVideo(
            input: rotated,
            output: output,
            timeout: .seconds(30)
        )

        let outputGeometry = try probeGeometry(output, ffprobe: tools.ffprobe)
        XCTAssertEqual(outputGeometry.width, 180)
        XCTAssertEqual(outputGeometry.height, 320)
        XCTAssertNil(outputGeometry.rotation)
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
            printf partial
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
            printf partial
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
            printf converted-video
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

    func testVideoConversionCacheRootSymlinkSwapCannotRedirectOutputOrCleanup() async throws {
        let root = try Fixture.makeTempDirectory()
        let external = try Fixture.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        let outputDirectory = root.appending(path: "Video")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let ready = root.appending(path: "ffmpeg-ready")
        let proceed = root.appending(path: "ffmpeg-proceed")
        let converter = try makeFakeVideoConverter(
            root: root,
            ffmpegScript: """
            #!/bin/sh
            for argument do output=$argument; done
            printf ready > "\(ready.path)"
            while [ ! -f "\(proceed.path)" ]; do /bin/sleep 0.01; done
            printf converted-video
            """
        )
        let input = root.appending(path: "input.mkv")
        let output = outputDirectory.appending(path: "output.mp4")
        try Data([0]).write(to: input)
        try Data("known-good".utf8).write(to: output)
        let externalMarker = external.appending(path: "do-not-delete")
        try Data("external".utf8).write(to: externalMarker)

        let conversion = Task {
            try await converter.convertToPlayableVideo(
                input: input,
                output: output,
                timeout: .seconds(5)
            )
        }
        try await waitForFile(ready)
        let retired = root.appending(path: "Retired")
        try FileManager.default.moveItem(at: outputDirectory, to: retired)
        try FileManager.default.createSymbolicLink(
            at: outputDirectory,
            withDestinationURL: external
        )
        try Data().write(to: proceed)

        do {
            try await conversion.value
            XCTFail("Expected the replaced cache directory to be rejected")
        } catch ConversionError.unsafeOutputPath {
            // Expected. All writes and cleanup stay descriptor-relative to Retired.
        } catch {
            XCTFail("Expected unsafeOutputPath, got \(error)")
        }

        XCTAssertEqual(
            try Data(contentsOf: retired.appending(path: "output.mp4")),
            Data("known-good".utf8)
        )
        XCTAssertEqual(try Data(contentsOf: externalMarker), Data("external".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.appending(path: "output.mp4").path))
        XCTAssertTrue(try incomingConversionFiles(in: retired).isEmpty)
    }

    func testSynchronousVideoConversionDoesNotDependOnCooperativeExecutor() async throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let converter = try makeFakeVideoConverter(
            root: root,
            ffmpegScript: """
            #!/bin/sh
            for argument do output=$argument; done
            printf synchronous-video
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
            printf converted-video
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
    struct ActualMediaTools {
        let ffmpeg: String
        let ffprobe: String
        let converter: VideoConverter
    }

    struct ProbedGeometry: Decodable {
        struct Stream: Decodable {
            struct SideData: Decodable {
                let rotation: Int?
            }

            let width: Int
            let height: Int
            let sampleAspectRatio: String?
            let displayAspectRatio: String?
            let sideData: [SideData]?

            enum CodingKeys: String, CodingKey {
                case width, height
                case sampleAspectRatio = "sample_aspect_ratio"
                case displayAspectRatio = "display_aspect_ratio"
                case sideData = "side_data_list"
            }
        }

        let streams: [Stream]
    }

    struct Geometry {
        let width: Int
        let height: Int
        let sampleAspectRatio: String?
        let displayAspectRatio: String?
        let rotation: Int?
    }

    func actualMediaTools() throws -> ActualMediaTools {
        let environment = ProcessInfo.processInfo.environment
        guard let ffmpeg = environment["BACKGROUND_ENGINE_FFMPEG"],
              let ffprobe = environment["BACKGROUND_ENGINE_FFPROBE"],
              FileManager.default.isExecutableFile(atPath: ffmpeg),
              FileManager.default.isExecutableFile(atPath: ffprobe) else {
            throw XCTSkip("Bundled FFmpeg and ffprobe are required for geometry conversion tests.")
        }
        let resolver = MediaToolResolver(
            bundleResourceURL: nil,
            environment: [
                "BACKGROUND_ENGINE_FFMPEG": ffmpeg,
                "BACKGROUND_ENGINE_FFPROBE": ffprobe
            ],
            allowDevelopmentFallback: true
        )
        return ActualMediaTools(
            ffmpeg: ffmpeg,
            ffprobe: ffprobe,
            converter: VideoConverter(resolver: resolver)
        )
    }

    func runMediaTool(_ executable: String, arguments: [String]) throws {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(data: errorData, encoding: .utf8) ?? "media tool failed"
        )
        if process.terminationStatus != 0 {
            throw ConversionError.ffmpegFailed(
                process.terminationStatus,
                String(data: errorData, encoding: .utf8) ?? ""
            )
        }
    }

    func writeRawRGBAFrame(width: Int, height: Int, to output: URL) throws {
        try Data(repeating: 0xFF, count: width * height * 4).write(to: output, options: .atomic)
    }

    func probeGeometry(_ input: URL, ffprobe: String) throws -> Geometry {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(filePath: ffprobe)
        process.arguments = [
            "-v", "error", "-select_streams", "v:0",
            "-show_entries",
            "stream=width,height,sample_aspect_ratio,display_aspect_ratio:stream_side_data",
            "-of", "json", input.path
        ]
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw ConversionError.ffprobeFailed(
                process.terminationStatus,
                String(data: errorData, encoding: .utf8) ?? ""
            )
        }
        let stream = try XCTUnwrap(JSONDecoder().decode(ProbedGeometry.self, from: data).streams.first)
        return Geometry(
            width: stream.width,
            height: stream.height,
            sampleAspectRatio: stream.sampleAspectRatio,
            displayAspectRatio: stream.displayAspectRatio,
            rotation: stream.sideData?.compactMap(\.rotation).first
        )
    }

    func assertMediaFullyDecodes(_ input: URL, ffmpeg: String) throws {
        try runMediaTool(
            ffmpeg,
            arguments: [
                "-hide_banner", "-loglevel", "error", "-xerror",
                "-i", input.path,
                "-map", "0:v:0", "-map", "0:a?",
                "-f", "null", "-"
            ]
        )
    }

    func assertAVFoundationFullyDecodesVideo(
        _ input: URL,
        requiresAudio: Bool = false
    ) async throws {
        let asset = AVURLAsset(url: input)
        let isPlayable = try await asset.load(.isPlayable)
        XCTAssertTrue(isPlayable)
        if requiresAudio {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertFalse(audioTracks.isEmpty)
        }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        XCTAssertTrue(reader.canAdd(output))
        reader.add(output)
        XCTAssertTrue(reader.startReading())

        var decodedFrameCount = 0
        while output.copyNextSampleBuffer() != nil {
            decodedFrameCount += 1
        }
        XCTAssertEqual(
            reader.status,
            .completed,
            reader.error?.localizedDescription ?? "AVFoundation decoding failed"
        )
        XCTAssertGreaterThan(decodedFrameCount, 0)
    }

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
