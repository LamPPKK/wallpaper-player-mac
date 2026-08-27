import XCTest
@testable import SteamCMDRunnerService

final class SteamCMDOperationSlotTests: XCTestCase {
    func testClearsBeforeReentrantReplyRegistersNextOperation() {
        let slot = SteamCMDOperationSlot<OperationFixture>()
        let first = OperationFixture()
        let second = OperationFixture()
        XCTAssertTrue(slot.register(first))

        var registeredFromReply = false
        slot.finish(first) {
            registeredFromReply = slot.register(second)
        }

        XCTAssertTrue(registeredFromReply)
        XCTAssertTrue(slot.current() === second)
    }

    func testStaleCleanupCannotReleaseNewerOperation() {
        let slot = SteamCMDOperationSlot<OperationFixture>()
        let first = OperationFixture()
        let second = OperationFixture()
        let third = OperationFixture()
        XCTAssertTrue(slot.register(first))
        slot.finish(first) {
            XCTAssertTrue(slot.register(second))
        }

        XCTAssertFalse(slot.clear(first))
        XCTAssertTrue(slot.current() === second)
        XCTAssertFalse(slot.register(third))
    }
}

private final class OperationFixture: @unchecked Sendable {}
