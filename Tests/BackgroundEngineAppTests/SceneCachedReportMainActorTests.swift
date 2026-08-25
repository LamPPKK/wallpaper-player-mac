import AppKit
import Darwin
import Foundation
import XCTest
@testable import BackgroundEngineApp
import BackgroundEngineCore

final class SceneCachedReportMainActorTests: XCTestCase {
    @MainActor
    func testCachedPlaybackUsesPersistedProbeWithoutMainActorAnalysisOrMetadataIO() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "scene-cached-main-actor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let packageURL = root.appending(path: "scene.pkg")
        try Data("PKGV-test-fixture".utf8).write(to: packageURL)
        let cacheDirectory = root.appending(path: "SceneVideoCache")
        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        SceneVideoCache.overrideCacheDirectoryURL = cacheDirectory
        defer { SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory }

        let sourceVideoURL = root.appending(path: "rendered.mp4")
        try Data([0, 1, 2, 3]).write(to: sourceVideoURL)
        _ = try SceneVideoCache.install(
            videoAt: sourceVideoURL,
            audioResult: .included,
            at: SceneVideoCache.cachedVideoURL(assetId: "persisted-scene")
        )

        let persistedReport = CompatibilityReport(
            level: .full,
            playbackPath: .renderedSceneCache,
            requiredCapabilities: [.sound]
        )
        let asset = WallpaperAsset(
            id: "persisted-scene",
            title: "Persisted Scene",
            kind: .scene,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: root.path,
            entrypoint: packageURL.path,
            thumbnail: nil,
            workshopId: nil,
            compatibility: .cached(reason: "Rendered Scene cache is available."),
            compatibilityReport: persistedReport,
            redistributionAllowed: false,
            issues: []
        )

        let recorder = SceneCachedValidationRecorder()
        let previousDependencies = SceneWallpaperContentFactory.cachedReportValidationDependencies
        let previousReportHandler = SceneWallpaperContentFactory.compatibilityReportHandler
        var verifiedReport: CompatibilityReport?
        SceneWallpaperContentFactory.cachedReportValidationDependencies = .init(
            analyzeScene: { _ in
                recorder.recordAnalysis(onMainThread: pthread_main_np() != 0)
                return persistedReport
            },
            cachedAudioResult: { _ in
                recorder.recordMetadataRead(onMainThread: pthread_main_np() != 0)
                return .included
            }
        )
        SceneWallpaperContentFactory.compatibilityReportHandler = { _, report in
            if report.level == .full {
                verifiedReport = report
            }
        }
        defer {
            SceneWallpaperContentFactory.cachedReportValidationDependencies = previousDependencies
            SceneWallpaperContentFactory.compatibilityReportHandler = previousReportHandler
        }

        let view = try SceneWallpaperContentFactory.makeSceneContentView(
            asset: asset,
            url: packageURL,
            frame: CGRect(x: 0, y: 0, width: 640, height: 360),
            displayMode: .fill
        )
        defer { (view as? WallpaperContentLifecycle)?.prepareForClose() }

        // The synchronous MainActor path must only construct a conservative
        // report from the persisted probe. The metadata dependency is invoked
        // later by the detached validator, and the package analyzer is not
        // needed at all for a current persisted report.
        XCTAssertEqual(recorder.analysisCount, 0)
        XCTAssertEqual(recorder.mainThreadMetadataReadCount, 0)

        let deadline = Date().addingTimeInterval(2)
        while verifiedReport == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(verifiedReport?.level, .full)
        XCTAssertEqual(verifiedReport?.playbackPath, .renderedSceneCache)
        XCTAssertEqual(recorder.analysisCount, 0)
        XCTAssertEqual(recorder.metadataReadCount, 1)
        XCTAssertEqual(recorder.mainThreadAnalysisCount, 0)
        XCTAssertEqual(recorder.mainThreadMetadataReadCount, 0)
    }

    func testProvisionalReportWithoutPersistedProbeIsFailClosedAndDoesNotReadURL() {
        let inaccessibleURL = URL(filePath: "/path-that-must-not-be-read/scene.pkg")
        let asset = WallpaperAsset(
            id: "unprobed-scene",
            title: "Unprobed Scene",
            kind: .scene,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: inaccessibleURL.deletingLastPathComponent().path,
            entrypoint: inaccessibleURL.path,
            thumbnail: nil,
            workshopId: nil,
            redistributionAllowed: false,
            issues: []
        )

        let report = SceneWallpaperContentFactory.provisionalCachedReport(for: asset)

        XCTAssertEqual(report.level, .limited)
        XCTAssertEqual(report.playbackPath, .renderedSceneCache)
        XCTAssertEqual(report.diagnosticCode, "scene_cache_compatibility_pending")
        XCTAssertTrue(report.needsProbe)
    }

    @MainActor
    func testIncludedRerenderReanalyzesPersistedDegradedAudioReportAndUpgradesToFull() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "scene-cached-audio-upgrade-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appending(path: "scene.pkg")
        try Data("PKGV-test-fixture".utf8).write(to: packageURL)
        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        SceneVideoCache.overrideCacheDirectoryURL = root.appending(path: "SceneVideoCache")
        defer { SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory }
        let sourceVideoURL = root.appending(path: "rendered.mp4")
        try Data([4, 5, 6, 7]).write(to: sourceVideoURL)
        let cacheURL = try SceneVideoCache.install(
            videoAt: sourceVideoURL,
            audioResult: .included,
            at: SceneVideoCache.cachedVideoURL(assetId: "audio-upgrade-scene")
        )

        let degradedReport = CompatibilityReport(
            level: .limited,
            playbackPath: .renderedSceneCache,
            requiredCapabilities: [.sound],
            missingCapabilities: [.sound],
            warnings: ["Authored Scene audio is unavailable in the rendered cache."],
            diagnosticCode: "scene_authored_audio_unavailable"
        )
        let analyzedReport = CompatibilityReport(
            level: .full,
            playbackPath: .renderedSceneCache,
            requiredCapabilities: [.sound]
        )
        let asset = Self.sceneAsset(
            id: "audio-upgrade-scene",
            root: root,
            packageURL: packageURL,
            report: degradedReport
        )
        let recorder = SceneCachedValidationRecorder()
        let previousDependencies = SceneWallpaperContentFactory.cachedReportValidationDependencies
        let previousReportHandler = SceneWallpaperContentFactory.compatibilityReportHandler
        var verifiedReport: CompatibilityReport?
        SceneWallpaperContentFactory.cachedReportValidationDependencies = .init(
            analyzeScene: { _ in
                recorder.recordAnalysis(onMainThread: pthread_main_np() != 0)
                return analyzedReport
            },
            cachedAudioResult: { _ in
                recorder.recordMetadataRead(onMainThread: pthread_main_np() != 0)
                return .included
            }
        )
        SceneWallpaperContentFactory.compatibilityReportHandler = { _, report in
            if report.level == .full {
                verifiedReport = report
            }
        }
        defer {
            SceneWallpaperContentFactory.cachedReportValidationDependencies = previousDependencies
            SceneWallpaperContentFactory.compatibilityReportHandler = previousReportHandler
        }

        SceneWallpaperContentFactory.publishProvisionalCachedReport(
            for: asset,
            sceneURL: packageURL,
            cacheURL: cacheURL,
            preferredCacheKeys: [],
            audioResult: .included
        )

        let deadline = Date().addingTimeInterval(2)
        while verifiedReport == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(verifiedReport?.level, .full)
        XCTAssertFalse(verifiedReport?.missingCapabilities.contains(.sound) == true)
        XCTAssertNil(verifiedReport?.diagnosticCode)
        XCTAssertEqual(recorder.analysisCount, 1)
        XCTAssertEqual(recorder.mainThreadAnalysisCount, 0)
        // The render outcome already supplies the audio state, so no sidecar
        // read is needed while the stale static feature base is reanalyzed.
        XCTAssertEqual(recorder.metadataReadCount, 0)
    }

    @MainActor
    func testNewWarningContextRejectsOlderVerifierCompletionForSameCacheURL() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "scene-cached-warning-race-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appending(path: "scene.pkg")
        try Data("PKGV-test-fixture".utf8).write(to: packageURL)
        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        SceneVideoCache.overrideCacheDirectoryURL = root.appending(path: "SceneVideoCache")
        defer { SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory }
        let sourceVideoURL = root.appending(path: "rendered.mp4")
        try Data([8, 9, 10, 11]).write(to: sourceVideoURL)
        let cacheURL = try SceneVideoCache.install(
            videoAt: sourceVideoURL,
            audioResult: .included,
            at: SceneVideoCache.cachedVideoURL(assetId: "warning-race-scene")
        )

        let persistedReport = CompatibilityReport(
            level: .full,
            playbackPath: .renderedSceneCache,
            requiredCapabilities: [.sound]
        )
        let asset = Self.sceneAsset(
            id: "warning-race-scene",
            root: root,
            packageURL: packageURL,
            report: persistedReport
        )
        let audioLoader = SequencedSceneAudioResultLoader()
        let previousDependencies = SceneWallpaperContentFactory.cachedReportValidationDependencies
        let previousReportHandler = SceneWallpaperContentFactory.compatibilityReportHandler
        var reports: [CompatibilityReport] = []
        SceneWallpaperContentFactory.cachedReportValidationDependencies = .init(
            analyzeScene: { _ in persistedReport },
            cachedAudioResult: { _ in await audioLoader.load() }
        )
        SceneWallpaperContentFactory.compatibilityReportHandler = { _, report in
            reports.append(report)
        }
        defer {
            SceneWallpaperContentFactory.cachedReportValidationDependencies = previousDependencies
            SceneWallpaperContentFactory.compatibilityReportHandler = previousReportHandler
        }

        SceneWallpaperContentFactory.publishProvisionalCachedReport(
            for: asset,
            sceneURL: packageURL,
            cacheURL: cacheURL,
            preferredCacheKeys: []
        )
        let firstWaitDeadline = Date().addingTimeInterval(1)
        while !(await audioLoader.isFirstLoadWaiting()), Date() < firstWaitDeadline {
            await Task.yield()
        }
        let firstLoadIsWaiting = await audioLoader.isFirstLoadWaiting()
        XCTAssertTrue(firstLoadIsWaiting)

        let recoveryWarning = "Native Scene reconstruction failed; using a rendered fallback."
        SceneWallpaperContentFactory.publishProvisionalCachedReport(
            for: asset,
            sceneURL: packageURL,
            cacheURL: cacheURL,
            preferredCacheKeys: [],
            warning: recoveryWarning
        )

        let newContextDeadline = Date().addingTimeInterval(2)
        while !reports.contains(where: { $0.level == .full && $0.warnings.contains(recoveryWarning) }),
              Date() < newContextDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(reports.last?.warnings.contains(recoveryWarning) == true)

        await audioLoader.releaseFirstLoad()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(reports.last?.warnings.contains(recoveryWarning) == true)
        XCTAssertFalse(
            reports.drop(while: { !$0.warnings.contains(recoveryWarning) })
                .contains(where: { $0.level == .full && !$0.warnings.contains(recoveryWarning) })
        )
        let audioLoadCount = await audioLoader.loadCount
        XCTAssertEqual(audioLoadCount, 2)
    }

    private static func sceneAsset(
        id: String,
        root: URL,
        packageURL: URL,
        report: CompatibilityReport
    ) -> WallpaperAsset {
        WallpaperAsset(
            id: id,
            title: id,
            kind: .scene,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: root.path,
            entrypoint: packageURL.path,
            thumbnail: nil,
            workshopId: nil,
            compatibility: .cached(reason: "Rendered Scene cache is available."),
            compatibilityReport: report,
            redistributionAllowed: false,
            issues: []
        )
    }
}

private final class SceneCachedValidationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var analysisThreads: [Bool] = []
    private var metadataReadThreads: [Bool] = []

    func recordAnalysis(onMainThread: Bool) {
        lock.withLock { analysisThreads.append(onMainThread) }
    }

    func recordMetadataRead(onMainThread: Bool) {
        lock.withLock { metadataReadThreads.append(onMainThread) }
    }

    var analysisCount: Int {
        lock.withLock { analysisThreads.count }
    }

    var metadataReadCount: Int {
        lock.withLock { metadataReadThreads.count }
    }

    var mainThreadAnalysisCount: Int {
        lock.withLock { analysisThreads.filter { $0 }.count }
    }

    var mainThreadMetadataReadCount: Int {
        lock.withLock { metadataReadThreads.filter { $0 }.count }
    }
}

private actor SequencedSceneAudioResultLoader {
    private(set) var loadCount = 0
    private var firstContinuation: CheckedContinuation<Void, Never>?

    func load() async -> SceneRenderAudioResult? {
        loadCount += 1
        if loadCount == 1 {
            await withCheckedContinuation { continuation in
                firstContinuation = continuation
            }
        }
        return .included
    }

    func isFirstLoadWaiting() -> Bool {
        firstContinuation != nil
    }

    func releaseFirstLoad() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}
