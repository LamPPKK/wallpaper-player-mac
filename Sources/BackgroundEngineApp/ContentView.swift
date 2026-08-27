import AppKit
import SwiftUI
import BackgroundEngineCore

private enum SidebarDestination: String, CaseIterable, Identifiable {
    case library
    case downloads
    case displays
    case settings

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var systemImage: String {
        switch self {
        case .library: "photo.stack"
        case .downloads: "arrow.down.circle"
        case .displays: "display.2"
        case .settings: "gearshape"
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppViewModel
    @State private var destination: SidebarDestination? = .library

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                List(SidebarDestination.allCases, selection: $destination) { item in
                    Label(item.title, systemImage: item.systemImage)
                        .tag(item)
                        .accessibilityIdentifier("sidebar.\(item.rawValue)")
                }
                .navigationTitle("Background Engine")
                .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            } detail: {
                detailView
                    .navigationTitle(destination?.title ?? "Background Engine")
                    .toolbar {
                        ToolbarItemGroup(placement: .primaryAction) {
                            Button {
                                model.stopPlayback()
                            } label: {
                                Label("Stop All", systemImage: "stop.fill")
                            }
                            .keyboardShortcut(".", modifiers: [.command, .shift])
                        }
                    }
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 900, minHeight: 640)
        .accessibilityIdentifier("main.navigation")
        .alert(item: $model.updateAlert) { alert in
            updateAlert(alert)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch destination ?? .library {
        case .library:
            LibraryTabView(model: model)
        case .downloads:
            DownloadsView(model: model)
        case .displays:
            DisplaysView(model: model)
        case .settings:
            SettingsTabView(model: model)
        }
    }

    private func updateAlert(_ alert: UpdateAlert) -> Alert {
        return Alert(
            title: Text(alert.title),
            message: Text(alert.message),
            dismissButton: .default(Text(model.L("common.ok")))
        )
    }

    private var statusBar: some View {
        HStack {
            if let lively = model.activeOfficialLivelyInstallState,
               let fraction = lively.fractionCompleted {
                ProgressView(value: fraction)
                    .controlSize(.small)
                    .frame(width: 120)
                    .accessibilityLabel("Installing \(lively.title)")
                    .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
            } else if model.activeOfficialLivelyInstallState != nil {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(
                        model.activeOfficialLivelyInstallState?.statusText
                            ?? "Lively wallpaper installation in progress"
                    )
            } else if let progress = model.importProgress {
                ProgressView(value: progress.fraction)
                    .controlSize(.small)
                    .frame(width: 120)
            } else if model.isWorking {
                ProgressView()
                    .controlSize(.small)
            }
            Text(model.status)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if let lively = model.activeOfficialLivelyInstallState {
                Button("Cancel") {
                    model.cancelOfficialLivelyWallpaperInstall()
                }
                .controlSize(.small)
                .disabled(!lively.canCancel)
                .accessibilityLabel("Cancel \(lively.title) installation")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

/// A small "ⓘ" affordance that reveals a one-time explanation in a popover,
/// used to keep long help/caption text out of the always-visible layout.
struct HelpPopoverButton: View {
    let title: String
    let message: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .popover(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .frame(width: 300)
        }
    }
}

struct AssetPreview: View {
    let asset: WallpaperAsset?
    let placeholderTitle: String
    let placeholderDescription: String

    var body: some View {
        HStack(spacing: 12) {
            previewImage
            VStack(alignment: .leading, spacing: 4) {
                Text(asset?.title ?? placeholderTitle)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(assetDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let compatibilityDescription {
                    Text(compatibilityDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let issue = asset?.issues.first {
                    Text(issue.message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(10)
        .frame(minHeight: 112, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var previewImage: some View {
        AssetThumbnail(asset: asset, width: 144, height: 88, cornerRadius: 6)
    }

    private var assetDescription: String {
        guard let asset else {
            return placeholderDescription
        }
        let status = LibraryRowStatusResolver.status(for: asset).label
        return "\(asset.kind.rawValue) · \(status)"
    }

    private var compatibilityDescription: String? {
        guard let report = asset?.compatibilityReport else { return nil }
        let path = report.playbackPath?.rawValue ?? "none"
        if !report.missingCapabilities.isEmpty {
            return "Path: \(path) · Missing: \(report.missingCapabilities.map(\.rawValue).joined(separator: ", "))"
        }
        return report.warnings.first.map { "Path: \(path) · \($0)" } ?? "Path: \(path)"
    }
}

struct AssetRow: View {
    let asset: WallpaperAsset
    // Unused beyond forcing SwiftUI to re-evaluate this row's body: SwiftUI
    // skips recomputing a child view's body when its stored properties are
    // structurally unchanged, even if the enclosing `@ObservedObject`
    // published an unrelated change. Without a property here that changes
    // when a scene's video render completes, `displayStatus` below would
    // keep returning its first-render value until `asset` itself changed
    // (e.g. on the next library rescan), so the badge would look stuck on
    // "renders on first play" even after the cached video exists.
    let sceneVideoRenderRevision: Int
    var isNew: Bool = false
    var newBadgeText: String = "NEW"

    // Derived fresh on every body evaluation (not cached in the row) so the
    // badge picks up a completed scene video render as soon as the list
    // re-renders, without needing dedicated per-row observation wiring.
    private var displayStatus: LibraryRowDisplayStatus {
        LibraryRowStatusResolver.status(for: asset)
    }

    var body: some View {
        HStack(spacing: 10) {
            AssetThumbnail(asset: asset, width: 64, height: 40, cornerRadius: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(asset.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(asset.projectDirectory)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let issue = asset.issues.first {
                    Text(issue.message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if isNew {
                Text(newBadgeText)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
            }
            if let dateAddedText {
                Text(dateAddedText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(asset.kind.rawValue)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
            Text(displayStatus.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(displayStatus.isPositive ? .green : .orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background((displayStatus.isPositive ? Color.green : Color.orange).opacity(0.12), in: Capsule())
        }
        .padding(.vertical, 4)
    }

    private var dateAddedText: String? {
        guard let dateAdded = asset.dateAdded else {
            return nil
        }
        return Self.dateFormatter.string(from: dateAdded)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct AssetThumbnail: View {
    let asset: WallpaperAsset?
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.72))
            if let image = previewNSImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: width, height: height)
            } else {
                Text(asset?.kind.rawValue.uppercased() ?? "PREVIEW")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 6)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityLabel(accessibilityLabel)
    }

    private var previewNSImage: NSImage? {
        guard let url = previewURL else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    private var previewURL: URL? {
        guard let asset else {
            return nil
        }
        if let thumbnail = asset.thumbnail {
            return URL(filePath: thumbnail)
        }
        guard asset.kind == .image, let entrypoint = asset.entrypoint else {
            return nil
        }
        return URL(filePath: entrypoint)
    }

    private var accessibilityLabel: String {
        guard let asset else {
            return "Wallpaper preview placeholder"
        }
        return "Wallpaper preview for \(asset.title)"
    }
}
