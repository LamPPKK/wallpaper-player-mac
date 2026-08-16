import Foundation

/// Looks up the v1 English-only UI chrome from the bundled string table.
@MainActor
enum Localization {
    private static var englishBundle: Bundle?

    static func string(_ key: String) -> String {
        bundle().localizedString(forKey: key, value: key, table: nil)
    }

    private static func bundle() -> Bundle {
        if let cached = englishBundle {
            return cached
        }
        #if SWIFT_PACKAGE
        let resourceBundle = Bundle.module
        #else
        let resourceBundle = Bundle.main
        #endif
        let resolved: Bundle
        if let path = resourceBundle.path(forResource: "en", ofType: "lproj"),
           let languageBundle = Bundle(path: path) {
            resolved = languageBundle
        } else {
            resolved = resourceBundle
        }
        englishBundle = resolved
        return resolved
    }
}
