import Foundation
import XCTest
@testable import BackgroundEngineCore

final class WebMediaDiskReservationTests: XCTestCase {
    func testAvailableCapacityFallsBackWhenImportantUsageReportsZero() {
        XCTAssertEqual(
            WebMediaDiskReservationManager.usableAvailableBytes(
                importantUsage: 0,
                basic: 47 * 1_024 * 1_024 * 1_024
            ),
            47 * 1_024 * 1_024 * 1_024
        )
        XCTAssertEqual(
            WebMediaDiskReservationManager.usableAvailableBytes(
                importantUsage: 64,
                basic: 128
            ),
            64
        )
        XCTAssertEqual(
            WebMediaDiskReservationManager.usableAvailableBytes(
                importantUsage: 0,
                basic: nil
            ),
            0
        )
        XCTAssertNil(
            WebMediaDiskReservationManager.usableAvailableBytes(
                importantUsage: -1,
                basic: -1
            )
        )
    }

    func testReservationAccountsForConcurrentUnwrittenOutputs() async throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = WebMediaDiskReservationManager()
        let available = try WebMediaDiskReservationManager.availableBytes(at: root)
        guard available > WebMediaDiskReservationManager.safetyReserveBytes + 4 else {
            do {
                _ = try manager.acquire(directory: root, bytes: 1)
                XCTFail("Expected a full test volume to preserve the safety reserve")
            } catch let error as WebMediaPreparationError {
                guard case .insufficientDiskSpace = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            return
        }
        let firstBytes = available - WebMediaDiskReservationManager.safetyReserveBytes - 1
        let first = try manager.acquire(directory: root, bytes: firstBytes)
        let reservedAfterFirst = manager.reservedBytesForTesting()
        XCTAssertEqual(reservedAfterFirst, firstBytes)

        do {
            _ = try manager.acquire(directory: root, bytes: 2)
            XCTFail("Expected the second concurrent reservation to exceed available capacity")
        } catch let error as WebMediaPreparationError {
            guard case .insufficientDiskSpace = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let reservedAfterRejection = manager.reservedBytesForTesting()
        XCTAssertEqual(reservedAfterRejection, firstBytes)

        manager.release(first)
        let reservedAfterRelease = manager.reservedBytesForTesting()
        XCTAssertEqual(reservedAfterRelease, 0)
    }

    func testReservationCanResizeAndReleaseWithoutLeakingAccounting() async throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = WebMediaDiskReservationManager()

        let token = try manager.acquire(directory: root, bytes: 1)
        try manager.resize(token: token, directory: root, bytes: 2)
        let reservedAfterResize = manager.reservedBytesForTesting()
        XCTAssertEqual(reservedAfterResize, 2)
        manager.release(token)
        let reservedAfterRelease = manager.reservedBytesForTesting()
        XCTAssertEqual(reservedAfterRelease, 0)
    }

    func testSourceSizeEstimateRejectsSymlinkAndOversizedFile() throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.webm")
        try Data(repeating: 1, count: 8).write(to: source)
        XCTAssertEqual(
            try WebMediaDiskReservationManager.regularFileByteCount(
                at: source,
                maximumBytes: 8
            ),
            8
        )
        XCTAssertThrowsError(
            try WebMediaDiskReservationManager.regularFileByteCount(
                at: source,
                maximumBytes: 7
            )
        )

        let symlink = root.appending(path: "linked.webm")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        XCTAssertThrowsError(
            try WebMediaDiskReservationManager.regularFileByteCount(
                at: symlink,
                maximumBytes: 8
            )
        )
    }
}
