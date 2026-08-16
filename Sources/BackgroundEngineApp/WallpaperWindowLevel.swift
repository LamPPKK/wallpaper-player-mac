import AppKit

enum WallpaperWindowLevel {
    static var desktopWallpaper: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
    }
}
