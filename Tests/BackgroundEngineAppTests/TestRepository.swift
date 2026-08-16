import Foundation

private let testRepositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

func testRepositoryPath(_ relativePath: String) -> String {
    testRepositoryRoot.appending(path: relativePath).path
}

extension String {
    init(repositoryFile relativePath: String) throws {
        try self.init(contentsOf: testRepositoryRoot.appending(path: relativePath), encoding: .utf8)
    }
}
