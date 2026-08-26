import AppKit
import CoreGraphics

struct DesktopVisibilityMonitor {
    /// Returns one visibility result per `NSScreen`, preserving screen order.
    /// CGWindow bounds use the WindowServer coordinate space, while
    /// `NSScreen.frame` uses AppKit's coordinate space; `CGDisplayBounds`
    /// keeps coverage checks correct for displays above/below the primary.
    func desktopVisibility(for screens: [NSScreen]) -> [Bool] {
        Self.desktopVisibility(
            windows: windowSnapshots(),
            currentProcessId: Int(ProcessInfo.processInfo.processIdentifier),
            screenFrames: screens.map(Self.windowServerFrame)
        )
    }

    static func isDesktopVisible(
        windows: [WindowSnapshot],
        currentProcessId: Int,
        screenFrames: [CGRect] = []
    ) -> Bool {
        guard !screenFrames.isEmpty else {
            // Retain the conservative fallback used when display geometry is
            // omitted by pure callers. Product playback uses the per-display
            // optional geometry overload below and fails open for unknown IDs.
            return !windows.contains {
                isBlockingWindow($0, currentProcessId: currentProcessId, screenFrames: screenFrames)
            }
        }
        return desktopVisibility(
            windows: windows,
            currentProcessId: currentProcessId,
            screenFrames: screenFrames
        ).allSatisfy { $0 }
    }

    /// A desktop is considered covered only when ordinary application
    /// windows collectively cover essentially the complete display. A small
    /// or centered window must not pause that display, and coverage on one
    /// display must not affect another display's wallpaper session.
    static func desktopVisibility(
        windows: [WindowSnapshot],
        currentProcessId: Int,
        screenFrames: [CGRect]
    ) -> [Bool] {
        desktopVisibility(
            windows: windows,
            currentProcessId: currentProcessId,
            screenFrames: screenFrames.map(Optional.some)
        )
    }

    /// Missing display identifiers cannot safely fall back to `NSScreen.frame`:
    /// AppKit and WindowServer use different vertical coordinate conventions.
    /// Such displays therefore fail open while displays with known geometry
    /// continue to be evaluated independently.
    static func desktopVisibility(
        windows: [WindowSnapshot],
        currentProcessId: Int,
        screenFrames: [CGRect?]
    ) -> [Bool] {
        let knownScreenFrames = screenFrames.compactMap { $0 }
        let blockingWindows = windows.filter {
            isBlockingWindow(
                $0,
                currentProcessId: currentProcessId,
                screenFrames: knownScreenFrames
            )
        }
        return screenFrames.map { optionalScreenFrame in
            guard let screenFrame = optionalScreenFrame else {
                return true
            }
            guard screenFrame.width > 0, screenFrame.height > 0 else {
                return true
            }
            let intersections = blockingWindows.compactMap { window -> CGRect? in
                let intersection = window.bounds.intersection(screenFrame)
                guard !intersection.isNull, !intersection.isEmpty else { return nil }
                return intersection
            }
            let screenArea = screenFrame.area
            guard screenArea > 0 else { return true }
            let coveredFraction = coveredArea(of: intersections) / screenArea
            return coveredFraction < minimumCoveredFraction
        }
    }

    private func windowSnapshots() -> [WindowSnapshot] {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return windows.map(WindowSnapshot.init)
    }

    private static func windowServerFrame(_ screen: NSScreen) -> CGRect? {
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else {
            return nil
        }
        let bounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        guard bounds.width > 0, bounds.height > 0 else {
            return nil
        }
        return bounds
    }

    /// Exact rectangle-union area using vertical strips. Window counts are
    /// small and this runs only once per second, while avoiding double-counted
    /// overlap that could otherwise pause a partially visible desktop.
    private static func coveredArea(of rectangles: [CGRect]) -> Double {
        let rectangles = rectangles.filter {
            !$0.isNull && !$0.isEmpty && $0.width.isFinite && $0.height.isFinite
        }
        guard !rectangles.isEmpty else { return 0 }
        let xCoordinates = Array(Set(rectangles.flatMap { [$0.minX, $0.maxX] })).sorted()
        guard xCoordinates.count > 1 else { return 0 }

        var area = 0.0
        for index in 0..<(xCoordinates.count - 1) {
            let lowerX = xCoordinates[index]
            let upperX = xCoordinates[index + 1]
            let width = upperX - lowerX
            guard width > 0 else { continue }
            let intervals = rectangles.compactMap { rectangle -> ClosedRange<Double>? in
                guard rectangle.minX < upperX, rectangle.maxX > lowerX else { return nil }
                return rectangle.minY...rectangle.maxY
            }.sorted { $0.lowerBound < $1.lowerBound }
            guard var current = intervals.first else { continue }
            var coveredHeight = 0.0
            for interval in intervals.dropFirst() {
                if interval.lowerBound <= current.upperBound {
                    current = current.lowerBound...max(current.upperBound, interval.upperBound)
                } else {
                    coveredHeight += current.upperBound - current.lowerBound
                    current = interval
                }
            }
            coveredHeight += current.upperBound - current.lowerBound
            area += width * coveredHeight
        }
        return area
    }

    private static func isBlockingWindow(
        _ window: WindowSnapshot,
        currentProcessId: Int,
        screenFrames: [CGRect]
    ) -> Bool {
        guard window.layer == 0,
              window.alpha >= minimumBlockingWindowAlpha,
              window.bounds.area > 12_000 else {
            return false
        }
        if window.processId == currentProcessId {
            return false
        }
        if isFinderDesktopHost(window, screenFrames: screenFrames) {
            return false
        }
        if isSmallDesktopOverlay(window, screenFrames: screenFrames) {
            return false
        }
        return !ignoredOwners.contains(window.ownerName)
    }

    /// Finder owns both the real desktop host and ordinary folder windows.
    /// A size-only heuristic therefore cannot safely identify the desktop:
    /// fullscreen/tiled Finder windows must continue to count as coverage.
    /// Prefer WindowServer's window name, then require the candidate to match
    /// a complete display. Any ambiguity fails safe as a user window.
    private static func isFinderDesktopHost(
        _ window: WindowSnapshot,
        screenFrames: [CGRect]
    ) -> Bool {
        guard window.ownerName == "Finder" else {
            return false
        }
        guard let name = window.windowName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              name.caseInsensitiveCompare("Desktop") == .orderedSame else {
            return false
        }
        return screenFrames.contains { screenFrame in
            rectanglesApproximatelyMatch(window.bounds, screenFrame)
        }
    }

    private static func rectanglesApproximatelyMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        guard lhs.width > 0, lhs.height > 0, rhs.width > 0, rhs.height > 0 else {
            return false
        }
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else {
            return false
        }
        let intersectionArea = intersection.area
        return intersectionArea / lhs.area >= minimumCoveredFraction
            && intersectionArea / rhs.area >= minimumCoveredFraction
    }

    private static func isSmallDesktopOverlay(_ window: WindowSnapshot, screenFrames: [CGRect]) -> Bool {
        guard max(window.bounds.width, window.bounds.height) <= 240 else {
            return false
        }
        return screenFrames.contains { screen in
            abs(window.bounds.minX - screen.minX) <= 80 || abs(window.bounds.maxX - screen.maxX) <= 80
        }
    }
}

extension DesktopVisibilityMonitor {
    struct WindowSnapshot {
        let ownerName: String
        let windowName: String?
        let processId: Int?
        let layer: Int
        let alpha: Double
        let bounds: CGRect

        init(
            ownerName: String,
            windowName: String? = nil,
            processId: Int?,
            layer: Int,
            alpha: Double,
            bounds: CGRect
        ) {
            self.ownerName = ownerName
            self.windowName = windowName
            self.processId = processId
            self.layer = layer
            self.alpha = alpha
            self.bounds = bounds
        }

        init(_ window: [String: Any]) {
            ownerName = window[kCGWindowOwnerName as String] as? String ?? ""
            windowName = window[kCGWindowName as String] as? String
            processId = window[kCGWindowOwnerPID as String] as? Int
            layer = window[kCGWindowLayer as String] as? Int ?? Int.max
            alpha = window[kCGWindowAlpha as String] as? Double ?? 1
            bounds = Self.cgRect(from: window[kCGWindowBounds as String] as? [String: Any])
        }

        private static func cgRect(from bounds: [String: Any]?) -> CGRect {
            guard let bounds else {
                return .zero
            }
            return CGRect(
                x: bounds["X"] as? Double ?? 0,
                y: bounds["Y"] as? Double ?? 0,
                width: bounds["Width"] as? Double ?? 0,
                height: bounds["Height"] as? Double ?? 0
            )
        }
    }
}

private extension CGRect {
    var area: Double {
        width * height
    }
}

/// Full-screen windows can leave a few pixels to WindowServer-managed chrome
/// or rounding between Retina coordinate spaces. Requiring 95% coverage keeps
/// those sessions pausable without treating ordinary partial or centered
/// windows as a completely covered desktop.
private let minimumCoveredFraction = 0.95

/// WindowServer reports a single opacity for the complete window. A
/// translucent full-screen overlay still leaves the wallpaper visible, so it
/// must not be treated as a fully covered desktop.
private let minimumBlockingWindowAlpha = 0.95

private let ignoredOwners = [
    "AirPlayUIAgent",
    "Continuity",
    "Continuity Camera",
    "Window Server",
    "Dock",
    "Control Center",
    "ControlCenter",
    "ContinuityCaptureAgent",
    "Handoff",
    "WindowManager",
    "Notification Center",
    "SystemUIServer"
]
