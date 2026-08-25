import Darwin
import Foundation
import XCTest
@testable import BackgroundEngineCore

final class WebMediaPreparerTests: XCTestCase {
    func testPreferredAudioStreamUsesDefaultThenChannelsSampleRateAndIndex() throws {
        let defaultReport = try decodeReport(#"""
        {
          "streams": [
            {"index":7,"codec_type":"audio","sample_rate":"96000","channels":8,"disposition":{"default":0}},
            {"index":4,"codec_type":"audio","sample_rate":"44100","channels":1,"disposition":{"default":1}},
            {"index":1,"codec_type":"video","disposition":{"attached_pic":1}}
          ]
        }
        """#)
        XCTAssertEqual(defaultReport.preferredAudioStreamIndex, 4)

        let fallbackReport = try decodeReport(#"""
        {
          "streams": [
            {"index":9,"codec_type":"audio","sample_rate":"48000","channels":2},
            {"index":3,"codec_type":"audio","sample_rate":"96000","channels":2},
            {"index":1,"codec_type":"audio","sample_rate":"96000","channels":2}
          ]
        }
        """#)
        XCTAssertEqual(fallbackReport.preferredAudioStreamIndex, 1)
    }

    func testCacheKeyHashesEveryIdentityComponentIntoSafeStableFileName() {
        let original = WebMediaCacheKey(
            sourceContentHash: String(repeating: "a", count: 64),
            mediaBuildID: "../build",
            recipeID: "../../recipe",
            kind: .audio
        )
        let same = WebMediaCacheKey(
            sourceContentHash: String(repeating: "A", count: 64),
            mediaBuildID: "../build",
            recipeID: "../../recipe",
            kind: .audio
        )
        let video = WebMediaCacheKey(
            sourceContentHash: String(repeating: "a", count: 64),
            mediaBuildID: "../build",
            recipeID: "../../recipe",
            kind: .video
        )

        XCTAssertEqual(original.fileName, same.fileName)
        XCTAssertNotEqual(original.fileName, video.fileName)
        XCTAssertTrue(original.fileName.hasSuffix(".m4a"))
        XCTAssertTrue(video.fileName.hasSuffix(".mp4"))
        XCTAssertFalse(original.fileName.contains("/"))
        XCTAssertFalse(original.fileName.contains(".."))
    }

    func testCrashRecoveryPrunesOnlyPinnedInternalTemporaryFiles() throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appending(path: "cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        let orphanNames = [
            ".web-media-source-crash.bin",
            ".web-media-video-crash.mp4",
            ".web-media-audio-crash.m4a"
        ]
        for name in orphanNames {
            try Data("orphan".utf8).write(to: cache.appending(path: name))
        }

        let published = cache.appending(path: "web-media-valid.mp4")
        let nearMatch = cache.appending(path: ".web-media-source")
        let preservedDirectory = cache.appending(path: ".web-media-video-directory")
        try Data("published".utf8).write(to: published)
        try Data("near-match".utf8).write(to: nearMatch)
        try FileManager.default.createDirectory(at: preservedDirectory, withIntermediateDirectories: false)

        let outside = root.appending(path: "outside.bin")
        let linked = cache.appending(path: ".web-media-source-linked.bin")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)

        XCTAssertEqual(
            try WebMediaPreparer.pruneOrphanedTemporaryFiles(in: cache),
            orphanNames.count
        )
        for name in orphanNames {
            XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appending(path: name).path))
        }
        XCTAssertEqual(try Data(contentsOf: published), Data("published".utf8))
        XCTAssertEqual(try Data(contentsOf: nearMatch), Data("near-match".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: preservedDirectory.path))
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
        XCTAssertTrue(
            try linked.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
        )
    }

    func testAudioConversionArgumentsSelectOneStreamAndUseDescriptorOutput() {
        let arguments = WebMediaPreparer.audioConversionArguments(
            inputPath: "fd:",
            audioStreamIndex: 7,
            sourceChannels: 6
        )

        XCTAssertTrue(arguments.contains("0:7"))
        XCTAssertTrue(arguments.contains("-vn"))
        XCTAssertTrue(arguments.contains("-sn"))
        XCTAssertTrue(arguments.contains("-dn"))
        XCTAssertTrue(arguments.contains("aac"))
        XCTAssertTrue(arguments.contains("aac_low"))
        XCTAssertTrue(arguments.contains("48000"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-ac")! + 1], "2")
        let descriptorOption = try? XCTUnwrap(arguments.firstIndex(of: "-fd"))
        XCTAssertNotNil(descriptorOption)
        if let descriptorOption {
            XCTAssertTrue(arguments[descriptorOption + 1].hasPrefix("__BACKGROUND_ENGINE_"))
            XCTAssertEqual(arguments[descriptorOption + 2], "-i")
            XCTAssertEqual(arguments[descriptorOption + 3], "fd:")
        }
        XCTAssertTrue(arguments.contains("+frag_keyframe+empty_moov+default_base_moof"))
        XCTAssertEqual(Array(arguments.suffix(3)), ["-f", "mp4", "pipe:1"])
    }

    func testSnapshotByteBudgetRejectsGrowthBeyondOpeningSizeLimit() throws {
        XCTAssertEqual(
            try WebMediaPreparer.validatedSnapshotByteCount(
                current: 7,
                adding: 3,
                maximum: 10
            ),
            10
        )
        XCTAssertThrowsError(
            try WebMediaPreparer.validatedSnapshotByteCount(
                current: 10,
                adding: 1,
                maximum: 10
            )
        ) { error in
            XCTAssertEqual(
                error as? WebMediaPreparationError,
                .sourceTooLarge(11, 10)
            )
        }
        XCTAssertThrowsError(
            try WebMediaPreparer.validatedSnapshotByteCount(
                current: UInt64.max,
                adding: 1,
                maximum: UInt64.max
            )
        ) { error in
            XCTAssertEqual(
                error as? WebMediaPreparationError,
                .sourceTooLarge(UInt64.max, UInt64.max)
            )
        }
    }

    func testAudioOutputReservationUsesDurationAndRemainsBounded() throws {
        let short = try decodeReport(#"""
        {"streams":[{"index":0,"codec_type":"audio","duration":"10"}],"format":{"duration":"10"}}
        """#)
        let unknown = try decodeReport(#"""
        {"streams":[{"index":0,"codec_type":"audio"}]}
        """#)
        let mismatched = try decodeReport(#"""
        {"streams":[{"index":0,"codec_type":"audio","duration":"20"}],"format":{"duration":"1"}}
        """#)

        XCTAssertLessThan(
            WebMediaPreparer.maximumAudioOutputBytes(for: short),
            WebMediaPreparer.maximumAudioBytes
        )
        XCTAssertEqual(
            WebMediaPreparer.maximumAudioOutputBytes(for: unknown),
            WebMediaPreparer.maximumAudioBytes
        )
        XCTAssertGreaterThan(
            WebMediaPreparer.maximumAudioOutputBytes(for: mismatched),
            WebMediaPreparer.maximumAudioOutputBytes(for: short)
        )
    }

    func testPacketEvidenceProbeReadsOnePacketFromOneAbsoluteStream() {
        let arguments = MediaProbe.boundedPacketProbeArguments(
            inputPath: "fd:",
            streamIndex: 7,
            streamStartTime: "3600.5"
        )

        XCTAssertEqual(
            arguments[arguments.firstIndex(of: "-select_streams")! + 1],
            "7"
        )
        XCTAssertEqual(
            arguments[arguments.firstIndex(of: "-read_intervals")! + 1],
            "3600.5%+#1"
        )
        XCTAssertTrue(arguments.contains("-count_packets"))
        XCTAssertEqual(arguments.last, "fd:")
        XCTAssertEqual(
            arguments[arguments.firstIndex(of: "-fd")! + 1],
            "__BACKGROUND_ENGINE_MEDIA_PROBE_FD__"
        )

        let invalidStart = MediaProbe.boundedPacketProbeArguments(
            inputPath: "fd:",
            streamIndex: 1,
            streamStartTime: "not-a-timestamp"
        )
        XCTAssertEqual(
            invalidStart[invalidStart.firstIndex(of: "-read_intervals")! + 1],
            "0.0%+#1"
        )
    }

    func testAudioWithAttachedCoverIsPreparedOnceAndThenReused() async throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let invocationLog = root.appending(path: "ffmpeg.log")
        let resolver = try makeFakeRuntime(root: root, invocationLog: invocationLog)
        let source = root.appending(path: "ambience.ogg")
        try Data("source-audio".utf8).write(to: source)
        let cache = root.appending(path: "cache")
        let preparer = WebMediaPreparer(resolver: resolver)

        let first = try await preparer.prepare(
            source: source,
            cacheDirectory: cache,
            timeout: .seconds(30)
        )
        let second = try await preparer.prepare(
            source: source,
            cacheDirectory: cache,
            timeout: .seconds(30)
        )

        XCTAssertEqual(first.kind, .audio)
        XCTAssertFalse(first.reusedCachedOutput)
        XCTAssertTrue(second.reusedCachedOutput)
        XCTAssertEqual(first.url, second.url)
        XCTAssertEqual(first.url.pathExtension, "m4a")
        XCTAssertEqual(try Data(contentsOf: first.url), Data("converted-audio".utf8))
        XCTAssertEqual(first.probeReport.preferredAudioStreamIndex, 0)
        XCTAssertFalse(first.probeReport.hasVideo)
        XCTAssertEqual(try invocationCount(at: invocationLog), 1)
        XCTAssertTrue(try temporaryMediaFiles(in: cache).isEmpty)
    }

    func testOGVVideoUsesExistingVideoConverterAndPublishesMP4() async throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let invocationLog = root.appending(path: "ffmpeg.log")
        let resolver = try makeFakeRuntime(root: root, invocationLog: invocationLog)
        let source = root.appending(path: "animation.ogv")
        try Data("source-video".utf8).write(to: source)
        let cache = root.appending(path: "cache")

        let result = try await WebMediaPreparer(resolver: resolver).prepare(
            source: source,
            cacheDirectory: cache,
            timeout: .seconds(30)
        )

        XCTAssertEqual(result.kind, .video)
        XCTAssertEqual(result.url.pathExtension, "mp4")
        XCTAssertEqual(try Data(contentsOf: result.url), Data("converted-video".utf8))
        XCTAssertEqual(result.probeReport.preferredVideoStreamIndex, 0)
        XCTAssertEqual(try invocationCount(at: invocationLog), 1)
        let invocation = try String(contentsOf: invocationLog, encoding: .utf8)
        XCTAssertTrue(invocation.contains("-fd "))
        XCTAssertTrue(invocation.contains("-i fd:"))
        XCTAssertFalse(invocation.contains(".web-media-source"))
        XCTAssertTrue(try temporaryMediaFiles(in: cache).isEmpty)
    }

    func testMPEG4FallbackOutputIsRejectedAndNeverPublished() async throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let invocationLog = root.appending(path: "ffmpeg.log")
        let resolver = try makeFakeRuntime(
            root: root,
            invocationLog: invocationLog,
            ffmpegBody: "printf '%s' 'converted-video-mpeg4'"
        )
        let source = root.appending(path: "animation.ogv")
        try Data("source-video".utf8).write(to: source)
        let cache = root.appending(path: "cache")

        do {
            _ = try await WebMediaPreparer(resolver: resolver).prepare(
                source: source,
                cacheDirectory: cache,
                timeout: .seconds(30)
            )
            XCTFail("Expected MPEG-4 Part 2 output rejection")
        } catch let error as WebMediaPreparationError {
            XCTAssertEqual(error, .invalidConvertedOutput)
        }

        XCTAssertEqual(try invocationCount(at: invocationLog), 1)
        XCTAssertTrue(try temporaryMediaFiles(in: cache).isEmpty)
        let published = try FileManager.default.contentsOfDirectory(
            at: cache,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("web-media-") }
        XCTAssertTrue(published.isEmpty)
    }

    func testMPEG4ExistingVideoCacheIsRejectedWithoutBeingChanged() async throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let invocationLog = root.appending(path: "ffmpeg.log")
        let resolver = try makeFakeRuntime(root: root, invocationLog: invocationLog)
        let source = root.appending(path: "animation.ogv")
        try Data("source-video".utf8).write(to: source)
        let cache = root.appending(path: "cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let sourceHash = try WallpaperContentHasher.hashFile(source)
        let key = WebMediaCacheKey(sourceContentHash: sourceHash, kind: .video)
        let existing = cache.appending(path: key.fileName)
        let cachedBytes = Data("cached-video-mpeg4".utf8)
        try cachedBytes.write(to: existing)

        do {
            _ = try await WebMediaPreparer(resolver: resolver).prepare(
                source: source,
                cacheDirectory: cache,
                timeout: .seconds(30)
            )
            XCTFail("Expected incompatible cached video rejection")
        } catch let error as WebMediaPreparationError {
            XCTAssertEqual(error, .invalidExistingCache(key.fileName))
        }

        XCTAssertEqual(try Data(contentsOf: existing), cachedBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: invocationLog.path))
        XCTAssertTrue(try temporaryMediaFiles(in: cache).isEmpty)
    }

    func testInvalidExistingCacheIsNeverOverwritten() async throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let invocationLog = root.appending(path: "ffmpeg.log")
        let resolver = try makeFakeRuntime(root: root, invocationLog: invocationLog)
        let source = root.appending(path: "ambience.ogg")
        try Data("source-audio".utf8).write(to: source)
        let cache = root.appending(path: "cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let sourceHash = try WallpaperContentHasher.hashFile(source)
        let key = WebMediaCacheKey(sourceContentHash: sourceHash, kind: .audio)
        let existing = cache.appending(path: key.fileName)
        let invalidBytes = Data("invalid-cache".utf8)
        try invalidBytes.write(to: existing)

        do {
            _ = try await WebMediaPreparer(resolver: resolver).prepare(
                source: source,
                cacheDirectory: cache,
                timeout: .seconds(30)
            )
            XCTFail("Expected invalid cache rejection")
        } catch let error as WebMediaPreparationError {
            XCTAssertEqual(error, .invalidExistingCache(key.fileName))
        }

        XCTAssertEqual(try Data(contentsOf: existing), invalidBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: invocationLog.path))
        XCTAssertTrue(try temporaryMediaFiles(in: cache).isEmpty)
    }

    func testCancellationReapsAudioConverterAndLeavesNoPartialCache() async throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let invocationLog = root.appending(path: "ffmpeg.log")
        let processIdentifierFile = root.appending(path: "ffmpeg.pid")
        let resolver = try makeFakeRuntime(
            root: root,
            invocationLog: invocationLog,
            ffmpegBody: """
            printf '%s' "$$" > "\(processIdentifierFile.path)"
            /bin/sleep 30
            """
        )
        let source = root.appending(path: "ambience.ogg")
        try Data("source-audio".utf8).write(to: source)
        let cache = root.appending(path: "cache")
        let task = Task {
            try await WebMediaPreparer(resolver: resolver).prepare(
                source: source,
                cacheDirectory: cache,
                timeout: .seconds(30)
            )
        }
        let processIdentifier = try await waitForProcessIdentifier(at: processIdentifierFile)

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        await assertProcessExited(processIdentifier)
        XCTAssertTrue(try temporaryMediaFiles(in: cache).isEmpty)
        let published = try FileManager.default.contentsOfDirectory(
            at: cache,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("web-media-") }
        XCTAssertTrue(published.isEmpty)
    }

    func testFFmpegTimeoutReapsChildAndLeavesNoPartialCache() async throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let invocationLog = root.appending(path: "ffmpeg.log")
        let processIdentifierFile = root.appending(path: "ffmpeg.pid")
        let resolver = try makeFakeRuntime(
            root: root,
            invocationLog: invocationLog,
            ffmpegBody: """
            printf '%s' "$$" > "\(processIdentifierFile.path)"
            exec /bin/sleep 60
            """
        )
        let source = root.appending(path: "ambience.ogg")
        try Data("source-audio".utf8).write(to: source)
        let cache = root.appending(path: "cache")

        let task = Task {
            try await WebMediaPreparer(resolver: resolver).prepare(
                source: source,
                cacheDirectory: cache,
                timeout: .seconds(15)
            )
        }
        defer { task.cancel() }
        let processIdentifier = try await waitForProcessIdentifier(
            at: processIdentifierFile
        )

        do {
            _ = try await task.value
            XCTFail("Expected FFmpeg timeout")
        } catch let error as WebMediaPreparationError {
            XCTAssertEqual(error, .timedOut)
        }

        await assertProcessExited(processIdentifier)
        XCTAssertTrue(try temporaryMediaFiles(in: cache).isEmpty)
        let published = try FileManager.default.contentsOfDirectory(
            at: cache,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("web-media-") }
        XCTAssertTrue(published.isEmpty)
    }

    func testFFprobeTimeoutReapsChildAndPreservesExistingCache() async throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let invocationLog = root.appending(path: "ffmpeg.log")
        let processIdentifierFile = root.appending(path: "ffprobe.pid")
        let resolver = try makeFakeRuntime(
            root: root,
            invocationLog: invocationLog,
            ffprobeBody: """
            input=''
            descriptor=''
            previous=''
            for argument in "$@"; do
              if [ "$previous" = '-fd' ]; then descriptor="$argument"; fi
              input="$argument"
              previous="$argument"
            done
            if [ "$input" = 'fd:' ] && [ -n "$descriptor" ]; then input="/dev/fd/$descriptor"; fi
            payload=$(/bin/dd if="$input" bs=64 count=1 2>/dev/null || true)
            case "$payload" in
              source-audio*)
                printf '%s' '{"streams":[{"index":0,"codec_name":"vorbis","codec_type":"audio","sample_rate":"48000","channels":2}],"format":{"format_name":"ogg","duration":"1.0"}}'
                ;;
              probe-timeout-cache*)
                printf '%s' "$$" > "\(processIdentifierFile.path)"
                exec /bin/sleep 30
                ;;
              *)
                printf '%s' '{"streams":[],"format":{"format_name":"unknown"}}'
                ;;
            esac
            """
        )
        let source = root.appending(path: "ambience.ogg")
        try Data("source-audio".utf8).write(to: source)
        let cache = root.appending(path: "cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let sourceHash = try WallpaperContentHasher.hashFile(source)
        let key = WebMediaCacheKey(sourceContentHash: sourceHash, kind: .audio)
        let existing = cache.appending(path: key.fileName)
        let cachedBytes = Data("probe-timeout-cache".utf8)
        try cachedBytes.write(to: existing)

        do {
            _ = try await WebMediaPreparer(resolver: resolver).prepare(
                source: source,
                cacheDirectory: cache,
                timeout: .seconds(1)
            )
            XCTFail("Expected ffprobe timeout")
        } catch let error as WebMediaPreparationError {
            XCTAssertEqual(error, .timedOut)
        }

        let processIdentifier = try await waitForProcessIdentifier(
            at: processIdentifierFile
        )
        await assertProcessExited(processIdentifier)
        XCTAssertEqual(try Data(contentsOf: existing), cachedBytes)
        XCTAssertTrue(try temporaryMediaFiles(in: cache).isEmpty)
        let cacheEntries = try FileManager.default.contentsOfDirectory(
            at: cache,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)
        XCTAssertEqual(cacheEntries, [key.fileName])
        XCTAssertFalse(FileManager.default.fileExists(atPath: invocationLog.path))
    }

    func testSymlinkSourceIsRejectedBeforeFFmpegRuns() async throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let invocationLog = root.appending(path: "ffmpeg.log")
        let resolver = try makeFakeRuntime(root: root, invocationLog: invocationLog)
        let actual = root.appending(path: "actual.ogg")
        try Data("source-audio".utf8).write(to: actual)
        let source = root.appending(path: "linked.ogg")
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: actual)

        do {
            _ = try await WebMediaPreparer(resolver: resolver).prepare(
                source: source,
                cacheDirectory: root.appending(path: "cache"),
                timeout: .seconds(30)
            )
            XCTFail("Expected unsafe source rejection")
        } catch let error as WebMediaPreparationError {
            guard case .unsafeSource = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: invocationLog.path))
    }

    func testUnsafeVideoDimensionsAreRejectedBeforeFFmpegRuns() async throws {
        let cases: [(payload: String, error: WebMediaPreparationError)] = [
            ("source-video-zero", .invalidSourceVideoDimensions),
            ("source-video-axis", .sourceVideoDimensionsExceeded),
            ("source-video-pixels", .sourceVideoDimensionsExceeded)
        ]

        for testCase in cases {
            try await assertSourceRejectedBeforeFFmpeg(
                payload: testCase.payload,
                expected: testCase.error
            )
        }
    }

    func testUnsafeAudioParametersAreRejectedBeforeFFmpegRuns() async throws {
        for payload in ["source-audio-channels", "source-audio-rate"] {
            try await assertSourceRejectedBeforeFFmpeg(
                payload: payload,
                expected: .invalidSourceAudioParameters
            )
        }
    }

    func testExcessiveTotalVideoAndAudioStreamCountsAreRejectedBeforeFFmpegRuns() async throws {
        let cases: [[String]] = [
            Array(
                repeating: "video",
                count: WebMediaPreparer.maximumSourceVideoStreamCount + 1
            ),
            ["video"] + Array(
                repeating: "audio",
                count: WebMediaPreparer.maximumSourceAudioStreamCount + 1
            ),
            ["video"] + Array(
                repeating: "subtitle",
                count: WebMediaPreparer.maximumSourceStreamCount
            )
        ]

        for streamTypes in cases {
            let root = try Fixture.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let invocationLog = root.appending(path: "ffmpeg.log")
            let reportJSON = try streamReportJSON(streamTypes: streamTypes)
            let resolver = try makeFakeRuntime(
                root: root,
                invocationLog: invocationLog,
                ffprobeBody: "printf '%s' '\(reportJSON)'"
            )
            let source = root.appending(path: "source.media")
            try Data([0]).write(to: source)

            do {
                _ = try await WebMediaPreparer(resolver: resolver).prepare(
                    source: source,
                    cacheDirectory: root.appending(path: "cache"),
                    timeout: .seconds(30)
                )
                XCTFail("Expected excessive stream metadata to be rejected")
            } catch WebMediaPreparationError.sourceStreamCountExceeded(
                let total,
                let video,
                let audio
            ) {
                XCTAssertEqual(total, streamTypes.count)
                XCTAssertEqual(video, streamTypes.count(where: { $0 == "video" }))
                XCTAssertEqual(audio, streamTypes.count(where: { $0 == "audio" }))
            } catch {
                XCTFail("Expected sourceStreamCountExceeded, got \(error)")
            }

            XCTAssertFalse(FileManager.default.fileExists(atPath: invocationLog.path))
        }
    }

    func testOversizedSparseSourceIsRejectedBeforeProbingOrFFmpeg() async throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let invocationLog = root.appending(path: "ffmpeg.log")
        let resolver = try makeFakeRuntime(root: root, invocationLog: invocationLog)
        let source = root.appending(path: "oversized.ogg")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let handle = try FileHandle(forWritingTo: source)
        let size = WebMediaPreparer.maximumSourceBytes + 1
        try handle.truncate(atOffset: size)
        try handle.close()

        do {
            _ = try await WebMediaPreparer(resolver: resolver).prepare(
                source: source,
                cacheDirectory: root.appending(path: "cache"),
                timeout: .seconds(30)
            )
            XCTFail("Expected source size rejection")
        } catch let error as WebMediaPreparationError {
            XCTAssertEqual(error, .sourceTooLarge(size, WebMediaPreparer.maximumSourceBytes))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: invocationLog.path))
    }

    func testVideoConversionMustRetainAuthoredAudioPackets() async throws {
        for outputMarker in ["converted-video-no-audio", "converted-video-empty-audio"] {
            let root = try Fixture.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let invocationLog = root.appending(path: "ffmpeg.log")
            let resolver = try makeFakeRuntime(
                root: root,
                invocationLog: invocationLog,
                ffmpegBody: "printf '%s' '\(outputMarker)'"
            )
            let source = root.appending(path: "animation.ogv")
            try Data("source-video".utf8).write(to: source)
            let cache = root.appending(path: "cache")

            do {
                _ = try await WebMediaPreparer(resolver: resolver).prepare(
                    source: source,
                    cacheDirectory: cache,
                    timeout: .seconds(30)
                )
                XCTFail("Expected authored audio retention validation")
            } catch let error as WebMediaPreparationError {
                XCTAssertEqual(error, .invalidConvertedOutput)
            }

            XCTAssertEqual(try invocationCount(at: invocationLog), 1)
            XCTAssertTrue(try temporaryMediaFiles(in: cache).isEmpty)
        }
    }

    func testVideoOutputRequiresObservedPacketsNotDeclaredFrameCount() async throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let invocationLog = root.appending(path: "ffmpeg.log")
        let resolver = try makeFakeRuntime(
            root: root,
            invocationLog: invocationLog,
            ffmpegBody: "printf '%s' 'converted-video-declared-only'"
        )
        let source = root.appending(path: "animation.ogv")
        try Data("source-video".utf8).write(to: source)
        let cache = root.appending(path: "cache")

        do {
            _ = try await WebMediaPreparer(resolver: resolver).prepare(
                source: source,
                cacheDirectory: cache,
                timeout: .seconds(30)
            )
            XCTFail("Expected empty video output rejection")
        } catch let error as WebMediaPreparationError {
            XCTAssertEqual(error, .invalidConvertedOutput)
        }

        XCTAssertEqual(try invocationCount(at: invocationLog), 1)
        XCTAssertTrue(try temporaryMediaFiles(in: cache).isEmpty)
    }

    func testAudioOutputRequiresSaneAACParametersAndDuration() async throws {
        for outputMarker in ["converted-audio-invalid", "converted-audio-no-duration"] {
            let root = try Fixture.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let invocationLog = root.appending(path: "ffmpeg.log")
            let resolver = try makeFakeRuntime(
                root: root,
                invocationLog: invocationLog,
                ffmpegBody: "printf '%s' '\(outputMarker)'"
            )
            let source = root.appending(path: "ambience.ogg")
            try Data("source-audio".utf8).write(to: source)
            let cache = root.appending(path: "cache")

            do {
                _ = try await WebMediaPreparer(resolver: resolver).prepare(
                    source: source,
                    cacheDirectory: cache,
                    timeout: .seconds(30)
                )
                XCTFail("Expected invalid AAC output rejection")
            } catch let error as WebMediaPreparationError {
                XCTAssertEqual(error, .invalidConvertedOutput)
            }

            XCTAssertEqual(try invocationCount(at: invocationLog), 1)
            XCTAssertTrue(try temporaryMediaFiles(in: cache).isEmpty)
        }
    }

    func testBundledFFmpegConvertsSyntheticOggVorbisToAACM4A() async throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = MediaToolResolver(
            bundleResourceURL: nil,
            environment: ProcessInfo.processInfo.environment,
            allowDevelopmentFallback: true
        )
        let ffmpeg = try XCTUnwrap(resolver.resolve(.ffmpeg).path)
        let raw = root.appending(path: "stereo-silence.s16le")
        try Data(repeating: 0, count: 48_000).write(to: raw)
        let source = root.appending(path: "synthetic.ogg")
        try requireSuccess(ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "s16le", "-ar", "48000", "-ac", "2",
            "-i", raw.path,
            "-c:a", "vorbis", "-strict", "-2",
            source.path
        ])

        let result = try await WebMediaPreparer(resolver: resolver).prepare(
            source: source,
            cacheDirectory: root.appending(path: "cache"),
            timeout: .seconds(30)
        )

        XCTAssertEqual(result.kind, .audio)
        XCTAssertEqual(result.url.pathExtension, "m4a")
        XCTAssertGreaterThan(
            try result.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,
            0
        )
        let audioIndex = try XCTUnwrap(result.probeReport.preferredAudioStreamIndex)
        XCTAssertEqual(
            result.probeReport.streams.first(where: { $0.index == audioIndex })?.codecName,
            "aac"
        )
        XCTAssertFalse(result.probeReport.hasVideo)
    }

    func testBundledFFmpegConvertsSyntheticAVIToH264OrRejectsFallback() async throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = MediaToolResolver(
            bundleResourceURL: nil,
            environment: ProcessInfo.processInfo.environment,
            allowDevelopmentFallback: true
        )
        let ffmpeg = try XCTUnwrap(resolver.resolve(.ffmpeg).path)
        let raw = root.appending(path: "black-frames.rgb")
        let frameByteCount = 64 * 64 * 3
        try Data(repeating: 0, count: frameByteCount * 5).write(to: raw)
        let rawAudio = root.appending(path: "stereo-silence.s16le")
        try Data(repeating: 0, count: 48_000 * 2 * 2).write(to: rawAudio)
        let source = root.appending(path: "synthetic.avi")
        try requireSuccess(ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "rawvideo", "-pixel_format", "rgb24",
            "-video_size", "64x64", "-framerate", "5",
            "-i", raw.path,
            "-f", "s16le", "-ar", "48000", "-ac", "2",
            "-i", rawAudio.path,
            "-map", "0:v:0", "-map", "1:a:0", "-shortest",
            "-frames:v", "5", "-c:v", "mpeg4", "-c:a", "pcm_s16le",
            "-f", "avi",
            source.path
        ])

        let cache = root.appending(path: "cache")
        do {
            let result = try await WebMediaPreparer(resolver: resolver).prepare(
                source: source,
                cacheDirectory: cache,
                timeout: .seconds(30)
            )

            XCTAssertEqual(result.kind, .video)
            XCTAssertEqual(result.url.pathExtension, "mp4")
            XCTAssertGreaterThan(
                try result.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,
                0
            )
            let videoIndex = try XCTUnwrap(result.probeReport.preferredVideoStreamIndex)
            XCTAssertEqual(
                result.probeReport.streams.first(where: { $0.index == videoIndex })?.codecName,
                "h264"
            )
            let audioIndex = try XCTUnwrap(result.probeReport.preferredAudioStreamIndex)
            let audio = try XCTUnwrap(
                result.probeReport.streams.first(where: { $0.index == audioIndex })
            )
            XCTAssertEqual(audio.codecName, "aac")
            XCTAssertEqual(audio.sampleRate, "48000")
            XCTAssertEqual(audio.channels, 2)
        } catch let error as WebMediaPreparationError {
            // VideoConverter intentionally retains MPEG-4 Part 2 as a native
            // AVPlayer fallback. Web media must fail closed when that fallback
            // was needed because WKWebView does not consistently decode it.
            XCTAssertEqual(error, .invalidConvertedOutput)
            let published = try FileManager.default.contentsOfDirectory(
                at: cache,
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix("web-media-") }
            XCTAssertTrue(published.isEmpty)
            XCTAssertTrue(try temporaryMediaFiles(in: cache).isEmpty)
        }
    }

    private func decodeReport(_ source: String) throws -> MediaProbeReport {
        try JSONDecoder().decode(MediaProbeReport.self, from: Data(source.utf8))
    }

    private func streamReportJSON(streamTypes: [String]) throws -> String {
        let streams: [[String: Any]] = streamTypes.enumerated().map { index, type in
            var stream: [String: Any] = [
                "index": index,
                "codec_type": type
            ]
            if type == "video" {
                stream["width"] = 32
                stream["height"] = 32
            } else if type == "audio" {
                stream["channels"] = 2
                stream["sample_rate"] = "48000"
            }
            return stream
        }
        let data = try JSONSerialization.data(withJSONObject: ["streams": streams])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func assertSourceRejectedBeforeFFmpeg(
        payload: String,
        expected: WebMediaPreparationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let invocationLog = root.appending(path: "ffmpeg.log")
        let resolver = try makeFakeRuntime(root: root, invocationLog: invocationLog)
        let source = root.appending(path: "source.media")
        try Data(payload.utf8).write(to: source)

        do {
            _ = try await WebMediaPreparer(resolver: resolver).prepare(
                source: source,
                cacheDirectory: root.appending(path: "cache"),
                timeout: .seconds(30)
            )
            XCTFail("Expected source validation failure", file: file, line: line)
        } catch let error as WebMediaPreparationError {
            XCTAssertEqual(error, expected, file: file, line: line)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: invocationLog.path),
            "FFmpeg must not run for rejected source metadata",
            file: file,
            line: line
        )
    }

    private func makeFakeRuntime(
        root: URL,
        invocationLog: URL,
        ffmpegBody: String? = nil,
        ffprobeBody: String? = nil
    ) throws -> MediaToolResolver {
        let tools = root.appending(path: "MediaTools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let ffprobe = tools.appending(path: "ffprobe")
        let defaultFFprobeBody = """
        input=''
        descriptor=''
        previous=''
        for argument in "$@"; do
          if [ "$previous" = '-fd' ]; then descriptor="$argument"; fi
          input="$argument"
          previous="$argument"
        done
        if [ "$input" = 'fd:' ] && [ -n "$descriptor" ]; then input="/dev/fd/$descriptor"; fi
        payload=$(/bin/dd if="$input" bs=64 count=1 2>/dev/null || true)
        case "$payload" in
          source-video-zero*)
            printf '%s' '{"streams":[{"index":0,"codec_name":"theora","codec_type":"video","width":0,"height":32}],"format":{"format_name":"ogg","duration":"1.0"}}'
            ;;
          source-video-axis*)
            printf '%s' '{"streams":[{"index":0,"codec_name":"theora","codec_type":"video","width":16385,"height":32}],"format":{"format_name":"ogg","duration":"1.0"}}'
            ;;
          source-video-pixels*)
            printf '%s' '{"streams":[{"index":0,"codec_name":"theora","codec_type":"video","width":8193,"height":8193}],"format":{"format_name":"ogg","duration":"1.0"}}'
            ;;
          source-audio-channels*)
            printf '%s' '{"streams":[{"index":0,"codec_name":"vorbis","codec_type":"audio","sample_rate":"48000","channels":33}],"format":{"format_name":"ogg","duration":"1.0"}}'
            ;;
          source-audio-rate*)
            printf '%s' '{"streams":[{"index":0,"codec_name":"vorbis","codec_type":"audio","sample_rate":"384001","channels":2}],"format":{"format_name":"ogg","duration":"1.0"}}'
            ;;
          source-audio*)
            printf '%s' '{"streams":[{"index":0,"codec_name":"mjpeg","codec_type":"video","disposition":{"attached_pic":1}},{"index":2,"codec_name":"vorbis","codec_type":"audio","sample_rate":"44100","channels":6,"disposition":{"default":1}}],"format":{"format_name":"ogg","duration":"1.0"}}'
            ;;
          source-video*)
            printf '%s' '{"streams":[{"index":0,"codec_name":"theora","codec_type":"video","width":32,"height":32},{"index":1,"codec_name":"vorbis","codec_type":"audio","sample_rate":"44100","channels":2}],"format":{"format_name":"ogg","duration":"1.0"}}'
            ;;
          converted-audio-invalid*)
            printf '%s' '{"streams":[{"index":0,"codec_name":"aac","codec_type":"audio","sample_rate":"1000000","channels":0,"nb_read_packets":"1"}],"format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"1.0"}}'
            ;;
          converted-audio-no-duration*)
            printf '%s' '{"streams":[{"index":0,"codec_name":"aac","codec_type":"audio","sample_rate":"48000","channels":2,"nb_read_packets":"1"}],"format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"0"}}'
            ;;
          converted-audio*)
            printf '%s' '{"streams":[{"index":0,"codec_name":"aac","codec_type":"audio","sample_rate":"48000","channels":2,"nb_read_packets":"1","disposition":{"default":1}}],"format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"1.0"}}'
            ;;
          converted-video-no-audio*)
            printf '%s' '{"streams":[{"index":0,"codec_name":"h264","codec_type":"video","width":32,"height":32,"nb_read_packets":"1"}],"format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"1.0"}}'
            ;;
          converted-video-empty-audio*)
            printf '%s' '{"streams":[{"index":0,"codec_name":"h264","codec_type":"video","width":32,"height":32,"nb_read_packets":"1"},{"index":1,"codec_name":"aac","codec_type":"audio","sample_rate":"48000","channels":2,"nb_read_packets":"0"}],"format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"1.0"}}'
            ;;
          converted-video-declared-only*)
            printf '%s' '{"streams":[{"index":0,"codec_name":"h264","codec_type":"video","width":32,"height":32,"nb_frames":"5","nb_read_packets":"0"}],"format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"1.0"}}'
            ;;
          converted-video-empty*)
            printf '%s' '{"streams":[{"index":0,"codec_name":"h264","codec_type":"video","width":32,"height":32,"nb_read_packets":"0"},{"index":1,"codec_name":"aac","codec_type":"audio","sample_rate":"48000","channels":2}],"format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"1.0"}}'
            ;;
          converted-video-mpeg4*|cached-video-mpeg4*)
            printf '%s' '{"streams":[{"index":0,"codec_name":"mpeg4","codec_type":"video","width":32,"height":32,"nb_read_packets":"1"},{"index":1,"codec_name":"aac","codec_type":"audio","sample_rate":"48000","channels":2,"nb_read_packets":"1"}],"format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"1.0"}}'
            ;;
          converted-video*)
            printf '%s' '{"streams":[{"index":0,"codec_name":"h264","codec_type":"video","width":32,"height":32,"nb_read_packets":"1"},{"index":1,"codec_name":"aac","codec_type":"audio","sample_rate":"48000","channels":2,"nb_read_packets":"1"}],"format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"1.0"}}'
            ;;
          *)
            printf '%s' '{"streams":[],"format":{"format_name":"unknown"}}'
            ;;
        esac
        """
        try Data("""
        #!/bin/sh
        \(ffprobeBody ?? defaultFFprobeBody)
        """.utf8).write(to: ffprobe)

        let ffmpeg = tools.appending(path: "ffmpeg")
        let body = ffmpegBody ?? """
        input=''
        descriptor=''
        previous=''
        for argument in "$@"; do
          if [ "$previous" = '-fd' ]; then descriptor="$argument"; fi
          if [ "$previous" = '-i' ]; then input="$argument"; fi
          previous="$argument"
        done
        if [ "$input" = 'fd:' ] && [ -n "$descriptor" ]; then input="/dev/fd/$descriptor"; fi
        payload=$(/bin/dd if="$input" bs=64 count=1 2>/dev/null || true)
        case "$payload" in
          source-video*) printf '%s' 'converted-video' ;;
          *) printf '%s' 'converted-audio' ;;
        esac
        """
        try Data("""
        #!/bin/sh
        printf '%s\n' "$*" >> "\(invocationLog.path)"
        \(body)
        """.utf8).write(to: ffmpeg)
        for executable in [ffmpeg, ffprobe] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
        }
        return MediaToolResolver(
            bundleResourceURL: root,
            environment: [:],
            allowDevelopmentFallback: false
        )
    }

    private func invocationCount(at url: URL) throws -> Int {
        try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .count
    }

    private func temporaryMediaFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".web-media-") }
    }

    private func waitForProcessIdentifier(at url: URL) async throws -> Int32 {
        for _ in 0..<500 {
            if let value = try? String(contentsOf: url, encoding: .utf8),
               let processIdentifier = Int32(
                value.trimmingCharacters(in: .whitespacesAndNewlines)
               ), processIdentifier > 1 {
                return processIdentifier
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for child process")
        throw CocoaError(.fileReadUnknown)
    }

    private func assertProcessExited(_ processIdentifier: Int32) async {
        for _ in 0..<200 where Darwin.kill(processIdentifier, 0) == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(Darwin.kill(processIdentifier, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    private func requireSuccess(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(data: errorData, encoding: .utf8) ?? ""
        )
        if process.terminationStatus != 0 {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
