import BackgroundEngineCore
import SwiftUI

struct DisplaysView: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Display Sessions")
                        .font(.title2.weight(.semibold))
                    Text("Each connected display keeps an independent wallpaper and playback policy.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") {
                    model.refreshConnectedDisplays()
                }
                Button("Apply Sessions", systemImage: "play.fill") {
                    model.applyDisplayAssignments()
                }
                .buttonStyle(.borderedProminent)
            }

            if model.connectedDisplays.isEmpty {
                ContentUnavailableView("No Displays", systemImage: "display.trianglebadge.exclamationmark")
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.connectedDisplays) { display in
                            DisplayAssignmentCard(display: display, model: model)
                        }
                    }
                }
            }
        }
        .padding(20)
    }
}

private struct DisplayAssignmentCard: View {
    let display: ConnectedDisplay
    @ObservedObject var model: AppViewModel

    private var assignment: DisplayAssignment { model.displayAssignment(for: display.id) }

    var body: some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text("Wallpaper")
                        .foregroundStyle(.secondary)
                    Picker("Wallpaper", selection: assetBinding) {
                        Text("None").tag(Optional<String>.none)
                        ForEach(model.libraryAssets) { asset in
                            Text(asset.title).tag(Optional(asset.id))
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Layout")
                        .foregroundStyle(.secondary)
                    Picker("Layout", selection: displayModeBinding) {
                        ForEach(WallpaperDisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                GridRow {
                    Text("Quality")
                        .foregroundStyle(.secondary)
                    Picker("Quality", selection: qualityBinding) {
                        ForEach(RenderQuality.allCases, id: \.self) { quality in
                            Text(quality.rawValue.capitalized).tag(quality)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                GridRow {
                    Text("Audio")
                        .foregroundStyle(.secondary)
                    Toggle("Play wallpaper audio on the primary display", isOn: audioBinding)
                        .disabled(!display.isPrimary)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Label(display.name, systemImage: display.isPrimary ? "display" : "rectangle.on.rectangle")
                    .font(.headline)
                if display.isPrimary {
                    Text("PRIMARY")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                Text("\(Int(display.resolution.width)) × \(Int(display.resolution.height))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var assetBinding: Binding<String?> {
        Binding(
            get: { assignment.assetID },
            set: { assetID in
                if let assetID {
                    model.updateDisplayAssignment(displayUUID: display.id, assetID: assetID)
                } else {
                    model.updateDisplayAssignment(displayUUID: display.id, clearAsset: true)
                }
            }
        )
    }

    private var displayModeBinding: Binding<WallpaperDisplayMode> {
        Binding(
            get: { assignment.displayMode },
            set: { model.updateDisplayAssignment(displayUUID: display.id, displayMode: $0) }
        )
    }

    private var qualityBinding: Binding<RenderQuality> {
        Binding(
            get: { assignment.quality },
            set: { model.updateDisplayAssignment(displayUUID: display.id, quality: $0) }
        )
    }

    private var audioBinding: Binding<Bool> {
        Binding(
            get: { assignment.audioSource == .primaryDisplay },
            set: {
                model.updateDisplayAssignment(
                    displayUUID: display.id,
                    audioSource: $0 ? .primaryDisplay : .muted
                )
            }
        )
    }
}
