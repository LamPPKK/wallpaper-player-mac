import Foundation

enum SettingsWindowPlacement {
    private static let minimumReachableTitleBarWidth: CGFloat = 160
    private static let minimumReachableTitleBarHeight: CGFloat = 22
    private static let titleBarHeight: CGFloat = 28

    static func centeredFrame(
        windowSize: CGSize,
        minimumWindowSize: CGSize = .zero,
        screenFrame: CGRect
    ) -> CGRect {
        let targetWidth = max(windowSize.width, minimumWindowSize.width)
        let targetHeight = max(windowSize.height, minimumWindowSize.height)
        let width = min(targetWidth, screenFrame.width)
        let height = min(targetHeight, screenFrame.height)
        let originX = screenFrame.minX + ((screenFrame.width - width) / 2)
        let originY = screenFrame.minY + ((screenFrame.height - height) / 2)
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    static func preferredScreenFrame(mouseLocation: CGPoint, screenFrames: [CGRect], fallback: CGRect) -> CGRect {
        screenFrames.first { $0.contains(mouseLocation) } ?? fallback
    }

    /// Returns a centered replacement only when the window's title bar can no
    /// longer be reached on any connected display. macOS can restore a SwiftUI
    /// window at the coordinates of a display that has since been unplugged.
    static func recoveredFrame(
        windowFrame: CGRect,
        screenFrames: [CGRect],
        fallback: CGRect
    ) -> CGRect? {
        guard !hasReachableTitleBar(windowFrame: windowFrame, screenFrames: screenFrames) else {
            return nil
        }
        return centeredFrame(windowSize: windowFrame.size, screenFrame: fallback)
    }

    static func hasReachableTitleBar(windowFrame: CGRect, screenFrames: [CGRect]) -> Bool {
        guard !windowFrame.isEmpty else { return false }
        let height = min(titleBarHeight, windowFrame.height)
        let titleBar = CGRect(
            x: windowFrame.minX,
            y: windowFrame.maxY - height,
            width: windowFrame.width,
            height: height
        )
        let requiredWidth = min(minimumReachableTitleBarWidth, titleBar.width)
        let requiredHeight = min(minimumReachableTitleBarHeight, titleBar.height)
        return screenFrames.contains { screenFrame in
            let visibleTitleBar = titleBar.intersection(screenFrame)
            return !visibleTitleBar.isNull
                && visibleTitleBar.width >= requiredWidth
                && visibleTitleBar.height >= requiredHeight
        }
    }
}
