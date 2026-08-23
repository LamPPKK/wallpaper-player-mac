import Foundation

public struct WallpaperScanner: Sendable {
    private let classifyContent: @Sendable (URL, String?) -> MediaContentClassification

    public init() {
        let contentProbe = MediaContentProbe()
        classifyContent = { url, metadataType in
            contentProbe.classify(url, metadataType: metadataType)
        }
    }

    /// Internal dependency seam used by deterministic importer tests. Product
    /// callers keep using the bundled/runtime-resolving probe above.
    init(contentProbe: MediaContentProbe) {
        classifyContent = { url, metadataType in
            contentProbe.classify(url, metadataType: metadataType)
        }
    }

    /// Lets scanner tests observe which metadata hint is applied to each
    /// candidate without launching media processes or decoding large files.
    init(
        contentClassifier: @escaping @Sendable (URL, String?) -> MediaContentClassification
    ) {
        classifyContent = contentClassifier
    }

    public func scan(root: URL) throws -> ScanResult {
        try scan(root: root, performsSceneRenderProbe: true)
    }

    /// Used only by the one-time legacy manifest repair. It still identifies
    /// and validates the Scene package, but leaves expensive texture decoding
    /// to the app's asynchronous compatibility probe workflow.
    func scanForLibraryMigration(root: URL) throws -> ScanResult {
        try scan(root: root, performsSceneRenderProbe: false)
    }

    private func scan(root: URL, performsSceneRenderProbe: Bool) throws -> ScanResult {
        let projects = try discoverProjects(root: root.standardizedFileURL)
        let assets = try projects
            .map {
                try scanProject(
                    root: root.standardizedFileURL,
                    project: $0,
                    performsSceneRenderProbe: performsSceneRenderProbe
                )
            }
            .sorted(by: dateAddedSort)
        return ScanResult(root: root.path, generatedAt: Date(), assets: assets)
    }

    private func discoverProjects(root: URL) throws -> [URL] {
        if isProjectDirectory(root) {
            return [root]
        }
        return try FileManager.default
            .contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .addedToDirectoryDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            .filter { isDirectory($0) && isProjectDirectory($0) }
    }

    private func scanProject(
        root: URL,
        project: URL,
        performsSceneRenderProbe: Bool
    ) throws -> WallpaperAsset {
        let metadata = ProjectMetadata.load(from: project.appending(path: "project.json"))
        let selection = try findEntrypoint(
            in: project,
            preferredFile: metadata.value?.file,
            metadataType: metadata.value?.type
        )
        let entry = selection.url
        let kind = classify(
            metadataType: metadata.value?.type,
            classification: selection.classification
        )
        let status = supportStatus(kind: kind, classification: selection.classification)
        let report = kind == .scene && status == .playable && !performsSceneRenderProbe
            ? CompatibilityReport.pendingSceneProbe()
            : WallpaperCompatibilityAnalyzer().analyze(
                kind: kind,
                status: status,
                entrypoint: entry,
                projectRoot: project
            )
        let issues = issues(metadata: metadata, kind: kind, status: status, entrypoint: entry)
        let thumbnail = try findThumbnail(in: project, preferredFile: metadata.value?.preview)
        let id = project.lastPathComponent
        return WallpaperAsset(
            id: id,
            title: metadata.value?.title?.nonEmpty ?? id,
            kind: kind,
            supportStatus: status,
            source: sourceKind(for: root),
            projectDirectory: project.path,
            entrypoint: entry?.path,
            thumbnail: thumbnail?.path,
            workshopId: id.allSatisfy(\.isNumber) ? id : nil,
            dateAdded: dateAdded(for: project),
            compatibility: report.supportMode,
            compatibilityReport: report,
            redistributionAllowed: false,
            issues: issues
        )
    }

    private func isProjectDirectory(_ url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.appending(path: "project.json").path) {
            return true
        }
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            return false
        }
        return files.contains { file in
            let candidate = url.appending(path: file)
            return classifyContent(candidate, nil).kind != .unknown
        }
    }

    private func findEntrypoint(
        in project: URL,
        preferredFile: String?,
        metadataType: String?
    ) throws -> EntrypointSelection {
        let expectedKind = declaredKind(metadataType)
        let preferred = preferredFile.flatMap {
            resolveExisting(project: project, relativePath: $0)
        }
        let preferredClassification = preferred.map {
            entrypointClassification(
                $0,
                metadataType: metadataType,
                expectedKind: expectedKind
            )
        }
        if let preferred,
           let preferredClassification,
           expectedKind == .application || isPlayableEntrypoint(
               preferredClassification,
               expectedKind: expectedKind
           ) {
            return EntrypointSelection(url: preferred, classification: preferredClassification)
        }
        let files = try recursiveFiles(in: project)
        let fallback = files.sorted {
            entrypointSort($0, $1, expectedKind: expectedKind)
        }.lazy.compactMap { candidate -> EntrypointSelection? in
            guard !isImplicitThumbnail(candidate) else { return nil }
            let classification = entrypointClassification(
                candidate,
                metadataType: metadataType,
                expectedKind: expectedKind
            )
            guard isPlayableEntrypoint(classification, expectedKind: expectedKind) else {
                return nil
            }
            return EntrypointSelection(url: candidate, classification: classification)
        }.first
        if let fallback {
            return fallback
        }
        // Preserve an existing but invalid declared entrypoint when no valid
        // alternative exists. The scanner can then report the project as
        // Unsupported with a useful probe diagnostic instead of pretending
        // the referenced file was missing.
        return EntrypointSelection(url: preferred, classification: preferredClassification)
    }

    private func declaredKind(_ metadataType: String?) -> WallpaperKind? {
        return switch metadataType?.lowercased() {
        case "video": .video
        case "web": .web
        case "scene": .scene
        case "image": .image
        case "application": .application
        default: nil
        }
    }

    private func entrypointClassification(
        _ url: URL,
        metadataType: String?,
        expectedKind: WallpaperKind?
    ) -> MediaContentClassification {
        // Passing a recognized declared type preserves bounded Web preamble
        // compatibility and fail-fast expected-kind checks. Scene metadata is
        // safe for fallback candidates because MediaContentProbe gates its
        // package analyzer behind a bounded PKGV header check.
        let probeMetadataType = expectedKind == nil ? nil : metadataType
        return classifyContent(url, probeMetadataType)
    }

    private func isPlayableEntrypoint(
        _ classification: MediaContentClassification,
        expectedKind: WallpaperKind?
    ) -> Bool {
        guard classification.supportStatus == .playable
                || classification.supportStatus == .needsConversion else {
            return false
        }
        return expectedKind.map { classification.kind == $0 }
            ?? (classification.kind != .unknown && classification.kind != .application)
    }

    private func findThumbnail(in project: URL, preferredFile: String?) throws -> URL? {
        if let preferredFile, let preferred = resolveExisting(project: project, relativePath: preferredFile) {
            return preferred
        }
        return try recursiveFiles(in: project).first {
            imageExtensions.contains($0.pathExtension.lowercased())
                && preferredThumbnailNames.contains($0.deletingPathExtension().lastPathComponent.lowercased())
        }
    }

    private func recursiveFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL, isRegularFile(url) else {
                return nil
            }
            guard isInside(url, root: directory) else {
                return nil
            }
            return url
        }
    }

    private func resolveExisting(project: URL, relativePath: String) -> URL? {
        // Workshop metadata is authored on Windows and occasionally keeps
        // backslash separators even after Steam copies the project to macOS.
        // Treat those separators as project-relative path components; without
        // this normalization a valid nested entrypoint is missed and the
        // fallback scanner can select a different HTML/media file.
        let normalizedRelativePath = relativePath.replacingOccurrences(of: "\\", with: "/")
        guard !normalizedRelativePath.isEmpty,
              !normalizedRelativePath.contains("\0"),
              !(normalizedRelativePath as NSString).isAbsolutePath,
              normalizedRelativePath.range(
                  of: #"^[A-Za-z]:"#,
                  options: .regularExpression
              ) == nil else {
            return nil
        }
        let candidate = project.appending(path: normalizedRelativePath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: candidate.path),
              isRegularFile(candidate),
              isInside(candidate, root: project) else {
            return nil
        }
        return candidate
    }

    private func isInside(_ url: URL, root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let urlComponents = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard urlComponents.count > rootComponents.count else {
            return false
        }
        return Array(urlComponents.prefix(rootComponents.count)) == rootComponents
    }

    private func isImplicitThumbnail(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
            && preferredThumbnailNames.contains(url.deletingPathExtension().lastPathComponent.lowercased())
    }

    private func classify(
        metadataType: String? = nil,
        classification: MediaContentClassification?
    ) -> WallpaperKind {
        let expectedKind = declaredKind(metadataType)
        guard let classification else {
            return expectedKind == .application ? .application : .unknown
        }
        let probedKind = classification.kind
        guard let expectedKind, expectedKind != .application else {
            return expectedKind ?? probedKind
        }
        return probedKind == expectedKind ? probedKind : .unknown
    }

    private func supportStatus(
        kind: WallpaperKind,
        classification: MediaContentClassification?
    ) -> SupportStatus {
        switch kind {
        case .video, .web, .image, .scene:
            return classification?.supportStatus ?? .unsupported
        case .application, .unknown:
            return .unsupported
        }
    }

    private func issues(
        metadata: ProjectMetadataResult,
        kind: WallpaperKind,
        status: SupportStatus,
        entrypoint: URL?
    ) -> [ScanIssue] {
        var result = metadata.issue.map { [$0] } ?? []
        if entrypoint == nil {
            result.append(
                ScanIssue(code: "no_supported_entrypoint", message: "No playable media entrypoint was found.")
            )
        }
        if kind == .scene {
            result.append(contentsOf: sceneIssues(entrypoint: entrypoint, status: status))
        }
        if kind == .application {
            result.append(
                ScanIssue(
                    code: "windows_application_unsupported",
                    message: "Windows Application wallpapers are recognized but are not supported on macOS."
                )
            )
        }
        return result
    }

    private func sceneIssues(entrypoint: URL?, status: SupportStatus) -> [ScanIssue] {
        guard let entrypoint else {
            return [
                ScanIssue(
                    code: "scene_package_missing",
                    message: "scene.pkg metadata was detected but the package file was not found."
                )
            ]
        }
        guard status == .playable else {
            return [
                ScanIssue(
                    code: "scene_package_unreadable",
                    message: "The declared Scene entrypoint does not contain a readable PKGV package."
                )
            ]
        }
        do {
            let analysis = try ScenePackageAnalyzer().analyze(url: entrypoint)
            return [
                ScanIssue(code: "scene_package_detected", message: analysis.userFacingSummary),
                ScanIssue(
                    code: "scene_renderer_limited",
                    message: "Scene playback supports 2D image layers, animated sprite textures, text layers, "
                        + "selected text SceneScript, "
                        + "keyframed motion, and selected effect motion; advanced shaders, particles, advanced scripts, audio, "
                        + "and video textures may differ."
                )
            ]
        } catch {
            return [
                ScanIssue(
                    code: "scene_package_unreadable",
                    message: "scene.pkg could not be inspected: \(error.localizedDescription)"
                )
            ]
        }
    }

    private func sourceKind(for root: URL) -> SourceKind {
        let path = root.path.lowercased().replacingOccurrences(of: "\\", with: "/")
        if path.contains("/steamapps/workshop/content/431960") {
            return .localSteamWorkshop
        }
        if path.contains("/wallpaper_engine/projects/backup") {
            return .wallpaperEngineBackup
        }
        return .manualFolder
    }

    private func dateAdded(for project: URL) -> Date? {
        let values = try? project.resourceValues(forKeys: [.addedToDirectoryDateKey, .contentModificationDateKey])
        return values?.addedToDirectoryDate ?? values?.contentModificationDate
    }
}

private struct EntrypointSelection {
    let url: URL?
    let classification: MediaContentClassification?
}

private struct ProjectMetadata: Decodable {
    let title: String?
    let file: String?
    let preview: String?
    let type: String?
}

private struct ProjectMetadataResult {
    let value: ProjectMetadata?
    let issue: ScanIssue?
}

private extension ProjectMetadata {
    static func load(from url: URL) -> ProjectMetadataResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ProjectMetadataResult(value: nil, issue: nil)
        }
        do {
            let data = try Data(contentsOf: url)
            let value = try JSONDecoder().decode(ProjectMetadata.self, from: data)
            return ProjectMetadataResult(value: value, issue: nil)
        } catch {
            return ProjectMetadataResult(
                value: nil,
                issue: ScanIssue(code: "malformed_project_json", message: "project.json could not be parsed.")
            )
        }
    }
}

private let playableVideoExtensions = ["mp4", "mov", "m4v"]
private let conversionVideoExtensions = ["webm", "mkv", "avi"]
private let imageExtensions = ["jpg", "jpeg", "png", "gif", "apng", "webp", "heic"]
private let preferredThumbnailNames = ["preview", "thumbnail", "thumb", "cover"]

private func entrypointSort(_ lhs: URL, _ rhs: URL, expectedKind: WallpaperKind?) -> Bool {
    let lhsRank = entrypointRank(lhs, expectedKind: expectedKind)
    let rhsRank = entrypointRank(rhs, expectedKind: expectedKind)
    if lhsRank != rhsRank {
        return lhsRank < rhsRank
    }
    return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
}

private func entrypointRank(_ url: URL, expectedKind: WallpaperKind?) -> Int {
    let ext = url.pathExtension.lowercased()
    switch expectedKind {
    case .video where playableVideoExtensions.contains(ext): return 0
    case .video where conversionVideoExtensions.contains(ext): return 1
    case .web where ext == "html" || ext == "htm": return 0
    case .image where imageExtensions.contains(ext): return 0
    case .scene where ext == "pkg": return 0
    case .video, .web, .image, .scene: return 2
    case .application, .unknown, nil: break
    }
    if playableVideoExtensions.contains(ext) { return 0 }
    if conversionVideoExtensions.contains(ext) { return 1 }
    if ext == "html" || ext == "htm" { return 2 }
    if imageExtensions.contains(ext) { return 3 }
    if ext == "pkg" { return 4 }
    return 5
}

private func dateAddedSort(_ lhs: WallpaperAsset, _ rhs: WallpaperAsset) -> Bool {
    switch (lhs.dateAdded, rhs.dateAdded) {
    case let (left?, right?) where left != right:
        return left > right
    case (_?, nil):
        return true
    case (nil, _?):
        return false
    default:
        return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
    }
}

private func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
}

private func isRegularFile(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
