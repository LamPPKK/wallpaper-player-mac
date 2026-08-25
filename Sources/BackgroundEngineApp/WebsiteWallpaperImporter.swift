import BackgroundEngineCore
import Foundation

enum WebsiteWallpaperImportError: LocalizedError, Equatable {
    case invalidURL
    case generatedProjectMissing

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Enter a valid HTTPS website URL without embedded credentials."
        case .generatedProjectMissing:
            "Background Engine could not create the website wallpaper project."
        }
    }
}

/// Creates a small local project that records the opted-in HTTPS origin.
/// The website itself is loaded by `RestrictedWebWallpaperView`; it is never
/// copied, mirrored, or granted native-command access.
actor WebsiteWallpaperImporter {
    private let store: LibraryStore

    init(store: LibraryStore) {
        self.store = store
    }

    func importWebsite(_ input: String) async throws -> WallpaperAsset {
        let normalizedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let targetURL = URL(string: normalizedInput) else {
            throw WebsiteWallpaperImportError.invalidURL
        }
        let configuration: RemoteWebWallpaperConfiguration
        do {
            configuration = try RemoteWebWallpaperConfiguration(targetURL: targetURL)
        } catch {
            throw WebsiteWallpaperImportError.invalidURL
        }
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "background-engine-website-\(UUID().uuidString)")
        let project = temporaryRoot.appending(path: "website-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try writeGeneratedProject(configuration: configuration, to: project)

        let importer = WallpaperImporter(store: store)
        let scan = try await importer.scan(root: project)
        guard let generated = scan.assets.first else {
            throw WebsiteWallpaperImportError.generatedProjectMissing
        }
        let imported = try await importer.importAsset(generated)
        let allowed = imported.allowingNetworkAccess(true)
        try store.replaceAsset(allowed)
        return allowed
    }

    private func writeGeneratedProject(
        configuration: RemoteWebWallpaperConfiguration,
        to project: URL
    ) throws {
        let title = configuration.targetURL.host ?? "Website"
        let projectJSON: [String: Any] = [
            "title": title,
            "type": "web",
            "file": "index.html"
        ]
        let metadata = try JSONSerialization.data(
            withJSONObject: projectJSON,
            options: [.prettyPrinted, .sortedKeys]
        )
        try metadata.write(to: project.appending(path: "project.json"), options: [.atomic])
        try JSONEncoder().encode(configuration).write(
            to: project.appending(path: RemoteWebWallpaperConfiguration.fileName),
            options: [.atomic]
        )
        let placeholder = """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><title>Website Wallpaper</title></head>
        <body><p>This website wallpaper is opened securely by Background Engine.</p></body></html>
        """
        try Data(placeholder.utf8).write(to: project.appending(path: "index.html"), options: [.atomic])
    }
}
