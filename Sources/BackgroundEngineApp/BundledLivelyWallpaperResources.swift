import Foundation

enum BundledLivelyWallpaperResources {
    static func rootURL() -> URL? {
#if SWIFT_PACKAGE
        Bundle.module.url(forResource: "LivelyWallpapers", withExtension: nil)
#else
        guard let resources = Bundle.main.resourceURL else { return nil }
        let candidate = resources.appending(path: "LivelyWallpapers", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
#endif
    }
}
