import Foundation

struct SecurityScopedBookmarkStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(_ url: URL, key: String) throws {
        let data: Data
        do {
            data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: [.isDirectoryKey],
                relativeTo: nil
            )
            defaults.set(true, forKey: "\(key).securityScoped")
        } catch {
            // SwiftPM/unit-test processes are not signed with an App Sandbox
            // entitlement. A minimal bookmark keeps the same persistence
            // semantics there; release builds use the security-scoped path.
            data = try url.bookmarkData(
                options: [.minimalBookmark],
                includingResourceValuesForKeys: [.isDirectoryKey],
                relativeTo: nil
            )
            defaults.set(false, forKey: "\(key).securityScoped")
        }
        defaults.set(data, forKey: key)
    }

    func resolve(key: String) throws -> URL? {
        guard let data = defaults.data(forKey: key) else { return nil }
        var stale = false
        let options: URL.BookmarkResolutionOptions = defaults.bool(forKey: "\(key).securityScoped")
            ? [.withSecurityScope]
            : [.withoutUI]
        let url = try URL(
            resolvingBookmarkData: data,
            options: options,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        if stale { try save(url, key: key) }
        return url.standardizedFileURL
    }

    func remove(key: String) {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: "\(key).securityScoped")
    }
}
