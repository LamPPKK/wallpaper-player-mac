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

    func testOwnerFilteredLookupCannotSelectAnotherConnectionsOperation() {
        let slot = SteamCMDOperationSlot<OwnedOperationFixture>()
        let owner = UUID()
        let operation = OwnedOperationFixture(ownerID: owner)
        XCTAssertTrue(slot.register(operation))

        XCTAssertNil(slot.current(where: { $0.ownerID == UUID() }))
        XCTAssertTrue(slot.current(where: { $0.ownerID == owner }) === operation)
    }

    func testConnectionCloseCancelsOnlyItsOwnedOperation() async {
        let service = SteamCMDRunnerService()
        let owner = UUID()
        let otherOwner = UUID()
        let operation = SteamCMDServiceOperation(ownerID: owner)
        let cancellationObserved = expectation(description: "owned task cancelled")
        let task = Task<Void, Never> {
            await withTaskCancellationHandler {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            } onCancel: {
                cancellationObserved.fulfill()
            }
        }
        defer { task.cancel() }
        operation.install(task)
        XCTAssertTrue(service.register(operation))

        service.connectionDidClose(ownerID: otherOwner)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(task.isCancelled)

        service.connectionDidClose(ownerID: owner)
        await fulfillment(of: [cancellationObserved], timeout: 1)
        XCTAssertTrue(task.isCancelled)
    }

    func testLateOwnerCancellationCannotCancelReplacementOperation() async {
        let slot = SteamCMDOperationSlot<SteamCMDServiceOperation>()
        let first = SteamCMDServiceOperation(ownerID: UUID())
        let replacement = SteamCMDServiceOperation(ownerID: UUID())
        let firstCancellationObserved = expectation(description: "first task cancelled")
        let firstTask = Task<Void, Never> {
            await withTaskCancellationHandler {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            } onCancel: {
                firstCancellationObserved.fulfill()
            }
        }
        let replacementTask = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        defer {
            firstTask.cancel()
            replacementTask.cancel()
        }
        first.install(firstTask)
        replacement.install(replacementTask)
        XCTAssertTrue(slot.register(first))

        // Model the widest possible race window in `connectionDidClose`: the
        // first owner was selected, then it finished and another owner began
        // before cancellation was delivered to the selected object.
        let selected = slot.current(where: { $0.ownerID == first.ownerID })
        XCTAssertTrue(slot.clear(first))
        XCTAssertTrue(slot.register(replacement))
        selected?.cancel()

        await fulfillment(of: [firstCancellationObserved], timeout: 1)
        XCTAssertTrue(firstTask.isCancelled)
        XCTAssertFalse(replacementTask.isCancelled)
        XCTAssertTrue(slot.current() === replacement)
    }

    func testExplicitCancelWaitsForTheSelectedOperationToFinish() async {
        let service = SteamCMDRunnerService()
        let operation = SteamCMDServiceOperation(ownerID: UUID())
        let cancellationObserved = expectation(description: "selected task cancelled")
        let cancelReplied = expectation(description: "cancel replied after selected operation finished")
        let didReply = LockedBooleanFixture()
        let task = Task<Void, Never> {
            await withTaskCancellationHandler {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            } onCancel: {
                cancellationObserved.fulfill()
            }
        }
        defer { task.cancel() }
        operation.install(task)
        XCTAssertTrue(service.register(operation))

        service.cancel { payload in
            XCTAssertEqual(payload["ok"] as? Bool, true)
            didReply.setTrue()
            cancelReplied.fulfill()
        }
        await fulfillment(of: [cancellationObserved], timeout: 1)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(
            didReply.value,
            "Cancel must not reply while the selected operation still owns cleanup."
        )

        operation.finish()
        await fulfillment(of: [cancelReplied], timeout: 1)
    }
}

private final class OperationFixture: @unchecked Sendable {}

private final class OwnedOperationFixture: @unchecked Sendable {
    let ownerID: UUID

    init(ownerID: UUID) {
        self.ownerID = ownerID
    }
}

private final class LockedBooleanFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.withLock { storage }
    }

    func setTrue() {
        lock.withLock { storage = true }
    }
}
