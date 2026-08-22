import Foundation

public struct LegacyMigrationCandidate: Identifiable, Equatable, Sendable {
    public let asset: WallpaperAsset
    public let sourceApplication: String

    public var id: WallpaperAsset.ID { asset.id }

    public init(asset: WallpaperAsset, sourceApplication: String) {
        self.asset = asset
        self.sourceApplication = sourceApplication
    }
}

/// Previews and copies compatible wallpapers from prior macOS wallpaper
/// player libraries. Source folders are read-only and are never removed.
public actor LegacyLibraryMigrator {
    private let roots: [(name: String, url: URL)]
    private let importer: WallpaperImporter

    public init(destination: LibraryStore, roots: [(String, URL)]? = nil) {
        importer = WallpaperImporter(store: destination)
        if let roots {
            self.roots = roots.map { (name: $0.0, url: $0.1) }
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.roots = [
                ("Open Wallpaper Engine", support.appending(path: "Open Wallpaper Engine")),
                ("Workshop Wallpaper Bridge", support.appending(path: "WorkshopWallpaperBridge"))
            ]
        }
    }

    init(importer: WallpaperImporter, roots: [(String, URL)] = []) {
        self.importer = importer
        self.roots = roots.map { (name: $0.0, url: $0.1) }
    }

    public func preview() async -> [LegacyMigrationCandidate] {
        var candidates: [LegacyMigrationCandidate] = []
        for root in roots where FileManager.default.fileExists(atPath: root.url.path) {
            if let manifest = loadManifest(at: root.url.appending(path: "library.json")) {
                candidates.append(contentsOf: manifest.assets.map {
                    LegacyMigrationCandidate(asset: $0.replacing(source: .legacyMigration), sourceApplication: root.name)
                })
                continue
            }
            let assetsRoot = root.url.appending(path: "Assets")
            if let result = try? await importer.scan(root: assetsRoot) {
                candidates.append(contentsOf: result.assets.map {
                    LegacyMigrationCandidate(asset: $0.replacing(source: .legacyMigration), sourceApplication: root.name)
                })
            }
        }
        var seen = Set<String>()
        return candidates.filter { candidate in
            let key = candidate.asset.workshopId ?? candidate.asset.projectDirectory
            return seen.insert(key).inserted
        }
    }

    public func migrate(_ candidates: [LegacyMigrationCandidate]) async throws -> [WallpaperAsset] {
        var imported: [WallpaperAsset] = []
        for candidate in candidates {
            try Task.checkCancellation()
            imported.append(
                try await importer.importAndPrepareAsset(candidate.asset.replacing(source: .legacyMigration))
            )
            try Task.checkCancellation()
        }
        return imported
    }

    private func loadManifest(at url: URL) -> LibraryManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LibraryManifest.self, from: data)
    }
}
