import Foundation
import XCTest
@testable import BackgroundEngineCore

final class SteamCMDXPCPayloadTests: XCTestCase {
    func testVoidSuccessPayloadIsAccepted() throws {
        XCTAssertNoThrow(
            try SteamCMDXPCPayload.validateSuccess(from: SteamCMDXPCPayload.success())
        )
    }

    func testVoidFailurePayloadPreservesRemoteInstallError() throws {
        let payload = SteamCMDXPCPayload.failure(FixtureError.installFailed)

        XCTAssertThrowsError(try SteamCMDXPCPayload.validateSuccess(from: payload)) { error in
            guard case SteamCMDXPCClientError.remoteFailure(let message) = error else {
                return XCTFail("Expected remoteFailure, got \(error)")
            }
            XCTAssertEqual(message, FixtureError.installFailed.localizedDescription)
        }
    }

    func testMalformedVoidPayloadIsRejected() throws {
        for payload: NSDictionary in [
            [:],
            ["ok": "true"],
            ["ok": false],
            ["ok": false, "error": "   "],
        ] {
            XCTAssertThrowsError(try SteamCMDXPCPayload.validateSuccess(from: payload)) { error in
                guard case SteamCMDXPCClientError.invalidResponse = error else {
                    return XCTFail("Expected invalidResponse, got \(error)")
                }
            }
        }
    }

    func testTypedDecodeUsesTheSameStrictEnvelopeValidation() throws {
        XCTAssertThrowsError(
            try SteamCMDXPCPayload.decode(String.self, from: ["ok": false])
        ) { error in
            guard case SteamCMDXPCClientError.invalidResponse = error else {
                return XCTFail("Expected invalidResponse, got \(error)")
            }
        }
    }
}

private enum FixtureError: LocalizedError {
    case installFailed

    var errorDescription: String? { "SteamCMD install fixture failed." }
}
