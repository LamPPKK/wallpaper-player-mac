import Foundation
import XCTest
@testable import BackgroundEngineApp
@testable import BackgroundEngineCore

final class WebMediaRuntimeCoordinatorTests: XCTestCase {
    func testInitializationDoesNotTouchCacheOrInvokeStartupPrune() {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "web-startup-prune-init-\(UUID().uuidString)")
        let cache = root.appending(path: "cache")
        defer { try? FileManager.default.removeItem(at: root) }
        let pruneProbe = StartupPruneProbe()

        _ = WebMediaRuntimeCoordinator(
            playbackProbe: WebMediaPlaybackProbe { _ in true },
            cacheDirectory: cache,
            startupPruneOperation: { _ in pruneProbe.record() },
            preparationOperation: { source, cache, _ in
                PreparationRecorder.result(source: source, cache: cache)
            }
        )

        XCTAssertEqual(pruneProbe.callCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }

    func testConcurrentFirstPreparationsShareOneDetachedStartupPrune() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "web-startup-prune-shared-\(UUID().uuidString)")
        let project = root.appending(path: "project")
        let cache = root.appending(path: "cache")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entrypoint = project.appending(path: "index.html")
        try "<!doctype html><canvas></canvas>".write(
            to: entrypoint,
            atomically: true,
            encoding: .utf8
        )
        let pruneProbe = StartupPruneProbe(blocksUntilReleased: true)
        let coordinator = WebMediaRuntimeCoordinator(
            playbackProbe: WebMediaPlaybackProbe { _ in true },
            cacheDirectory: cache,
            startupPruneOperation: { _ in pruneProbe.record() },
            preparationOperation: { source, cache, _ in
                PreparationRecorder.result(source: source, cache: cache)
            }
        )

        let first = Task {
            try await coordinator.prepareResources(
                entrypoint: entrypoint,
                projectRoot: project
            )
        }
        defer { pruneProbe.release() }
        XCTAssertTrue(pruneProbe.waitUntilEntered())
        let second = Task {
            try await coordinator.prepareResources(
                entrypoint: entrypoint,
                projectRoot: project
            )
        }
        // Give the actor a scheduling point to observe and join the existing
        // detached task before it is released.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(pruneProbe.callCount, 1)
        pruneProbe.release()

        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(pruneProbe.callCount, 1)
    }

    func testStartupPruneEnumerationHonorsDirectoryEntryLimit() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "web-startup-prune-limit-\(UUID().uuidString)")
        let cache = root.appending(path: "cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<3 {
            try Data("entry".utf8).write(
                to: cache.appending(path: "published-\(index).mp4")
            )
        }

        XCTAssertThrowsError(
            try WebMediaPreparer.pruneOrphanedTemporaryFiles(
                in: cache,
                maximumDirectoryEntries: 2
            )
        ) { error in
            XCTAssertEqual(
                error as? WebMediaPreparationError,
                .unsafeCacheDirectory
            )
        }
    }

    func testOpaqueDynamicSourcePreparesSafeProjectMediaCandidatesBeforeLoad() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "web-dynamic-media-\(UUID().uuidString)")
        let project = root.appending(path: "project")
        let nested = project.appending(path: "nested")
        let outside = root.appending(path: "outside.mkv")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entrypoint = project.appending(path: "index.html")
        try #"<script>const media = document.createElement('video'); media.src = selectedFile;</script>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        try Data("RIFF0000AVI fixture".utf8).write(
            to: nested.appending(path: "dynamic.avi")
        )
        try Data([0x1A, 0x45, 0xDF, 0xA3, 0, 1, 2, 3]).write(
            to: nested.appending(path: "extensionless-clip.asset")
        )
        try Data("OggS-audio".utf8).write(to: project.appending(path: "sound.ogg"))
        try Data("console.log('not media')".utf8).write(
            to: project.appending(path: "runtime.js")
        )
        try Data("<html>not media</html>".utf8).write(
            to: project.appending(path: "document.html")
        )
        try Data([0x89, 0x50, 0x4E, 0x47]).write(
            to: project.appending(path: "poster.png")
        )
        try Data([0x1A, 0x45, 0xDF, 0xA3]).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: project.appending(path: "escape.mkv"),
            withDestinationURL: outside
        )
        try Data("RIFF0000AVI hidden".utf8).write(
            to: project.appending(path: ".hidden.avi")
        )

        let recorder = PreparationRecorder()
        let coordinator = WebMediaRuntimeCoordinator(
            playbackProbe: WebMediaPlaybackProbe { _ in true },
            cacheDirectory: root.appending(path: "cache"),
            preparationOperation: { source, cache, _ in
                await recorder.prepare(source: source, cache: cache)
            }
        )

        let resources = try await coordinator.prepareResources(
            entrypoint: entrypoint,
            projectRoot: project
        )

        XCTAssertEqual(
            resources.map(\.sourceURL.lastPathComponent),
            ["dynamic.avi", "extensionless-clip.asset", "sound.ogg"]
        )
        let callCount = await recorder.callCount
        XCTAssertEqual(callCount, 3)
        XCTAssertEqual(
            resources.localResourceMIMEOverrides,
            [WebLocalResourceMIMEOverride(sourceURL: entrypoint, mimeType: "text/html")]
        )
    }

    func testOpaqueDynamicSourceFailsClosedWhenCandidateLimitIsExceeded() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "web-dynamic-media-limit-\(UUID().uuidString)")
        let project = root.appending(path: "project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entrypoint = project.appending(path: "index.html")
        try #"<script>player.src = selectedFile;</script>"#
            .write(to: entrypoint, atomically: true, encoding: .utf8)
        for index in 0...WebDynamicMediaCandidateDiscovery.maximumCandidates {
            try Data("RIFF0000AVI \(index)".utf8).write(
                to: project.appending(path: "candidate-\(index).avi")
            )
        }
        let recorder = PreparationRecorder()
        let coordinator = WebMediaRuntimeCoordinator(
            playbackProbe: WebMediaPlaybackProbe { _ in false },
            cacheDirectory: root.appending(path: "cache"),
            preparationOperation: { source, cache, _ in
                await recorder.prepare(source: source, cache: cache)
            }
        )

        do {
            _ = try await coordinator.prepareResources(
                entrypoint: entrypoint,
                projectRoot: project
            )
            XCTFail("Expected bounded dynamic-media discovery to fail closed")
        } catch let error as WebMediaRuntimeCoordinatorError {
            guard case .dynamicMediaDiscoveryLimitExceeded(
                let maximumEntries,
                let maximumCandidates
            ) = error else {
                return XCTFail("Unexpected coordinator error: \(error)")
            }
            XCTAssertEqual(
                maximumEntries,
                WebDynamicMediaCandidateDiscovery.maximumExaminedEntries
            )
            XCTAssertEqual(
                maximumCandidates,
                WebDynamicMediaCandidateDiscovery.maximumCandidates
            )
        }
        let callCount = await recorder.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testStaticProjectDoesNotPrepareUnreferencedMediaCandidate() async throws {
        let fixture = try makeWebFixture(includeOnlyVideo: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("RIFF0000AVI unused".utf8).write(
            to: fixture.project.appending(path: "unused.avi")
        )
        let recorder = PreparationRecorder()
        let coordinator = WebMediaRuntimeCoordinator(
            playbackProbe: WebMediaPlaybackProbe { _ in true },
            cacheDirectory: fixture.cache,
            preparationOperation: { source, cache, _ in
                await recorder.prepare(source: source, cache: cache)
            }
        )

        let resources = try await coordinator.prepareResources(
            entrypoint: fixture.entrypoint,
            projectRoot: fixture.project
        )

        XCTAssertTrue(resources.isEmpty)
        let callCount = await recorder.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testOneFailedOptionalSourcePreservesSuccessfulPreparedFallback() async throws {
        let fixture = try makeWebFixture(mediaNames: ["broken.ogv", "fallback.ogv"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = WebMediaRuntimeCoordinator(
            playbackProbe: WebMediaPlaybackProbe { _ in false },
            cacheDirectory: fixture.cache,
            preparationOperation: { source, cache, _ in
                if source.lastPathComponent == "broken.ogv" {
                    throw WebMediaPreparationError.unsupportedSource
                }
                return PreparationRecorder.result(source: source, cache: cache)
            }
        )

        let result = try await coordinator.prepareResources(
            entrypoint: fixture.entrypoint,
            projectRoot: fixture.project
        )

        XCTAssertEqual(result.map(\.sourceURL.lastPathComponent), ["fallback.ogv"])
        XCTAssertEqual(result.failures.map(\.sourceURL.lastPathComponent), ["broken.ogv"])
        XCTAssertEqual(result.failures.first?.diagnosticCode, "web_media_preparation_failed")
        XCTAssertEqual(result.warnings.count, 1)
    }

    func testFailedConversionPreservesDirectAuthoredFallback() async throws {
        let fixture = try makeWebFixture(mediaNames: ["broken.ogv", "fallback.mp4"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = WebMediaRuntimeCoordinator(
            playbackProbe: WebMediaPlaybackProbe {
                $0.sourceURL.lastPathComponent == "fallback.mp4"
            },
            cacheDirectory: fixture.cache,
            preparationOperation: { _, _, _ in
                throw WebMediaPreparationError.unsupportedSource
            }
        )

        let result = try await coordinator.prepareResources(
            entrypoint: fixture.entrypoint,
            projectRoot: fixture.project
        )

        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.failures.map(\.sourceURL.lastPathComponent), ["broken.ogv"])
    }

    func testAllFailedLocalSourcesReturnWarningsWithoutBlockingAuthoredFallbacks() async throws {
        let fixture = try makeWebFixture(mediaNames: ["broken.ogv"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = WebMediaRuntimeCoordinator(
            playbackProbe: WebMediaPlaybackProbe { _ in false },
            cacheDirectory: fixture.cache,
            preparationOperation: { _, _, _ in
                throw WebMediaPreparationError.unsupportedSource
            }
        )

        let result = try await coordinator.prepareResources(
            entrypoint: fixture.entrypoint,
            projectRoot: fixture.project
        )

        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.sourceURL.lastPathComponent, "broken.ogv")
        XCTAssertEqual(result.warnings.count, 1)
    }

    func testFailedLocalSourceDoesNotBlockHTTPSAuthoredFallback() async throws {
        let fixture = try makeWebFixture(mediaNames: ["broken.ogv"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data(#"""
        <html><video autoplay>
          <source src="broken.ogv" type="video/ogg">
          <source src="https://media.example.test/fallback.mp4" type="video/mp4">
        </video></html>
        """#.utf8).write(to: fixture.entrypoint)
        let coordinator = WebMediaRuntimeCoordinator(
            playbackProbe: WebMediaPlaybackProbe { _ in false },
            cacheDirectory: fixture.cache,
            preparationOperation: { _, _, _ in
                throw WebMediaPreparationError.unsupportedSource
            }
        )

        let result = try await coordinator.prepareResources(
            entrypoint: fixture.entrypoint,
            projectRoot: fixture.project
        )

        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.failures.map(\.sourceURL.lastPathComponent), ["broken.ogv"])
    }

    func testOpaqueImageExpressionIgnoresUnrelatedCorruptMediaCandidateFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "web-opaque-image-fallback-\(UUID().uuidString)")
        let project = root.appending(path: "project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entrypoint = project.appending(path: "index.html")
        try Data(#"""
        <html><canvas></canvas><img id="poster">
          <script>document.querySelector('#poster').src = selectedPoster;</script>
        </html>
        """#.utf8).write(to: entrypoint)
        try Data("corrupt-media".utf8).write(
            to: project.appending(path: "unused-corrupt.avi")
        )
        let coordinator = WebMediaRuntimeCoordinator(
            playbackProbe: WebMediaPlaybackProbe { _ in false },
            cacheDirectory: root.appending(path: "cache"),
            preparationOperation: { _, _, _ in
                throw WebMediaPreparationError.unsupportedSource
            }
        )

        let result = try await coordinator.prepareResources(
            entrypoint: entrypoint,
            projectRoot: project
        )

        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(
            result.failures.map(\.sourceURL.lastPathComponent),
            ["unused-corrupt.avi"]
        )
    }

    func testProjectDeadlineReturnsPartialSuccessAndCancelsUnfinishedJob() async throws {
        let fixture = try makeWebFixture(mediaNames: ["fast.ogv", "stalled.ogv"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let probe = PartialDeadlineProbe()
        let coordinator = WebMediaRuntimeCoordinator(
            playbackProbe: WebMediaPlaybackProbe { _ in false },
            cacheDirectory: fixture.cache,
            preparationTimeout: .seconds(7_200),
            projectPreparationTimeout: .milliseconds(100),
            preparationOperation: { source, cache, _ in
                try await probe.prepare(source: source, cache: cache)
            }
        )

        let result = try await coordinator.prepareResources(
            entrypoint: fixture.entrypoint,
            projectRoot: fixture.project
        )

        XCTAssertEqual(result.map(\.sourceURL.lastPathComponent), ["fast.ogv"])
        XCTAssertEqual(result.failures.map(\.sourceURL.lastPathComponent), ["stalled.ogv"])
        XCTAssertEqual(result.failures.first?.diagnosticCode, "web_media_project_deadline")
        try await probe.waitUntilStalledJobCancelled()
        let stalledWasCancelled = await probe.stalledWasCancelled
        XCTAssertTrue(stalledWasCancelled)
    }

    func testProjectDeadlineLeavesOrphanTrackedUntilMaintenanceCanReapIt() async throws {
        let fixture = try makeWebFixture(mediaNames: ["stalled.ogv"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let preparation = DeadlineReapingGate()
        let maintenance = CacheOperationProbe()
        let coordinator = WebMediaRuntimeCoordinator(
            playbackProbe: WebMediaPlaybackProbe { _ in false },
            cacheDirectory: fixture.cache,
            projectPreparationTimeout: .milliseconds(100),
            preparationOperation: { source, cache, _ in
                await preparation.prepare(source: source, cache: cache)
            }
        )

        let result = try await coordinator.prepareResources(
            entrypoint: fixture.entrypoint,
            projectRoot: fixture.project
        )
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(
            result.failures.first?.diagnosticCode,
            "web_media_project_deadline"
        )

        let clear = Task {
            try await coordinator.performCacheMaintenance { _ in
                await maintenance.recordEntry()
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        var maintenanceEntered = await maintenance.entered
        XCTAssertFalse(maintenanceEntered)

        await preparation.release()
        try await maintenance.waitUntilEntered()
        try await clear.value
        maintenanceEntered = await maintenance.entered
        XCTAssertTrue(maintenanceEntered)
    }

    func testOneDisplayDeadlineDoesNotCancelJobStillNeededByAnotherDisplay() async throws {
        let fixture = try makeWebFixture(mediaNames: ["shared.ogv"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = PreparationGate()
        let coordinator = WebMediaRuntimeCoordinator(
            playbackProbe: WebMediaPlaybackProbe { _ in false },
            cacheDirectory: fixture.cache,
            projectPreparationTimeout: .milliseconds(500),
            preparationOperation: { source, cache, _ in
                try await gate.prepare(source: source, cache: cache)
            }
        )

        let firstDisplay = Task {
            try await coordinator.prepareResources(
                entrypoint: fixture.entrypoint,
                projectRoot: fixture.project
            )
        }
        try await gate.waitUntilStarted()
        try await Task.sleep(for: .milliseconds(250))
        let secondDisplay = Task {
            try await coordinator.prepareResources(
                entrypoint: fixture.entrypoint,
                projectRoot: fixture.project
            )
        }

        let firstResult = try await firstDisplay.value
        XCTAssertTrue(firstResult.isEmpty)
        XCTAssertEqual(
            firstResult.failures.first?.diagnosticCode,
            "web_media_project_deadline"
        )
        var wasCancelled = await gate.wasCancelled
        XCTAssertFalse(wasCancelled)

        await gate.release()
        let resources = try await secondDisplay.value
        XCTAssertEqual(resources.map(\.sourceURL.lastPathComponent), ["shared.ogv"])
        wasCancelled = await gate.wasCancelled
        XCTAssertFalse(wasCancelled)
        let callCount = await gate.callCount
        XCTAssertEqual(callCount, 1)
    }

    func testDefaultProjectDeadlineIsFarBelowPerFileConversionBudget() {
        XCTAssertLessThan(
            WebMediaRuntimeCoordinator.defaultProjectPreparationTimeout,
            WebMediaRuntimeCoordinator.defaultPreparationTimeout / 4
        )
    }

    func testPreparesOnlyNonDirectLocalMediaAndMapsMIMETypes() async throws {
        let fixture = try makeWebFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recorder = PreparationRecorder()
        let coordinator = WebMediaRuntimeCoordinator(
            playbackProbe: WebMediaPlaybackProbe { reference in
                reference.sourceURL.lastPathComponent == "direct.mp4"
            },
            cacheDirectory: fixture.cache,
            preparationTimeout: .seconds(5),
            preparationOperation: { source, cache, _ in
                await recorder.prepare(source: source, cache: cache)
            }
        )

        let resources = try await coordinator.prepareResources(
            entrypoint: fixture.entrypoint,
            projectRoot: fixture.project
        )

        XCTAssertEqual(resources.map(\.sourceURL.lastPathComponent), [
            "ambience.ogg",
            "animation.ogv"
        ])
        XCTAssertEqual(resources.map(\.mimeType), ["audio/mp4", "video/mp4"])
        let callCount = await recorder.callCount
        let cacheDirectories = await recorder.cacheDirectories
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(
            Set(cacheDirectories),
            Set([fixture.cache.standardizedFileURL])
        )
    }

    func testConcurrentDisplaysShareJobAndCancellingOneWaiterDoesNotCancelIt() async throws {
        let fixture = try makeWebFixture(includeOnlyVideo: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = PreparationGate()
        let coordinator = WebMediaRuntimeCoordinator(
            playbackProbe: WebMediaPlaybackProbe { _ in false },
            cacheDirectory: fixture.cache,
            preparationTimeout: .seconds(5),
            preparationOperation: { source, cache, _ in
                try await gate.prepare(source: source, cache: cache)
            }
        )

        let first = Task {
            try await coordinator.prepareResources(
                entrypoint: fixture.entrypoint,
                projectRoot: fixture.project
            )
        }
        let second = Task {
            try await coordinator.prepareResources(
                entrypoint: fixture.entrypoint,
                projectRoot: fixture.project
            )
        }
        try await gate.waitUntilStarted()
        var callCount = await gate.callCount
        XCTAssertEqual(callCount, 1)

        first.cancel()
        do {
            _ = try await first.value
            XCTFail("Expected the first display waiter to be cancelled")
        } catch is CancellationError {
            // Expected. The conversion remains alive for the second display.
        }
        callCount = await gate.callCount
        var wasCancelled = await gate.wasCancelled
        XCTAssertEqual(callCount, 1)
        XCTAssertFalse(wasCancelled)

        await gate.release()
        let resources = try await second.value
        XCTAssertEqual(resources.count, 1)
        XCTAssertEqual(resources.first?.sourceURL.lastPathComponent, "animation.ogv")
        XCTAssertEqual(resources.first?.mimeType, "video/mp4")
        callCount = await gate.callCount
        wasCancelled = await gate.wasCancelled
        XCTAssertEqual(callCount, 1)
        XCTAssertFalse(wasCancelled)
    }

    func testDelayedScopedCancellationPreservesNewWaiterSharingOldJob() async throws {
        let fixture = try makeWebFixture(includeOnlyVideo: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = PreparationGate()
        let registrations = LifecycleScopeRegistrationProbe()
        let coordinator = WebMediaRuntimeCoordinator(
            playbackProbe: WebMediaPlaybackProbe { _ in false },
            cacheDirectory: fixture.cache,
            waiterRegistrationObserver: { scope in
                registrations.record(scope)
            },
            preparationOperation: { source, cache, _ in
                try await gate.prepare(source: source, cache: cache)
            }
        )

        let oldScope = coordinator.makePlaybackScope()
        let checkpoint = coordinator.cancellationCheckpoint()
        XCTAssertEqual(checkpoint, oldScope)
        let oldDisplay = Task {
            try await coordinator.prepareResources(
                entrypoint: fixture.entrypoint,
                projectRoot: fixture.project,
                lifecycleScope: oldScope
            )
        }
        await registrations.waitForRegistration(of: oldScope)
        try await gate.waitUntilStarted()

        let newScope = coordinator.makePlaybackScope()
        let newDisplay = Task {
            try await coordinator.prepareResources(
                entrypoint: fixture.entrypoint,
                projectRoot: fixture.project,
                lifecycleScope: newScope
            )
        }
        await registrations.waitForRegistration(of: newScope)

        // This cancellation is deliberately delivered after the newer waiter
        // has joined the old conversion. Its retained checkpoint may remove
        // only the old waiter, never the shared job or the newer session.
        await coordinator.cancelAll(upTo: checkpoint)
        do {
            _ = try await oldDisplay.value
            XCTFail("Expected the waiter covered by the old checkpoint to cancel")
        } catch is CancellationError {
            // Expected.
        }
        var callCount = await gate.callCount
        var wasCancelled = await gate.wasCancelled
        XCTAssertEqual(callCount, 1)
        XCTAssertFalse(wasCancelled)

        await gate.release()
        let resources = try await newDisplay.value
        XCTAssertEqual(resources.count, 1)
        resources.releaseCacheHandoff()
        callCount = await gate.callCount
        wasCancelled = await gate.wasCancelled
        XCTAssertEqual(callCount, 1)
        XCTAssertFalse(wasCancelled)
    }

    func testCancellationWatermarkRejectsOldScopeBeforeRegistration() async throws {
        let fixture = try makeWebFixture(includeOnlyVideo: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recorder = PreparationRecorder()
        let registrations = LifecycleScopeRegistrationProbe()
        let registrationGate = WaiterRegistrationGate()
        let coordinator = WebMediaRuntimeCoordinator(
            playbackProbe: WebMediaPlaybackProbe { _ in false },
            cacheDirectory: fixture.cache,
            waiterWillRegisterObserver: { _ in
                await registrationGate.pauseBeforeRegistration()
            },
            waiterRegistrationObserver: { scope in
                registrations.record(scope)
            },
            preparationOperation: { source, cache, _ in
                await recorder.prepare(source: source, cache: cache)
            }
        )

        let oldScope = coordinator.makePlaybackScope()
        let checkpoint = coordinator.cancellationCheckpoint()
        let oldDisplay = Task {
            try await coordinator.prepareResources(
                entrypoint: fixture.entrypoint,
                projectRoot: fixture.project,
                lifecycleScope: oldScope
            )
        }
        await registrationGate.waitUntilPaused()

        // The request already passed its entry check, but has not registered
        // a waiter. The retained watermark in registerOrStart must still reject
        // it after this delayed lifecycle cancellation completes.
        await coordinator.cancelAll(upTo: checkpoint)
        var callCount = await recorder.callCount
        XCTAssertEqual(callCount, 0)
        XCTAssertFalse(registrations.hasRegistered(oldScope))
        await registrationGate.resumeRegistration()

        do {
            _ = try await oldDisplay.value
            XCTFail("Expected the retained cancellation watermark to reject the old scope")
        } catch is CancellationError {
            // Expected. No waiter or converter may be registered afterward.
        }
        callCount = await recorder.callCount
        XCTAssertEqual(callCount, 0)
        XCTAssertFalse(registrations.hasRegistered(oldScope))
    }

    func testScopedCancellationStopsActiveAsyncPlaybackProbeBeforePreparation() async throws {
        let fixture = try makeWebFixture(includeOnlyVideo: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let probeGate = AsyncPlaybackProbeCancellationGate()
        let preparationRecorder = PreparationRecorder()
        let playbackProbe = WebMediaPlaybackProbe(
            isDirectlyPlayable: { _ in false },
            asynchronouslyIsDirectlyPlayable: { _ in
                await probeGate.inspectUntilCancelled()
            }
        )
        let coordinator = WebMediaRuntimeCoordinator(
            playbackProbe: playbackProbe,
            cacheDirectory: fixture.cache,
            preparationOperation: { source, cache, _ in
                await preparationRecorder.prepare(source: source, cache: cache)
            }
        )
        let scope = coordinator.makePlaybackScope()
        let checkpoint = coordinator.cancellationCheckpoint()
        let preparation = Task {
            try await coordinator.prepareResources(
                entrypoint: fixture.entrypoint,
                projectRoot: fixture.project,
                lifecycleScope: scope
            )
        }
        await probeGate.waitUntilStarted()

        let cancellationStart = ContinuousClock.now
        await coordinator.cancelAll(upTo: checkpoint)
        do {
            _ = try await preparation.value
            XCTFail("Expected lifecycle cancellation during the playback probe")
        } catch is CancellationError {
            // Expected.
        }
        let cancellationDuration = cancellationStart.duration(to: .now)
        await probeGate.waitUntilCancelled()

        let probeWasCancelled = await probeGate.wasCancelled
        let preparationCallCount = await preparationRecorder.callCount
        XCTAssertTrue(probeWasCancelled)
        XCTAssertEqual(preparationCallCount, 0)
        XCTAssertLessThan(
            cancellationDuration,
            .seconds(2),
            "Scoped cancellation must not wait for the 15-second probe deadline."
        )
    }

    func testScopedCancellationDoesNotAwaitUncooperativeAsyncPlaybackProbe() async throws {
        let fixture = try makeWebFixture(includeOnlyVideo: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let probeGate = UncooperativeAsyncPlaybackProbeGate()
        let preparationRecorder = PreparationRecorder()
        let coordinator = WebMediaRuntimeCoordinator(
            playbackProbe: WebMediaPlaybackProbe(
                isDirectlyPlayable: { _ in false },
                asynchronouslyIsDirectlyPlayable: { _ in
                    await probeGate.inspectIgnoringCancellation()
                }
            ),
            cacheDirectory: fixture.cache,
            preparationOperation: { source, cache, _ in
                await preparationRecorder.prepare(source: source, cache: cache)
            }
        )
        let scope = coordinator.makePlaybackScope()
        let checkpoint = coordinator.cancellationCheckpoint()
        let preparation = Task {
            try await coordinator.prepareResources(
                entrypoint: fixture.entrypoint,
                projectRoot: fixture.project,
                lifecycleScope: scope
            )
        }
        await probeGate.waitUntilStarted()

        let cancellationStart = ContinuousClock.now
        await coordinator.cancelAll(upTo: checkpoint)
        do {
            _ = try await preparation.value
            XCTFail("Expected lifecycle cancellation to abandon the stalled probe")
        } catch is CancellationError {
            // Expected even though the detached probe deliberately ignores it.
        }
        let cancellationDuration = cancellationStart.duration(to: .now)
        let preparationCallCount = await preparationRecorder.callCount
        XCTAssertEqual(preparationCallCount, 0)
        XCTAssertLessThan(cancellationDuration, .seconds(2))

        // Let the deliberately uncooperative fixture finish so the coordinator
        // can best-effort reap its detached task before test teardown.
        await probeGate.release()
    }

    func testSynchronousCompatibilityAnalysisNeverInvokesAsyncPlaybackProbe() throws {
        let mediaNames = (0..<64).map { "authored-\($0).ogv" }
        let fixture = try makeWebFixture(mediaNames: mediaNames)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let invocations = PlaybackProbeInvocationCounter()
        let playbackProbe = WebMediaPlaybackProbe(
            isDirectlyPlayable: { _ in
                invocations.recordSynchronousCall()
                return false
            },
            asynchronouslyIsDirectlyPlayable: { _ in
                invocations.recordAsynchronousCall()
                return true
            }
        )

        let report = WallpaperCompatibilityAnalyzer(
            webMediaPlaybackProbe: playbackProbe
        ).analyze(
            kind: .web,
            status: .playable,
            entrypoint: fixture.entrypoint,
            projectRoot: fixture.project
        )

        XCTAssertEqual(report.playbackPath, .webLive)
        XCTAssertEqual(invocations.synchronousCallCount, mediaNames.count)
        XCTAssertEqual(
            invocations.asynchronousCallCount,
            0,
            "Compatibility analysis must never perform up to 64 AV-style async waits."
        )
    }

    func testAllDirectMediaReturnsNoResourcesWithoutCallingPreparer() async throws {
        let fixture = try makeWebFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recorder = PreparationRecorder()
        let coordinator = WebMediaRuntimeCoordinator(
            playbackProbe: WebMediaPlaybackProbe { _ in true },
            cacheDirectory: fixture.cache,
            preparationOperation: { source, cache, _ in
                await recorder.prepare(source: source, cache: cache)
            }
        )

        let resources = try await coordinator.prepareResources(
            entrypoint: fixture.entrypoint,
            projectRoot: fixture.project
        )

        XCTAssertTrue(resources.isEmpty)
        let callCount = await recorder.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testImmediatePreparerCannotCompleteBeforeWaiterRegistration() async throws {
        let fixture = try makeWebFixture(includeOnlyVideo: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recorder = PreparationRecorder()
        let coordinator = WebMediaRuntimeCoordinator(
            playbackProbe: WebMediaPlaybackProbe { _ in false },
            cacheDirectory: fixture.cache,
            preparationOperation: { source, cache, _ in
                await recorder.prepare(source: source, cache: cache)
            }
        )

        for _ in 0..<100 {
            let resources = try await coordinator.prepareResources(
                entrypoint: fixture.entrypoint,
                projectRoot: fixture.project
            )
            XCTAssertEqual(resources.count, 1)
            XCTAssertEqual(resources.first?.mimeType, "video/mp4")
        }
    }

    func testPreparationLimiterAllowsAtMostTwoActiveConverters() async throws {
        let fixture = try makeWebFixture(mediaNames: [
            "one.ogv", "two.ogv", "three.ogv"
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = ConcurrencyGate()
        let coordinator = WebMediaRuntimeCoordinator(
            playbackProbe: WebMediaPlaybackProbe { _ in false },
            cacheDirectory: fixture.cache,
            maximumConcurrentPreparations: 2,
            preparationOperation: { source, cache, _ in
                try await gate.prepare(source: source, cache: cache)
            }
        )

        let preparation = Task {
            try await coordinator.prepareResources(
                entrypoint: fixture.entrypoint,
                projectRoot: fixture.project
            )
        }
        try await gate.waitForCallCount(2)
        try await Task.sleep(for: .milliseconds(50))
        var metrics = await gate.metrics
        XCTAssertEqual(metrics.calls, 2)
        XCTAssertEqual(metrics.maximumActive, 2)

        await gate.releaseOne()
        try await gate.waitForCallCount(3)
        metrics = await gate.metrics
        XCTAssertEqual(metrics.calls, 3)
        XCTAssertEqual(metrics.maximumActive, 2)

        await gate.releaseAll()
        let resources = try await preparation.value
        XCTAssertEqual(resources.count, 3)
        metrics = await gate.metrics
        XCTAssertEqual(metrics.maximumActive, 2)
        XCTAssertEqual(metrics.active, 0)
    }

    func testCancellingLastWaiterCancelsOrphanedConversion() async throws {
        let fixture = try makeWebFixture(includeOnlyVideo: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let probe = CancellationProbe()
        let coordinator = WebMediaRuntimeCoordinator(
            playbackProbe: WebMediaPlaybackProbe { _ in false },
            cacheDirectory: fixture.cache,
            preparationOperation: { source, cache, _ in
                try await probe.prepare(source: source, cache: cache)
            }
        )
        let task = Task {
            try await coordinator.prepareResources(
                entrypoint: fixture.entrypoint,
                projectRoot: fixture.project
            )
        }
        try await probe.waitUntilStarted()

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected waiter cancellation")
        } catch is CancellationError {
            // Expected.
        }
        try await probe.waitUntilCancelled()
        let wasCancelled = await probe.wasCancelled
        XCTAssertTrue(wasCancelled)
    }

    func testStaleCompletionCannotConsumeReplacementJobForSameSource() async throws {
        let fixture = try makeWebFixture(includeOnlyVideo: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = ABAJobGate()
        let completions = JobCompletionCounter()
        let secondResult = AsyncCompletionProbe()
        let coordinator = WebMediaRuntimeCoordinator(
            playbackProbe: WebMediaPlaybackProbe { _ in false },
            cacheDirectory: fixture.cache,
            jobCompletionObserver: { _ in await completions.recordCompletion() },
            preparationOperation: { source, cache, _ in
                await gate.prepare(source: source, cache: cache)
            }
        )

        let first = Task {
            try await coordinator.prepareResources(
                entrypoint: fixture.entrypoint,
                projectRoot: fixture.project
            )
        }
        try await gate.waitForCallCount(1)
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("Expected the first generation waiter to be cancelled")
        } catch is CancellationError {
            // The detached preparation intentionally remains blocked below.
        }

        let second = Task {
            do {
                let resources = try await coordinator.prepareResources(
                    entrypoint: fixture.entrypoint,
                    projectRoot: fixture.project
                )
                await secondResult.recordSuccess()
                return resources
            } catch {
                await secondResult.recordFailure()
                throw error
            }
        }
        try await gate.waitForCallCount(2)

        // Complete the cancelled, stale generation only after its replacement
        // exists. The completion observer makes this an ordering assertion,
        // rather than relying on a timing window.
        await gate.release(call: 1)
        try await completions.waitForCount(1)
        let completedFromStaleGeneration = await secondResult.isCompleted
        XCTAssertFalse(completedFromStaleGeneration)

        await gate.release(call: 2)
        let resources = try await second.value
        XCTAssertEqual(resources.count, 1)
        XCTAssertEqual(resources.first?.preparedURL.lastPathComponent, "generation-2.mp4")
    }

    func testCancelAllWaitsForConversionCleanupAndResumesDisplayWaiters() async throws {
        let fixture = try makeWebFixture(includeOnlyVideo: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let probe = CancellationProbe()
        let coordinator = WebMediaRuntimeCoordinator(
            playbackProbe: WebMediaPlaybackProbe { _ in false },
            cacheDirectory: fixture.cache,
            preparationOperation: { source, cache, _ in
                try await probe.prepare(source: source, cache: cache)
            }
        )
        let display = Task {
            try await coordinator.prepareResources(
                entrypoint: fixture.entrypoint,
                projectRoot: fixture.project
            )
        }
        try await probe.waitUntilStarted()

        await coordinator.cancelAll()

        do {
            _ = try await display.value
            XCTFail("Expected cache-clear cancellation")
        } catch is CancellationError {
            // Expected.
        }
        let wasCancelled = await probe.wasCancelled
        XCTAssertTrue(wasCancelled)
    }

    func testCacheMaintenanceBlocksRetryAndCancellationDoesNotHang() async throws {
        let fixture = try makeWebFixture(includeOnlyVideo: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(
            at: fixture.cache,
            withIntermediateDirectories: true
        )
        let marker = fixture.cache.appending(path: "stale-cache-entry.mp4")
        try Data("stale".utf8).write(to: marker)
        let preparation = ClearRetryPreparationGate()
        let maintenance = CacheMaintenanceGate()
        let coordinator = WebMediaRuntimeCoordinator(
            playbackProbe: WebMediaPlaybackProbe { _ in false },
            cacheDirectory: fixture.cache,
            preparationOperation: { source, cache, _ in
                try await preparation.prepare(source: source, cache: cache)
            }
        )

        let originalDisplay = Task {
            try await coordinator.prepareResources(
                entrypoint: fixture.entrypoint,
                projectRoot: fixture.project
            )
        }
        try await preparation.waitForCallCount(1)

        let clear = Task {
            try await coordinator.performCacheMaintenance { cacheDirectory in
                await maintenance.pause()
                if FileManager.default.fileExists(atPath: cacheDirectory.path) {
                    try FileManager.default.removeItem(at: cacheDirectory)
                }
            }
        }
        try await maintenance.waitUntilPaused()

        do {
            _ = try await originalDisplay.value
            XCTFail("Expected the display active at clear time to be cancelled")
        } catch is CancellationError {
            // Cleared waiters are resumed before converter drain/deletion.
        }
        let firstWasCancelled = await preparation.firstWasCancelled
        XCTAssertTrue(firstWasCancelled)

        let cancelledRetry = Task {
            try await coordinator.prepareResources(
                entrypoint: fixture.entrypoint,
                projectRoot: fixture.project
            )
        }
        await Task.yield()
        cancelledRetry.cancel()
        do {
            _ = try await cancelledRetry.value
            XCTFail("Expected retry cancellation during maintenance")
        } catch is CancellationError {
            // The maintenance gate removes and resumes cancelled waiters.
        }

        let liveRetry = Task {
            try await coordinator.prepareResources(
                entrypoint: fixture.entrypoint,
                projectRoot: fixture.project
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        var callCount = await preparation.callCount
        XCTAssertEqual(callCount, 1)

        await maintenance.release()
        try await clear.value
        let resources = try await liveRetry.value
        XCTAssertEqual(resources.count, 1)
        callCount = await preparation.callCount
        XCTAssertEqual(callCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testCacheMaintenanceDrainsOrphanedCancelledGenerationBeforeDeletion() async throws {
        let fixture = try makeWebFixture(includeOnlyVideo: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let preparation = ABAJobGate()
        let deletion = CacheOperationProbe()
        let coordinator = WebMediaRuntimeCoordinator(
            playbackProbe: WebMediaPlaybackProbe { _ in false },
            cacheDirectory: fixture.cache,
            preparationOperation: { source, cache, _ in
                await preparation.prepare(source: source, cache: cache)
            }
        )

        let display = Task {
            try await coordinator.prepareResources(
                entrypoint: fixture.entrypoint,
                projectRoot: fixture.project
            )
        }
        try await preparation.waitForCallCount(1)
        display.cancel()
        do {
            _ = try await display.value
            XCTFail("Expected the orphaned generation waiter to be cancelled")
        } catch is CancellationError {
            // Its detached operation deliberately ignores cancellation.
        }

        let clear = Task {
            try await coordinator.performCacheMaintenance { _ in
                await deletion.recordEntry()
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        var deletionEntered = await deletion.entered
        XCTAssertFalse(deletionEntered)

        await preparation.release(call: 1)
        try await deletion.waitUntilEntered()
        try await clear.value
        deletionEntered = await deletion.entered
        XCTAssertTrue(deletionEntered)
    }

    func testClearCacheDeletesDerivedDirectory() async throws {
        let fixture = try makeWebFixture(includeOnlyVideo: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(
            at: fixture.cache,
            withIntermediateDirectories: true
        )
        try Data("cached".utf8).write(
            to: fixture.cache.appending(path: "derived.mp4")
        )
        let coordinator = WebMediaRuntimeCoordinator(
            playbackProbe: WebMediaPlaybackProbe { _ in false },
            cacheDirectory: fixture.cache,
            preparationOperation: { source, cache, _ in
                PreparationRecorder.result(source: source, cache: cache)
            }
        )

        try await coordinator.clearCache()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cache.path))
    }

    func testCacheMaintenanceWaitsForCompletedResultHandoff() async throws {
        let fixture = try makeWebFixture(includeOnlyVideo: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let maintenance = CacheOperationProbe()
        let coordinator = WebMediaRuntimeCoordinator(
            playbackProbe: WebMediaPlaybackProbe { _ in false },
            cacheDirectory: fixture.cache,
            preparationOperation: { source, cache, _ in
                PreparationRecorder.result(source: source, cache: cache)
            }
        )

        var resources: WebMediaRuntimePreparationResult? = try await coordinator.prepareResources(
            entrypoint: fixture.entrypoint,
            projectRoot: fixture.project
        )
        XCTAssertEqual(resources?.count, 1)

        let clear = Task {
            try await coordinator.performCacheMaintenance { _ in
                await maintenance.recordEntry()
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        var maintenanceEntered = await maintenance.entered
        XCTAssertFalse(
            maintenanceEntered,
            "A published pathname must stay protected until the view pins it."
        )

        resources?.releaseCacheHandoff()
        resources = nil
        try await maintenance.waitUntilEntered()
        try await clear.value
        maintenanceEntered = await maintenance.entered
        XCTAssertTrue(maintenanceEntered)
    }

    func testCacheMaintenanceWaitsAcrossJobCompletionToResultAggregationGap() async throws {
        let fixture = try makeWebFixture(includeOnlyVideo: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let aggregation = HandoffAggregationGate()
        let leaseWait = AsyncTestSignal()
        let maintenance = CacheOperationProbe()
        let coordinator = WebMediaRuntimeCoordinator(
            playbackProbe: WebMediaPlaybackProbe { _ in false },
            cacheDirectory: fixture.cache,
            preparedMediaHandoffObserver: { _ in
                await aggregation.pauseBeforeAggregation()
            },
            resultLeaseWaitObserver: {
                await leaseWait.signal()
            },
            preparationOperation: { source, cache, _ in
                PreparationRecorder.result(source: source, cache: cache)
            }
        )

        let preparation = Task {
            try await coordinator.prepareResources(
                entrypoint: fixture.entrypoint,
                projectRoot: fixture.project
            )
        }
        await aggregation.waitUntilPaused()

        let clear = Task {
            try await coordinator.performCacheMaintenance { _ in
                await maintenance.recordEntry()
            }
        }
        await leaseWait.wait()
        var maintenanceEntered = await maintenance.entered
        XCTAssertFalse(
            maintenanceEntered,
            "Maintenance must observe a lease before result aggregation resumes."
        )

        await aggregation.resumeAggregation()
        let resources = try await preparation.value
        XCTAssertEqual(resources.count, 1)
        maintenanceEntered = await maintenance.entered
        XCTAssertFalse(
            maintenanceEntered,
            "The returned path stays protected until its consumer pins it."
        )

        resources.releaseCacheHandoff()
        try await maintenance.waitUntilEntered()
        try await clear.value
        maintenanceEntered = await maintenance.entered
        XCTAssertTrue(maintenanceEntered)
    }

    func testJobCancelledWhileWaitingForPermitNeverEntersPreparer() async throws {
        let firstFixture = try makeWebFixture(includeOnlyVideo: true)
        let secondFixture = try makeWebFixture(includeOnlyVideo: true)
        defer {
            try? FileManager.default.removeItem(at: firstFixture.root)
            try? FileManager.default.removeItem(at: secondFixture.root)
        }
        let gate = QueuedPreparationGate()
        let coordinator = WebMediaRuntimeCoordinator(
            playbackProbe: WebMediaPlaybackProbe { _ in false },
            cacheDirectory: firstFixture.cache,
            maximumConcurrentPreparations: 1,
            preparationOperation: { source, cache, _ in
                try await gate.prepare(source: source, cache: cache)
            }
        )
        let first = Task {
            try await coordinator.prepareResources(
                entrypoint: firstFixture.entrypoint,
                projectRoot: firstFixture.project
            )
        }
        try await gate.waitForCallCount(1)
        let second = Task {
            try await coordinator.prepareResources(
                entrypoint: secondFixture.entrypoint,
                projectRoot: secondFixture.project
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        var callCount = await gate.callCount
        XCTAssertEqual(callCount, 1)

        second.cancel()
        do {
            _ = try await second.value
            XCTFail("Expected queued waiter cancellation")
        } catch is CancellationError {
            // Expected.
        }
        await gate.releaseFirst()
        let firstResources = try await first.value
        XCTAssertEqual(firstResources.count, 1)
        try await Task.sleep(for: .milliseconds(50))
        callCount = await gate.callCount
        XCTAssertEqual(callCount, 1)
    }

    func testDefaultCacheDirectoryUsesApplicationSupportLayout() {
        let url = WebMediaRuntimeCoordinator.defaultCacheDirectory()
        XCTAssertEqual(url.lastPathComponent, "WebMediaCache")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Background Engine")
    }

    private func makeWebFixture(
        includeOnlyVideo: Bool = false
    ) throws -> (root: URL, project: URL, entrypoint: URL, cache: URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "web-media-runtime-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = root.appending(path: "project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let entrypoint = project.appending(path: "index.html")
        let markup: String
        if includeOnlyVideo {
            markup = #"<html><video src="animation.ogv"></video></html>"#
        } else {
            markup = #"""
            <html>
              <video src="direct.mp4"></video>
              <video src="animation.ogv"></video>
              <audio src="ambience.ogg"></audio>
            </html>
            """#
        }
        try Data(markup.utf8).write(to: entrypoint)
        for name in ["direct.mp4", "animation.ogv", "ambience.ogg"] {
            try Data("fixture-\(name)".utf8).write(to: project.appending(path: name))
        }
        return (
            root,
            project,
            entrypoint,
            root.appending(path: "cache", directoryHint: .isDirectory)
        )
    }

    private func makeWebFixture(
        mediaNames: [String]
    ) throws -> (root: URL, project: URL, entrypoint: URL, cache: URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "web-media-runtime-\(UUID().uuidString)", directoryHint: .isDirectory)
        let project = root.appending(path: "project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let mediaElements = mediaNames
            .map { #"<video src="\#($0)"></video>"# }
            .joined(separator: "\n")
        let entrypoint = project.appending(path: "index.html")
        try Data("<html>\(mediaElements)</html>".utf8).write(to: entrypoint)
        for name in mediaNames {
            try Data("fixture-\(name)".utf8).write(to: project.appending(path: name))
        }
        return (
            root,
            project,
            entrypoint,
            root.appending(path: "cache", directoryHint: .isDirectory)
        )
    }
}

private final class StartupPruneProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let releaseGate = DispatchSemaphore(value: 0)
    private let blocksUntilReleased: Bool
    private var calls = 0
    private var hasReleased = false

    init(blocksUntilReleased: Bool = false) {
        self.blocksUntilReleased = blocksUntilReleased
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    func record() {
        lock.withLock { calls += 1 }
        entered.signal()
        if blocksUntilReleased { releaseGate.wait() }
    }

    func waitUntilEntered() -> Bool {
        entered.wait(timeout: .now() + 2) == .success
    }

    func release() {
        let shouldSignal = lock.withLock {
            guard !hasReleased else { return false }
            hasReleased = true
            return true
        }
        if shouldSignal { releaseGate.signal() }
    }
}

private actor PreparationRecorder {
    private(set) var callCount = 0
    private(set) var cacheDirectories = [URL]()

    func prepare(source: URL, cache: URL) -> PreparedWebMedia {
        callCount += 1
        cacheDirectories.append(cache)
        return Self.result(source: source, cache: cache)
    }

    static func result(source: URL, cache: URL) -> PreparedWebMedia {
        let kind: PreparedWebMediaKind = source.pathExtension.lowercased() == "ogg"
            ? .audio
            : .video
        let output = cache.appending(
            path: source.deletingPathExtension().lastPathComponent
                + (kind == .audio ? ".m4a" : ".mp4")
        )
        let hash = String(repeating: kind == .audio ? "a" : "b", count: 64)
        return PreparedWebMedia(
            kind: kind,
            url: output,
            sourceContentHash: hash,
            cacheKey: WebMediaCacheKey(sourceContentHash: hash, kind: kind),
            probeReport: MediaProbeReport(streams: [], format: nil),
            reusedCachedOutput: false
        )
    }
}

private actor PreparationGate {
    private(set) var callCount = 0
    private(set) var wasCancelled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func prepare(source: URL, cache: URL) async throws -> PreparedWebMedia {
        callCount += 1
        do {
            await withCheckedContinuation { continuation = $0 }
            try Task.checkCancellation()
            return PreparationRecorder.result(source: source, cache: cache)
        } catch {
            if error is CancellationError { wasCancelled = true }
            throw error
        }
    }

    func waitUntilStarted() async throws {
        for _ in 0..<500 {
            if callCount > 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.executableLoad)
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ConcurrencyGate {
    private var calls = 0
    private var active = 0
    private var maximumActive = 0
    private var continuations = [CheckedContinuation<Void, Never>]()

    var metrics: (calls: Int, active: Int, maximumActive: Int) {
        (calls, active, maximumActive)
    }

    func prepare(source: URL, cache: URL) async throws -> PreparedWebMedia {
        calls += 1
        active += 1
        maximumActive = max(maximumActive, active)
        await withCheckedContinuation { continuations.append($0) }
        active -= 1
        try Task.checkCancellation()
        return PreparationRecorder.result(source: source, cache: cache)
    }

    func waitForCallCount(_ expected: Int) async throws {
        for _ in 0..<500 {
            if calls >= expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.executableLoad)
    }

    func releaseOne() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func releaseAll() {
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}

private actor CancellationProbe {
    private(set) var wasCancelled = false
    private var started = false

    func prepare(source: URL, cache: URL) async throws -> PreparedWebMedia {
        started = true
        do {
            try await Task.sleep(for: .seconds(30))
            return PreparationRecorder.result(source: source, cache: cache)
        } catch {
            if error is CancellationError { wasCancelled = true }
            throw error
        }
    }

    func waitUntilStarted() async throws {
        for _ in 0..<500 {
            if started { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.executableLoad)
    }

    func waitUntilCancelled() async throws {
        for _ in 0..<500 {
            if wasCancelled { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.executableLoad)
    }
}

private actor PartialDeadlineProbe {
    private(set) var stalledWasCancelled = false

    func prepare(source: URL, cache: URL) async throws -> PreparedWebMedia {
        if source.lastPathComponent == "fast.ogv" {
            return PreparationRecorder.result(source: source, cache: cache)
        }
        do {
            try await Task.sleep(for: .seconds(30))
            return PreparationRecorder.result(source: source, cache: cache)
        } catch {
            if error is CancellationError { stalledWasCancelled = true }
            throw error
        }
    }

    func waitUntilStalledJobCancelled() async throws {
        for _ in 0..<500 {
            if stalledWasCancelled { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.executableLoad)
    }
}

private actor DeadlineReapingGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func prepare(source: URL, cache: URL) async -> PreparedWebMedia {
        await withCheckedContinuation { continuation = $0 }
        return PreparationRecorder.result(source: source, cache: cache)
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor QueuedPreparationGate {
    private(set) var callCount = 0
    private var firstContinuation: CheckedContinuation<Void, Never>?

    func prepare(source: URL, cache: URL) async throws -> PreparedWebMedia {
        callCount += 1
        if callCount == 1 {
            await withCheckedContinuation { firstContinuation = $0 }
        }
        try Task.checkCancellation()
        return PreparationRecorder.result(source: source, cache: cache)
    }

    func waitForCallCount(_ expected: Int) async throws {
        for _ in 0..<500 {
            if callCount >= expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.executableLoad)
    }

    func releaseFirst() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}

private actor ABAJobGate {
    private var calls = 0
    private var continuations = [Int: CheckedContinuation<Void, Never>]()

    func prepare(source: URL, cache: URL) async -> PreparedWebMedia {
        calls += 1
        let generation = calls
        await withCheckedContinuation { continuations[generation] = $0 }
        let hashCharacter = generation == 1 ? "1" : "2"
        let hash = String(repeating: hashCharacter, count: 64)
        return PreparedWebMedia(
            kind: .video,
            url: cache.appending(path: "generation-\(generation).mp4"),
            sourceContentHash: hash,
            cacheKey: WebMediaCacheKey(sourceContentHash: hash, kind: .video),
            probeReport: MediaProbeReport(streams: [], format: nil),
            reusedCachedOutput: false
        )
    }

    func waitForCallCount(_ expected: Int) async throws {
        for _ in 0..<500 {
            if calls >= expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.executableLoad)
    }

    func release(call: Int) {
        continuations.removeValue(forKey: call)?.resume()
    }
}

private actor JobCompletionCounter {
    private var count = 0

    func recordCompletion() {
        count += 1
    }

    func waitForCount(_ expected: Int) async throws {
        for _ in 0..<500 {
            if count >= expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.executableLoad)
    }
}

private actor AsyncCompletionProbe {
    private(set) var isCompleted = false

    func recordSuccess() {
        isCompleted = true
    }

    func recordFailure() {
        isCompleted = true
    }
}

private actor ClearRetryPreparationGate {
    private(set) var callCount = 0
    private(set) var firstWasCancelled = false

    func prepare(source: URL, cache: URL) async throws -> PreparedWebMedia {
        callCount += 1
        if callCount == 1 {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                if error is CancellationError { firstWasCancelled = true }
                throw error
            }
        }
        return PreparationRecorder.result(source: source, cache: cache)
    }

    func waitForCallCount(_ expected: Int) async throws {
        for _ in 0..<500 {
            if callCount >= expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.executableLoad)
    }
}

private actor CacheMaintenanceGate {
    private var paused = false
    private var continuation: CheckedContinuation<Void, Never>?

    func pause() async {
        paused = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilPaused() async throws {
        for _ in 0..<500 {
            if paused { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.executableLoad)
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor CacheOperationProbe {
    private(set) var entered = false

    func recordEntry() {
        entered = true
    }

    func waitUntilEntered() async throws {
        for _ in 0..<500 {
            if entered { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.executableLoad)
    }
}

private actor HandoffAggregationGate {
    private var isPaused = false
    private var mayResume = false
    private var pausedWaiters = [CheckedContinuation<Void, Never>]()
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func pauseBeforeAggregation() async {
        isPaused = true
        let waiters = pausedWaiters
        pausedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !mayResume else { return }
        await withCheckedContinuation { resumeContinuation = $0 }
    }

    func waitUntilPaused() async {
        guard !isPaused else { return }
        await withCheckedContinuation { pausedWaiters.append($0) }
    }

    func resumeAggregation() {
        mayResume = true
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private actor AsyncTestSignal {
    private var isSignalled = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    func signal() {
        isSignalled = true
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters { waiter.resume() }
    }

    func wait() async {
        guard !isSignalled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor WaiterRegistrationGate {
    private var isPaused = false
    private var mayResume = false
    private var pausedWaiters = [CheckedContinuation<Void, Never>]()
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func pauseBeforeRegistration() async {
        isPaused = true
        let waiters = pausedWaiters
        pausedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !mayResume else { return }
        await withCheckedContinuation { resumeContinuation = $0 }
    }

    func waitUntilPaused() async {
        guard !isPaused else { return }
        await withCheckedContinuation { pausedWaiters.append($0) }
    }

    func resumeRegistration() {
        mayResume = true
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private final class LifecycleScopeRegistrationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var registeredScopes = Set<PlaybackLifecycleScope>()
    private var waiters = [
        PlaybackLifecycleScope: [CheckedContinuation<Void, Never>]
    ]()

    func record(_ scope: PlaybackLifecycleScope) {
        lock.lock()
        registeredScopes.insert(scope)
        let continuations = waiters.removeValue(forKey: scope) ?? []
        lock.unlock()
        for continuation in continuations { continuation.resume() }
    }

    func hasRegistered(_ scope: PlaybackLifecycleScope) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return registeredScopes.contains(scope)
    }

    func waitForRegistration(of scope: PlaybackLifecycleScope) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if registeredScopes.contains(scope) {
                lock.unlock()
                continuation.resume()
            } else {
                waiters[scope, default: []].append(continuation)
                lock.unlock()
            }
        }
    }
}

private actor AsyncPlaybackProbeCancellationGate {
    private var isStarted = false
    private(set) var wasCancelled = false
    private var startedWaiters = [CheckedContinuation<Void, Never>]()
    private var cancelledWaiters = [CheckedContinuation<Void, Never>]()

    func inspectUntilCancelled() async -> Bool {
        isStarted = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        do {
            try await Task.sleep(for: .seconds(60))
            return true
        } catch is CancellationError {
            wasCancelled = true
            let waiters = cancelledWaiters
            cancelledWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            return false
        } catch {
            return false
        }
    }

    func waitUntilStarted() async {
        guard !isStarted else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func waitUntilCancelled() async {
        guard !wasCancelled else { return }
        await withCheckedContinuation { cancelledWaiters.append($0) }
    }
}

private actor UncooperativeAsyncPlaybackProbeGate {
    private var isStarted = false
    private var startedWaiters = [CheckedContinuation<Void, Never>]()
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func inspectIgnoringCancellation() async -> Bool {
        isStarted = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
        return true
    }

    func waitUntilStarted() async {
        guard !isStarted else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class PlaybackProbeInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var synchronousCalls = 0
    private var asynchronousCalls = 0

    var synchronousCallCount: Int {
        lock.withLock { synchronousCalls }
    }

    var asynchronousCallCount: Int {
        lock.withLock { asynchronousCalls }
    }

    func recordSynchronousCall() {
        lock.withLock { synchronousCalls += 1 }
    }

    func recordAsynchronousCall() {
        lock.withLock { asynchronousCalls += 1 }
    }
}
