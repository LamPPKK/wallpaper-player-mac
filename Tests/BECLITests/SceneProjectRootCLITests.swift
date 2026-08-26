import Foundation
import XCTest
@testable import becli
import BackgroundEngineCore

final class SceneProjectRootCLITests: XCTestCase {
    func testSceneInfoCommandsInferNestedProjectRootForAudioProcessing() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "be-cli-scene-root-\(UUID().uuidString)")
        let content = root.appending(path: "content", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let packageURL = content.appending(path: "scene.pkg")
        try Self.scenePackageData(sceneJSON: #"{"objects":[]}"#)
            .write(to: packageURL, options: [.atomic])
        try #"{"title":"Nested","type":"scene","file":"content/scene.pkg","general":{"supportsaudioprocessing":true}}"#
            .write(
                to: root.appending(path: "project.json"),
                atomically: true,
                encoding: .utf8
            )

        let sceneInfo = try JSONDecoder().decode(
            ScenePackageAnalysis.self,
            from: WWBCtl.sceneInfoData(arguments: [packageURL.path])
        )
        let engineInfo = try JSONDecoder().decode(
            SceneRuntimeFeatures.self,
            from: WWBCtl.sceneEngineInfoData(arguments: [packageURL.path])
        )

        XCTAssertTrue(sceneInfo.runtimeFeatures.requiresAudioAnalysis)
        XCTAssertTrue(engineInfo.requiresAudioAnalysis)
        XCTAssertFalse(sceneInfo.runtimeFeatures.hasAudioDependencyUncertainty)
        XCTAssertFalse(engineInfo.hasAudioDependencyUncertainty)
    }

    private static func scenePackageData(sceneJSON: String) -> Data {
        let sceneData = Data(sceneJSON.utf8)
        var result = Data()
        result.appendLengthPrefixedString("PKGV0007")
        result.appendInt32(1)
        result.appendLengthPrefixedString("scene.json")
        result.appendInt32(0)
        result.appendInt32(sceneData.count)
        result.append(sceneData)
        return result
    }
}

private extension Data {
    mutating func appendInt32(_ value: Int) {
        var raw = Int32(value).littleEndian
        Swift.withUnsafeBytes(of: &raw) { append(contentsOf: $0) }
    }

    mutating func appendLengthPrefixedString(_ string: String) {
        let bytes = Data(string.utf8)
        appendInt32(bytes.count)
        append(bytes)
    }
}
