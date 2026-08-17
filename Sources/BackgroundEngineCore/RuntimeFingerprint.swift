import CryptoKit
import Foundation

public enum RuntimeFingerprint {
    /// Fingerprints only the engine files that define renderer behavior. It
    /// rejects symlinks and path escapes so a cache key never reads outside
    /// the assets folder selected by the user.
    public static func engineAssets(
        at root: URL,
        requiredPaths: [String]
    ) -> String? {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var digest = SHA256()
        var foundFile = false
        for relativePath in requiredPaths.sorted() {
            let candidate = root.appending(path: relativePath).standardizedFileURL
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)) == nil else {
                return nil
            }
            let canonical = candidate.resolvingSymlinksInPath()
            guard isInside(canonical, root: canonicalRoot),
                  let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            foundFile = true
            digest.update(data: Data(relativePath.utf8))
            digest.update(data: Data(String(values.fileSize ?? 0).utf8))
            do {
                let handle = try FileHandle(forReadingFrom: candidate)
                defer { try? handle.close() }
                while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                    digest.update(data: data)
                }
            } catch {
                return nil
            }
        }
        guard foundFile else { return nil }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isInside(_ candidate: URL, root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count > rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }
}
