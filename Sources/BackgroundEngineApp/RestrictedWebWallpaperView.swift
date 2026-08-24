import AppKit
import BackgroundEngineCore
import Darwin
import PlashRuntime
import WebKit

enum WebWallpaperPropertyValue: Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case text(String)

    var jsonObject: Any {
        switch self {
        case .bool(let value): value
        case .number(let value): value
        case .text(let value): value
        }
    }

    var persistedOverride: WebWallpaperPropertyOverrideValue {
        switch self {
        case .bool(let value): .bool(value)
        case .number(let value): .number(value)
        case .text(let value): .text(value)
        }
    }

    init(_ override: WebWallpaperPropertyOverrideValue) {
        switch override {
        case .bool(let value): self = .bool(value)
        case .number(let value): self = .number(value)
        case .text(let value): self = .text(value)
        }
    }
}

enum WebWallpaperCompatibilityBridge {
    enum EditablePropertyKind: String, Equatable, Sendable {
        case bool
        case slider
        case color
        case combo
        case text
    }

    struct ComboOption: Identifiable, Equatable, Sendable {
        let label: String
        let value: String
        var id: String { value }
    }

    struct EditableProperty: Identifiable, Equatable, Sendable {
        let name: String
        let label: String
        let kind: EditablePropertyKind
        let defaultValue: WebWallpaperPropertyValue
        let currentValue: WebWallpaperPropertyValue
        let minimum: Double?
        let maximum: Double?
        let step: Double?
        let options: [ComboOption]
        let order: Double
        var id: String { name }
    }

    enum DirectoryMode: String, Equatable, Sendable {
        case onDemand = "ondemand"
        case fetchAll = "fetchall"
    }

    struct DirectoryPropertyFiles: Equatable, Sendable {
        let mode: DirectoryMode
        let files: [String]
    }

    struct FileProperty: Identifiable, Equatable {
        let name: String
        let selectsDirectory: Bool
        var id: String { name }
    }

    static func defaultProperties(projectRoot: URL) -> [String: WebWallpaperPropertyValue] {
        guard let rawProperties = rawProperties(projectRoot: projectRoot) else {
            return [:]
        }
        let scalarOverrides = valueOverrides(projectRoot: projectRoot)
        var properties = rawProperties.reduce(into: [String: WebWallpaperPropertyValue]()) { result, item in
            guard let descriptor = item.value as? [String: Any],
                  let type = descriptor["type"] as? String,
                  let value = descriptor["value"],
                  let defaultProperty = propertyValue(type: type, value: value) else {
                return
            }
            if let override = scalarOverrides[item.key],
               let property = propertyValue(type: type, override: override) {
                result[item.key] = property
            } else {
                result[item.key] = defaultProperty
            }
        }
        if let overridesURL = auxiliaryMetadataURL(
            named: WebWallpaperUserFileStore.overridesFileName,
            projectRoot: projectRoot
        ), let data = WebWallpaperMetadataFileReader.data(
            at: overridesURL,
            maximumByteCount: WebWallpaperMetadataFileReader.maximumAuxiliaryMetadataBytes
        ),
           let overrides = try? JSONDecoder().decode([String: String].self, from: data) {
            for (name, relativePath) in overrides {
                guard let descriptor = rawProperties[name] as? [String: Any],
                      let type = (descriptor["type"] as? String)?.lowercased(),
                      type == "file" || type == "directory" else {
                    continue
                }
                let candidate = projectRoot.appending(path: relativePath).standardizedFileURL
                let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
                let resolved = candidate.resolvingSymlinksInPath()
                guard resolved.pathComponents.starts(with: root.pathComponents),
                      resolved.pathComponents.count > root.pathComponents.count else { continue }
                properties[name] = .text(candidate.path)
            }
        }
        return properties
    }

    static func editableProperties(projectRoot: URL) -> [EditableProperty] {
        guard let rawProperties = rawProperties(projectRoot: projectRoot) else { return [] }
        let scalarOverrides = valueOverrides(projectRoot: projectRoot)
        return rawProperties.compactMap { name, value -> EditableProperty? in
            guard let descriptor = value as? [String: Any],
                  let type = (descriptor["type"] as? String)?.lowercased(),
                  let rawDefault = descriptor["value"],
                  let defaultValue = propertyValue(type: type, value: rawDefault),
                  let kind = editableKind(type: type) else {
                return nil
            }
            let currentValue = scalarOverrides[name]
                .flatMap { propertyValue(type: type, override: $0) }
                ?? defaultValue
            let minimum = finiteNumber(descriptor["min"])
            let maximum = finiteNumber(descriptor["max"])
            let step = finiteNumber(descriptor["step"])
            let options: [ComboOption]
            if kind == .combo {
                options = (descriptor["options"] as? [[String: Any]] ?? []).compactMap { option in
                    guard let rawValue = option["value"] else { return nil }
                    let value = String(describing: rawValue)
                    let label = nonEmpty(option["label"] as? String) ?? value
                    return ComboOption(label: label, value: value)
                }
            } else {
                options = []
            }
            return EditableProperty(
                name: name,
                label: nonEmpty(descriptor["text"] as? String) ?? name,
                kind: kind,
                defaultValue: defaultValue,
                currentValue: currentValue,
                minimum: minimum,
                maximum: maximum,
                step: step,
                options: options,
                order: finiteNumber(descriptor["order"]) ?? Double.greatestFiniteMagnitude
            )
        }.sorted {
            if $0.order == $1.order {
                return $0.label.localizedStandardCompare($1.label) == .orderedAscending
            }
            return $0.order < $1.order
        }
    }

    /// Returns only well-typed values that differ from the wallpaper author's
    /// defaults. Keeping defaults out of persisted metadata means Reset keeps
    /// following new defaults after a Workshop update.
    static func persistedOverrides(
        _ values: [String: WebWallpaperPropertyValue],
        properties: [EditableProperty]
    ) -> [String: WebWallpaperPropertyOverrideValue] {
        properties.reduce(into: [:]) { result, property in
            guard let value = values[property.name],
                  value != property.defaultValue,
                  isCompatible(value, with: property.kind) else {
                return
            }
            result[property.name] = value.persistedOverride
        }
    }

    static func comboDisplayTexts(projectRoot: URL) -> [String: String] {
        editableProperties(projectRoot: projectRoot).reduce(into: [:]) { result, property in
            guard property.kind == .combo,
                  case .text(let selectedValue) = property.currentValue else {
                return
            }
            result[property.name] = property.options.first(where: {
                $0.value == selectedValue
            })?.label ?? selectedValue
        }
    }

    static func fileProperties(projectRoot: URL) -> [FileProperty] {
        guard let raw = rawProperties(projectRoot: projectRoot) else {
            return []
        }
        return raw.compactMap { name, value in
            guard let descriptor = value as? [String: Any],
                  let type = (descriptor["type"] as? String)?.lowercased(),
                  type == "file" || type == "directory" else { return nil }
            return FileProperty(name: name, selectsDirectory: type == "directory")
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func directoryProperties(projectRoot: URL) -> [String: DirectoryPropertyFiles] {
        guard let raw = rawProperties(projectRoot: projectRoot) else {
            return [:]
        }
        let overrides: [String: String]
        if let overridesURL = auxiliaryMetadataURL(
            named: WebWallpaperUserFileStore.overridesFileName,
            projectRoot: projectRoot
        ), let data = WebWallpaperMetadataFileReader.data(
            at: overridesURL,
            maximumByteCount: WebWallpaperMetadataFileReader.maximumAuxiliaryMetadataBytes
        ),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            overrides = decoded
        } else {
            overrides = [:]
        }

        return raw.reduce(into: [String: DirectoryPropertyFiles]()) { result, item in
            guard let descriptor = item.value as? [String: Any],
                  (descriptor["type"] as? String)?.lowercased() == "directory" else {
                return
            }
            let mode = (descriptor["mode"] as? String)?.lowercased() == DirectoryMode.fetchAll.rawValue
                ? DirectoryMode.fetchAll
                : DirectoryMode.onDemand
            let allowedExtensions = (descriptor["fileType"] as? String)?.lowercased() == "video"
                ? videoDirectoryExtensions
                : imageDirectoryExtensions
            let files: [String]
            if let relativePath = overrides[item.key],
               let directory = safeOverride(relativePath, projectRoot: projectRoot),
               (try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
                .map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true {
                files = safeRegularFiles(
                    in: directory,
                    projectRoot: projectRoot,
                    allowedExtensions: allowedExtensions
                )
            } else {
                files = []
            }
            result[item.key] = DirectoryPropertyFiles(mode: mode, files: files)
        }
    }

    private static func projectMetadata(projectRoot: URL) -> [String: Any]? {
        let projectJSON = projectRoot.appending(path: "project.json")
        guard let data = WebWallpaperMetadataFileReader.data(
            at: projectJSON,
            maximumByteCount: WebWallpaperMetadataFileReader.maximumProjectMetadataBytes
        ) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func rawProperties(projectRoot: URL) -> [String: Any]? {
        guard let root = projectMetadata(projectRoot: projectRoot) else { return nil }
        let general = root["general"] as? [String: Any]
        return (general?["properties"] as? [String: Any])
            ?? (root["properties"] as? [String: Any])
            ?? [:]
    }

    private static func valueOverrides(
        projectRoot: URL
    ) -> [String: WebWallpaperPropertyOverrideValue] {
        guard let url = auxiliaryMetadataURL(
            named: WebWallpaperUserFileStore.valueOverridesFileName,
            projectRoot: projectRoot
        ), let data = WebWallpaperMetadataFileReader.data(
            at: url,
            maximumByteCount: WebWallpaperMetadataFileReader.maximumAuxiliaryMetadataBytes
        ), let decoded = try? JSONDecoder().decode(
            [String: WebWallpaperPropertyOverrideValue].self,
            from: data
        ) else {
            return [:]
        }
        guard decoded.count <= WebWallpaperUserFileStore.maximumScalarProperties,
              decoded.allSatisfy({ name, value in
                  let nameBytes = name.lengthOfBytes(using: .utf8)
                  guard !name.isEmpty,
                        !name.contains("\0"),
                        nameBytes <= WebWallpaperUserFileStore.maximumPropertyNameBytes else {
                      return false
                  }
                  switch value {
                  case .bool:
                      return true
                  case .number(let number):
                      return number.isFinite
                  case .text(let text):
                      return text.lengthOfBytes(using: .utf8)
                          <= WebWallpaperUserFileStore.maximumTextValueBytes
                  }
              }) else {
            return [:]
        }
        return decoded
    }

    private static func auxiliaryMetadataURL(named name: String, projectRoot: URL) -> URL? {
        let storageRoot = projectRoot.appending(path: WebWallpaperUserFileStore.directoryName)
        var attributes = stat()
        let metadataStatus = storageRoot.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &attributes)
        }
        guard metadataStatus == 0, attributes.st_mode & S_IFMT == S_IFDIR else { return nil }
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedStorage = storageRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedStorage.pathComponents.starts(with: root.pathComponents),
              resolvedStorage.pathComponents.count == root.pathComponents.count + 1 else {
            return nil
        }
        return storageRoot.appending(path: name)
    }

    static func bootstrapScript(
        properties: [String: WebWallpaperPropertyValue],
        comboDisplayTexts: [String: String] = [:],
        directories: [String: DirectoryPropertyFiles] = [:],
        framesPerSecond: Int = 30
    ) -> String {
        let payload: [String: [String: Any]] = properties.reduce(into: [:]) { result, item in
            var property: [String: Any] = ["value": item.value.jsonObject]
            if let text = comboDisplayTexts[item.key] {
                property["text"] = text
            }
            result[item.key] = property
        }
        let propertyJSON = jsonString(payload)
        let directoryPayload = directories.mapValues {
            ["mode": $0.mode.rawValue, "files": $0.files] as [String: Any]
        }
        let directoryJSON = jsonString(directoryPayload)
        let generalJSON = jsonString(["fps": max(1, framesPerSecond)])
        return #"""
        (() => {
          'use strict';
          const userProperties = \#(propertyJSON);
          const directoryProperties = \#(directoryJSON);
          const fetchAllProperties = new Set(
            Object.entries(directoryProperties)
              .filter(([, property]) => property.mode === 'fetchall')
              .map(([name]) => name)
          );
          for (const name of fetchAllProperties) delete userProperties[name];
          const generalProperties = \#(generalJSON);
          let neutralAudioTimer = null;
          let currentPausedState = false;
          let lastAppliedListener = null;
          let propertyListenerValue = window.wallpaperPropertyListener || null;
          const isDOMReady = () => typeof document === 'undefined' || document.readyState !== 'loading';
          const safelyInvoke = (listener, callback, argumentsList) => {
            if (typeof callback !== 'function') return true;
            try {
              callback.apply(listener, argumentsList);
              return true;
            } catch (_) {
              return false;
            }
          };
          const playbackState = Object.freeze({ PLAYING: 0, PAUSED: 1, STOPPED: 2 });
          window.wallpaperMediaIntegration = Object.freeze({
            PLAYBACK_PLAYING: playbackState.PLAYING,
            PLAYBACK_PAUSED: playbackState.PAUSED,
            PLAYBACK_STOPPED: playbackState.STOPPED,
            playback: playbackState
          });
          const registerNeutralMediaListener = (listener, event) => {
            if (typeof listener !== 'function') return;
            window.setTimeout(() => safelyInvoke(window, listener, [event]), 0);
          };
          window.wallpaperRegisterMediaStatusListener = (listener) => {
            registerNeutralMediaListener(listener, { enabled: false });
          };
          window.wallpaperRegisterMediaPropertiesListener = (listener) => {
            registerNeutralMediaListener(listener, {
              title: '', artist: '', subTitle: '', albumTitle: '', albumArtist: '',
              genres: '', contentType: ''
            });
          };
          window.wallpaperRegisterMediaThumbnailListener = (listener) => {
            registerNeutralMediaListener(listener, {
              thumbnail: '', primaryColor: '#000000', secondaryColor: '#000000',
              tertiaryColor: '#000000', textColor: '#FFFFFF', highContrastColor: '#FFFFFF'
            });
          };
          window.wallpaperRegisterMediaPlaybackListener = (listener) => {
            registerNeutralMediaListener(listener, {
              state: window.wallpaperMediaIntegration.PLAYBACK_STOPPED
            });
          };
          window.wallpaperRegisterMediaTimelineListener = (listener) => {
            registerNeutralMediaListener(listener, { position: 0, duration: 0 });
          };
          window.wallpaperRegisterAudioListener = (listener) => {
            if (neutralAudioTimer !== null) window.clearInterval(neutralAudioTimer);
            if (typeof listener !== 'function') return;
            const neutral = new Array(128).fill(0);
            if (!currentPausedState) listener(neutral);
            neutralAudioTimer = window.setInterval(() => {
              if (!currentPausedState) listener(neutral);
            }, 1000 / 30);
          };
          window.wallpaperRequestRandomFileForProperty = (propertyName, callback) => {
            const property = directoryProperties[propertyName];
            if (typeof callback !== 'function' || !property || property.mode !== 'ondemand') return;
            const files = property.files || [];
            const selected = files.length > 0
              ? files[Math.floor(Math.random() * files.length)]
              : '';
            callback(propertyName, selected);
          };
          const applyProperties = () => {
            if (!isDOMReady()) return false;
            const listener = window.wallpaperPropertyListener;
            if (!listener) return false;
            if (listener === lastAppliedListener) return true;
            const hasSupportedCallback = [
              listener.applyUserProperties,
              listener.applyGeneralProperties,
              listener.userDirectoryFilesAddedOrChanged,
              listener.setPaused
            ].some((callback) => typeof callback === 'function');
            if (!hasSupportedCallback) return false;
            let delivered = safelyInvoke(listener, listener.applyUserProperties, [userProperties]);
            delivered = safelyInvoke(listener, listener.applyGeneralProperties, [generalProperties]) && delivered;
            if (typeof listener.userDirectoryFilesAddedOrChanged === 'function') {
              for (const name of fetchAllProperties) {
                delivered = safelyInvoke(
                  listener,
                  listener.userDirectoryFilesAddedOrChanged,
                  [name, directoryProperties[name].files || []]
                ) && delivered;
              }
            }
            delivered = safelyInvoke(listener, listener.setPaused, [currentPausedState]) && delivered;
            if (delivered) lastAppliedListener = listener;
            return delivered;
          };
          const installPropertyListenerHook = () => {
            const descriptor = Object.getOwnPropertyDescriptor(window, 'wallpaperPropertyListener');
            if (descriptor && descriptor.configurable === false) return;
            Object.defineProperty(window, 'wallpaperPropertyListener', {
              configurable: true,
              enumerable: true,
              get: () => propertyListenerValue,
              set: (listener) => {
                propertyListenerValue = listener;
                lastAppliedListener = null;
                window.setTimeout(applyProperties, 0);
              }
            });
          };
          installPropertyListenerHook();
          window.__backgroundEngineSetPaused = (paused) => {
            currentPausedState = Boolean(paused);
            if (!isDOMReady()) return;
            const listener = window.wallpaperPropertyListener;
            if (listener) safelyInvoke(listener, listener.setPaused, [currentPausedState]);
          };
          window.addEventListener('DOMContentLoaded', applyProperties, { once: true });
          let listenerProbeAttempts = 0;
          const probeForListener = () => {
            applyProperties();
            listenerProbeAttempts += 1;
            if (listenerProbeAttempts < 100) window.setTimeout(probeForListener, 100);
          };
          window.setTimeout(probeForListener, 0);
        })();
        """#
    }

    private static func propertyValue(type: String, value: Any) -> WebWallpaperPropertyValue? {
        switch type.lowercased() {
        case "bool", "boolean":
            if let bool = value as? Bool { return .bool(bool) }
            if let number = value as? NSNumber { return .bool(number.boolValue) }
            if let string = value as? String { return .bool(["1", "true", "yes"].contains(string.lowercased())) }
        case "slider":
            if let number = value as? NSNumber { return .number(number.doubleValue) }
            if let string = value as? String, let number = Double(string) { return .number(number) }
        case "color", "combo", "text", "textinput", "file", "directory":
            if let string = value as? String { return .text(string) }
        default:
            return nil
        }
        return nil
    }

    private static func propertyValue(
        type: String,
        override: WebWallpaperPropertyOverrideValue
    ) -> WebWallpaperPropertyValue? {
        switch (type.lowercased(), override) {
        case ("bool", .bool(let value)), ("boolean", .bool(let value)):
            return .bool(value)
        case ("slider", .number(let value)) where value.isFinite:
            return .number(value)
        case ("color", .text(let value)),
             ("combo", .text(let value)),
             ("text", .text(let value)),
             ("textinput", .text(let value)):
            return .text(value)
        default:
            return nil
        }
    }

    private static func editableKind(type: String) -> EditablePropertyKind? {
        switch type.lowercased() {
        case "bool", "boolean": .bool
        case "slider": .slider
        case "color": .color
        case "combo": .combo
        case "text", "textinput": .text
        default: nil
        }
    }

    private static func isCompatible(
        _ value: WebWallpaperPropertyValue,
        with kind: EditablePropertyKind
    ) -> Bool {
        switch (kind, value) {
        case (.bool, .bool):
            true
        case (.slider, .number(let number)):
            number.isFinite
        case (.color, .text), (.combo, .text), (.text, .text):
            true
        default:
            false
        }
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        let number: Double?
        if let value = value as? NSNumber {
            number = value.doubleValue
        } else if let value = value as? String {
            number = Double(value)
        } else {
            number = nil
        }
        guard let number, number.isFinite else { return nil }
        return number
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func jsonString(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
            .replacingOccurrences(of: "</", with: "<\\/")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    private static func safeOverride(_ relativePath: String, projectRoot: URL) -> URL? {
        let candidate = projectRoot.appending(path: relativePath).standardizedFileURL
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = candidate.resolvingSymlinksInPath()
        guard resolved.pathComponents.starts(with: root.pathComponents),
              resolved.pathComponents.count > root.pathComponents.count else {
            return nil
        }
        return candidate
    }

    private static let imageDirectoryExtensions: Set<String> = [
        "jpeg", "jpg", "png", "pnga", "bmp", "gif", "svg", "webp"
    ]
    private static let videoDirectoryExtensions: Set<String> = ["webm", "ogg", "ogv"]

    private static func safeRegularFiles(
        in directory: URL,
        projectRoot: URL,
        allowedExtensions: Set<String>
    ) -> [String] {
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }
        var files: [String] = []
        for case let candidate as URL in enumerator {
            guard files.count < 2_000 else { break }
            guard let values = try? candidate.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
            ) else {
                continue
            }
            if candidate.lastPathComponent.hasPrefix(".") {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true,
                  allowedExtensions.contains(candidate.pathExtension.lowercased()) else {
                continue
            }
            let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.pathComponents.starts(with: root.pathComponents),
                  resolved.pathComponents.count > root.pathComponents.count else {
                continue
            }
            files.append(candidate.path)
        }
        return files.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

enum RestrictedWebNavigationPolicy {
    static func allows(
        _ candidate: URL?,
        projectRoot: URL,
        isMainFrame: Bool,
        networkAccessAllowed: Bool,
        isDownload: Bool = false,
        trustedLocalMainFrameURL: URL? = nil,
        trustedRemoteMainFrameURL: URL? = nil
    ) -> Bool {
        guard !isDownload, let candidate else { return false }
        guard candidate.user == nil, candidate.password == nil else { return false }
        if candidate.isFileURL {
            guard candidate.host?.isEmpty ?? true else { return false }
            let rootComponents = projectRoot.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            let candidateComponents = candidate.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            guard candidateComponents.count > rootComponents.count,
                  Array(candidateComponents.prefix(rootComponents.count)) == rootComponents else {
                return false
            }
            guard isMainFrame else { return true }
            guard let trustedLocalMainFrameURL else { return false }
            return candidate.standardizedFileURL.resolvingSymlinksInPath().path
                == trustedLocalMainFrameURL.standardizedFileURL.resolvingSymlinksInPath().path
        }
        guard networkAccessAllowed,
              ["https", "http"].contains(candidate.scheme?.lowercased() ?? "") else {
            return false
        }
        guard isMainFrame else { return true }
        guard let trustedRemoteMainFrameURL else { return false }
        return sameRemoteOrigin(candidate, trustedRemoteMainFrameURL)
    }

    /// Applies the same project-root/origin boundary to the response that
    /// WebKit is about to commit. Redirects can change the final URL after an
    /// earlier navigation action was approved, so checking only the action
    /// would allow a trusted remote wallpaper to escape to another origin.
    static func allowsResponse(
        _ candidate: URL?,
        projectRoot: URL,
        isMainFrame: Bool,
        networkAccessAllowed: Bool,
        canShowMIMEType: Bool,
        trustedLocalMainFrameURL: URL? = nil,
        trustedRemoteMainFrameURL: URL? = nil
    ) -> Bool {
        canShowMIMEType && allows(
            candidate,
            projectRoot: projectRoot,
            isMainFrame: isMainFrame,
            networkAccessAllowed: networkAccessAllowed,
            trustedLocalMainFrameURL: trustedLocalMainFrameURL,
            trustedRemoteMainFrameURL: trustedRemoteMainFrameURL
        )
    }

    private static func sameRemoteOrigin(_ candidate: URL, _ trusted: URL) -> Bool {
        guard candidate.user == nil,
              candidate.password == nil,
              trusted.user == nil,
              trusted.password == nil else {
            return false
        }
        let candidateScheme = candidate.scheme?.lowercased()
        let trustedScheme = trusted.scheme?.lowercased()
        guard let candidateHost = candidate.host?.lowercased(),
              let trustedHost = trusted.host?.lowercased(),
              let candidateScheme,
              let trustedScheme else {
            return false
        }
        return candidateScheme == trustedScheme
            && candidateHost == trustedHost
            && effectivePort(candidate) == effectivePort(trusted)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}

@MainActor
final class RestrictedWebWallpaperView: NSView,
    WKNavigationDelegate,
    PausableWallpaperContent,
    WallpaperContentLifecycle {
    private let webView: PlashWebView
    private let url: URL
    private let readAccessURL: URL
    private let networkAccessAllowed: Bool
    private let remoteConfiguration: RemoteWebWallpaperConfiguration?
    private var failureLabel: NSTextField?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryBudgetResetTask: Task<Void, Never>?
    private var recoveryAttempts = 0
    private var isSuspended = false
    private var isClosed = false

    init(url: URL, readAccessURL: URL, frame: CGRect, networkAccessAllowed: Bool = false) {
        self.url = url
        self.readAccessURL = readAccessURL
        self.networkAccessAllowed = networkAccessAllowed
        remoteConfiguration = RemoteWebWallpaperConfiguration.load(projectRoot: readAccessURL)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "development"
        let configuration = PlashRuntime.makeConfiguration(
            applicationName: "Background Engine/\(version)",
            usesPersistentWebsiteData: false
        )
        let properties = WebWallpaperCompatibilityBridge.defaultProperties(projectRoot: readAccessURL)
        let comboDisplayTexts = WebWallpaperCompatibilityBridge.comboDisplayTexts(
            projectRoot: readAccessURL
        )
        let directories = WebWallpaperCompatibilityBridge.directoryProperties(projectRoot: readAccessURL)
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: WebWallpaperCompatibilityBridge.bootstrapScript(
                    properties: properties,
                    comboDisplayTexts: comboDisplayTexts,
                    directories: directories
                ),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        let plashWebView = PlashWebView(frame: frame, configuration: configuration)
        PlashRuntime.prepare(plashWebView)
        webView = plashWebView
        super.init(frame: frame)
        webView.navigationDelegate = self
        addSubview(webView)
        if networkAccessAllowed {
            loadProject()
        } else {
            installRemoteBlockerAndLoad()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        webView.frame = bounds
    }

    func setPlaybackSuspended(_ suspended: Bool) {
        isSuspended = suspended
        applyPlaybackSuspension()
    }

    func prepareForClose() {
        guard !isClosed else { return }
        isClosed = true
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryBudgetResetTask?.cancel()
        recoveryBudgetResetTask = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let allowed = RestrictedWebNavigationPolicy.allows(
            navigationAction.request.url,
            projectRoot: readAccessURL,
            isMainFrame: navigationAction.targetFrame?.isMainFrame != false,
            networkAccessAllowed: networkAccessAllowed,
            isDownload: navigationAction.shouldPerformDownload,
            trustedLocalMainFrameURL: remoteConfiguration == nil ? url : nil,
            trustedRemoteMainFrameURL: remoteConfiguration?.targetURL
        )
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        let allowed = RestrictedWebNavigationPolicy.allowsResponse(
            navigationResponse.response.url,
            projectRoot: readAccessURL,
            isMainFrame: navigationResponse.isForMainFrame,
            networkAccessAllowed: networkAccessAllowed,
            canShowMIMEType: navigationResponse.canShowMIMEType,
            trustedLocalMainFrameURL: remoteConfiguration == nil ? url : nil,
            trustedRemoteMainFrameURL: remoteConfiguration?.targetURL
        )
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showFailure("This Web wallpaper could not be loaded: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showFailure("This Web wallpaper could not be loaded: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        recoveryBudgetResetTask?.cancel()
        recoveryBudgetResetTask = nil
        if recoveryAttempts < 2 {
            showFailure("The Web wallpaper process stopped unexpectedly. Background Engine is retrying it.")
            scheduleProcessRecovery()
        } else {
            showFailure("The Web wallpaper stopped repeatedly. Replay it to try again.")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        failureLabel?.removeFromSuperview()
        failureLabel = nil
        applyPlaybackSuspension()
        scheduleRecoveryBudgetReset()
    }

    private func installRemoteBlockerAndLoad() {
        let rules = #"""
        [{"trigger":{"url-filter":"^https?://.*|^wss?://.*"},"action":{"type":"block"}}]
        """#
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "dev.3xhaust.Background Engine.BlockRemote",
            encodedContentRuleList: rules
        ) { [weak self] ruleList, error in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                guard error == nil, let ruleList else {
                    self.showFailure(
                        "Background Engine could not install the offline Web security rules. "
                            + "Enable network access for this wallpaper or replay it to retry."
                    )
                    return
                }
                self.webView.configuration.userContentController.add(ruleList)
                self.loadProject()
            }
        }
    }

    private func loadProject() {
        guard !isClosed else { return }
        if let remoteConfiguration {
            guard networkAccessAllowed else {
                showFailure("This website wallpaper requires external network access.")
                return
            }
            webView.load(URLRequest(
                url: remoteConfiguration.targetURL,
                cachePolicy: .reloadRevalidatingCacheData,
                timeoutInterval: 30
            ))
        } else {
            webView.loadFileURL(url, allowingReadAccessTo: readAccessURL)
        }
    }

    private func scheduleProcessRecovery() {
        guard !isClosed, recoveryAttempts < 2 else { return }
        recoveryAttempts += 1
        recoveryTask?.cancel()
        let delay = Duration.milliseconds(250 * recoveryAttempts)
        recoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, !self.isClosed else { return }
            self.recoveryTask = nil
            self.loadProject()
        }
    }

    private func applyPlaybackSuspension() {
        guard !isClosed else { return }
        webView.evaluateJavaScript(PlashRuntime.playbackScript(suspended: isSuspended))
    }

    private func scheduleRecoveryBudgetReset() {
        recoveryBudgetResetTask?.cancel()
        recoveryBudgetResetTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            guard let self, !Task.isCancelled, !self.isClosed else { return }
            self.recoveryAttempts = 0
            self.recoveryBudgetResetTask = nil
        }
    }

    private func showFailure(_ message: String) {
        failureLabel?.removeFromSuperview()
        let label = NSTextField(wrappingLabelWithString: message)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.7)
        ])
        failureLabel = label
    }

}
