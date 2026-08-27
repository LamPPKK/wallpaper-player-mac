import SwiftUI
@_spi(LivelyCatalog) import BackgroundEngineCore

/// The main "Library" tab: importing a copied Workshop folder, browsing the
/// Mac-local library, and playing/managing wallpapers. The imported-library
/// list is given the most vertical space; scanned-but-not-yet-imported
/// projects only take a small strip above it, and only while there are any.
struct LibraryTabView: View {
    @ObservedObject var model: AppViewModel
    @Environment(\.openURL) private var openURL
    @State private var webPropertyAsset: WallpaperAsset?
    @State private var pendingOfficialLivelyWallpaper: OfficialLivelyWallpaper?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            importRow
            if !model.scannedAssets.isEmpty {
                scannedSection
            }
            toolbarRow
            libraryList
            AssetPreview(
                asset: model.selectedLibraryAsset,
                placeholderTitle: model.L("library.preview.placeholder"),
                placeholderDescription: model.L("library.preview.empty")
            )
            rotationRow
            actionRow
        }
        .padding()
        .confirmationDialog(
            removeConfirmationTitle,
            isPresented: Binding(
                get: { model.pendingLibraryRemoval != nil },
                set: { isPresented in
                    if !isPresented {
                        model.cancelPendingLibraryRemoval()
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: model.pendingLibraryRemoval
        ) { _ in
            Button(model.L("library.remove.confirm.button"), role: .destructive) {
                model.removeSelectedLibraryAssets()
            }
            Button(model.L("common.cancel"), role: .cancel) {
                model.cancelPendingLibraryRemoval()
            }
        } message: { _ in
            Text(model.L("library.remove.confirm.message"))
        }
        .confirmationDialog(
            "Allow network access to this wallpaper?",
            isPresented: Binding(
                get: { model.pendingWebNetworkAssetID != nil },
                set: { if !$0 { model.cancelWebNetworkAccessChange() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Allow for This Wallpaper") {
                model.confirmWebNetworkAccess()
            }
            .disabled(model.isWorking)
            Button("Cancel", role: .cancel) {
                model.cancelWebNetworkAccessChange()
            }
        } message: {
            Text("This runs untrusted wallpaper code with HTTP/HTTPS and WebSocket access. A hostname can resolve or rebind to a device or service on your local network, so only continue for a wallpaper you trust. Literal private addresses, navigation, downloads, persistent cookies, and native bridges remain blocked, but URL filtering is not a complete local-network boundary.")
        }
        .confirmationDialog(
            pendingOfficialLivelyWallpaper.map { "Download \($0.title)?" }
                ?? "Download Lively Wallpaper?",
            isPresented: Binding(
                get: { pendingOfficialLivelyWallpaper != nil },
                set: { if !$0 { pendingOfficialLivelyWallpaper = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingOfficialLivelyWallpaper
        ) { wallpaper in
            Button("Download and Import") {
                pendingOfficialLivelyWallpaper = nil
                model.installOfficialLivelyWallpaper(wallpaper)
            }
            .disabled(model.isWorking)
            Button("View License") {
                openURL(wallpaper.licenseURL)
            }
            Button("View Source") {
                openURL(wallpaper.pinnedSourceURL)
            }
            Button("Cancel", role: .cancel) {
                pendingOfficialLivelyWallpaper = nil
            }
        } message: { wallpaper in
            Text(
                "\(wallpaper.summary) Background Engine downloads the pinned ZIP directly from rocksdanister's GitHub release and verifies its SHA-256 before import. The wallpaper is not bundled with the app. License: \(wallpaper.licenseName), including non-commercial and share-alike terms. Download size: \(formattedArchiveSize(wallpaper.archiveByteCount))."
            )
        }
        .sheet(item: $webPropertyAsset) { asset in
            WebWallpaperPropertiesEditorView(
                asset: asset,
                properties: WebWallpaperCompatibilityBridge.editableProperties(
                    projectRoot: URL(filePath: asset.projectDirectory)
                )
            ) { values in
                try await model.saveWebPropertyOverrides(values, for: asset)
            }
        }
    }

    private var removeConfirmationTitle: String {
        guard let pending = model.pendingLibraryRemoval else {
            return model.L("library.remove.confirm.title.fallback")
        }
        return String(format: model.L("library.remove.confirm.title"), pending.title)
    }

    private var importRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(model.L("library.source.title"))
                    .font(.subheadline.weight(.semibold))
                HelpPopoverButton(
                    title: model.L("library.import.help.title"),
                    message: model.L("library.import.help.body")
                )
                Spacer()
            }
            HStack(spacing: 8) {
                TextField(model.L("library.source.placeholder"), text: $model.sourcePath)
                Button(model.L("library.browse")) {
                    model.chooseFolder()
                }
                Button(model.L("library.scan")) {
                    model.scanSource()
                }
            }
        }
    }

    private var scannedSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(model.L("library.scanned.empty")) (\(model.scannedAssets.count))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker(model.L("library.sort.title"), selection: $model.scannedSortOrder) {
                    ForEach(ScannedAssetSortOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                Button(importButtonTitle) {
                    model.importSelected()
                }
                .disabled(model.selectedScannedAssetIds.isEmpty)
            }
            List(
                selection: Binding(
                    get: { model.selectedScannedAssetIds },
                    set: { model.selectScannedAssets($0) }
                )
            ) {
                ForEach(model.scannedAssets) { asset in
                    AssetRow(
                        asset: asset,
                        sceneVideoRenderRevision: model.sceneVideoRenderRevision,
                        isNew: model.isNewScannedAsset(asset),
                        newBadgeText: model.L("library.new.badge")
                    )
                    .tag(asset.id)
                }
            }
            .frame(height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            AssetPreview(
                asset: model.selectedScannedAsset,
                placeholderTitle: model.L("library.preview.placeholder"),
                placeholderDescription: model.L("library.preview.empty")
            )
        }
    }

    private var toolbarRow: some View {
        HStack(spacing: 12) {
            Text(model.L("library.imported.empty"))
                .font(.headline)
            Spacer()
            Picker(model.L("library.display"), selection: $model.displayMode) {
                ForEach(WallpaperDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            livelyInstallMenu
            Button("Add Lively…") {
                model.chooseLivelyWallpaperPackage()
            }
            .disabled(model.isWorking)
            .help("Import a user-provided Lively Wallpaper .zip export or project folder.")
            Button("Add Website…") {
                model.chooseWebsite()
            }
            Button(model.L("library.addVideo")) {
                model.chooseWallpaperFile()
            }
        }
    }

    private var libraryList: some View {
        List(
            selection: Binding(
                get: { model.selectedLibraryAssetIds },
                set: { model.selectLibraryAssets($0) }
            )
        ) {
            ForEach(model.libraryAssets) { asset in
                AssetRow(asset: asset, sceneVideoRenderRevision: model.sceneVideoRenderRevision)
                    .tag(asset.id)
                    .contextMenu {
                        contextMenuItems(for: asset)
                    }
            }
        }
        .overlay {
            if model.libraryAssets.isEmpty {
                VStack(spacing: 10) {
                    Text(model.L("library.imported.empty"))
                        .foregroundStyle(.tertiary)
                    livelyInstallMenu
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(maxHeight: .infinity)
    }

    private var livelyInstallMenu: some View {
        Menu {
            Button {
                model.installBundledLivelyWallpapers()
            } label: {
                Label("Install Included Collection (6)", systemImage: "shippingbox")
            }
            .disabled(model.isWorking || !model.bundledLivelyWallpapersAvailable)

            Divider()

            Section("Official GitHub Releases") {
                ForEach(OfficialLivelyWallpaperCatalog.wallpapers) { wallpaper in
                    Button {
                        pendingOfficialLivelyWallpaper = wallpaper
                    } label: {
                        Label(
                            "Download \(wallpaper.title)…",
                            systemImage: livelySystemImage(for: wallpaper)
                        )
                    }
                    .disabled(model.isWorking)
                }
            }
        } label: {
            Label("Lively Wallpapers", systemImage: "sparkles.rectangle.stack")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Install the included license-reviewed collection or download pinned official Lively releases after reviewing their licenses.")
    }

    private func livelySystemImage(for wallpaper: OfficialLivelyWallpaper) -> String {
        switch wallpaper.id {
        case "rocksdanister-rain-v3": "cloud.rain"
        case "rocksdanister-snow-v1": "snowflake"
        case "rocksdanister-clouds-v1": "cloud"
        default: "photo.on.rectangle"
        }
    }

    private func formattedArchiveSize(_ byteCount: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    private var rotationRow: some View {
        HStack(spacing: 12) {
            Toggle(model.L("library.rotate"), isOn: $model.rotationEnabled)
                .toggleStyle(.switch)
                .lineLimit(1)
                .fixedSize()
            Toggle(model.L("library.rotate.shuffle"), isOn: $model.rotationShuffle)
                .toggleStyle(.switch)
                .lineLimit(1)
                .fixedSize()
            Picker(model.L("library.rotate.every"), selection: $model.rotationInterval) {
                ForEach(AppViewModel.rotationIntervalOptions, id: \.seconds) { option in
                    Text(option.label).tag(option.seconds)
                }
            }
            .fixedSize()
            Button(model.L("library.rotate.next")) {
                model.nextWallpaper()
            }
            .disabled(!model.rotationEnabled)
            Spacer()
        }
    }

    @ViewBuilder
    private func contextMenuItems(for asset: WallpaperAsset) -> some View {
        if asset.kind == .web {
            Button(asset.allowsNetworkAccess == true ? "Block External Network" : "Allow External Network…") {
                model.requestWebNetworkAccessChange(for: asset)
            }
            .disabled(model.isWorking)
            Divider()
        }
        Button(model.L("library.convert")) {
            model.selectLibraryAssets([asset.id])
            model.convertSelected()
        }
        .disabled(!asset.videoConversionActionAvailable || model.isWorking)
        Button(model.L("library.setStillWallpaper")) {
            model.selectLibraryAssets([asset.id])
            model.setStillWallpaper()
        }
        Divider()
        Button(model.L("library.remove")) {
            model.selectLibraryAssets([asset.id])
            model.requestRemoveSelectedLibraryAssets()
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button(model.L("library.play")) {
                model.playSelected()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(model.selectedLibraryAsset == nil)
            Menu("Assign to Display") {
                ForEach(model.connectedDisplays) { display in
                    Button(display.isPrimary ? "\(display.name) (Primary)" : display.name) {
                        model.assignSelectedWallpaperToDisplay(display.id)
                        model.applyDisplayAssignments()
                    }
                }
            }
            .disabled(model.selectedLibraryAsset == nil || model.connectedDisplays.isEmpty)
            Button(removeButtonTitle) {
                model.requestRemoveSelectedLibraryAssets()
            }
            .disabled(model.selectedLibraryAssetIds.isEmpty)
            .keyboardShortcut(.delete, modifiers: [])
            Menu(model.L("library.more")) {
                Button(model.L("library.convert")) {
                    model.convertSelected()
                }
                .disabled(model.selectedLibraryAsset?.videoConversionActionAvailable != true || model.isWorking)
                Button(model.L("library.setStillWallpaper")) {
                    model.setStillWallpaper()
                }
                .disabled(model.selectedLibraryAsset == nil)
                Button(model.L("library.screenSaverSettings")) {
                    model.openScreenSaverSettings()
                }
                if let asset = model.selectedLibraryAsset,
                   !model.selectedWebEditableProperties.isEmpty {
                    Divider()
                    Button("Customize Web Properties…") {
                        webPropertyAsset = asset
                    }
                    .disabled(model.isWorking)
                }
                if !model.selectedWebFileProperties.isEmpty {
                    Divider()
                    ForEach(model.selectedWebFileProperties) { property in
                        Button("Choose \(property.name)…") {
                            model.chooseWebProperty(property)
                        }
                    }
                }
            }
            .fixedSize()
            Spacer()
            HelpPopoverButton(
                title: model.L("library.help.title"),
                message: model.L("library.help.body")
            )
        }
    }

    private var importButtonTitle: String {
        model.selectedScannedAssetCount > 1
            ? "\(model.L("library.import")) (\(model.selectedScannedAssetCount))"
            : model.L("library.import")
    }

    private var removeButtonTitle: String {
        model.selectedLibraryAssetCount > 1
            ? model.L("library.remove.selected")
            : model.L("library.remove")
    }
}
