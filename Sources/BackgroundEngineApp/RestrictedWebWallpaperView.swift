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

/// Keeps Web wallpaper audio inside Background Engine's global/per-display
/// routing. The script is injected at document start so autoplay cannot leak
/// audio while a navigation or WebContent process recovery is still loading.
enum WebWallpaperAudioBridge {
    static func bootstrapScript(controlToken: String) -> String {
        let tokenLiteral = javascriptStringLiteral(controlToken)
        return #"""
    (() => {
      if (window.__backgroundEngineApplyAudioPolicy) return;

      const NativeNumber = Number;
      const nativeNumberIsFinite = Number.isFinite;
      const NativeWeakMap = WeakMap;
      const NativePromise = Promise;
      const NativeMutationObserver = window.MutationObserver;
      const nativeReflectApply = Reflect.apply;
      const nativeReflectConstruct = Reflect.construct;
      const nativeDefineProperty = Object.defineProperty;
      const nativeGetOwnPropertyDescriptor = Object.getOwnPropertyDescriptor;
      const nativeSetPrototypeOf = Object.setPrototypeOf;
      const nativeIsPrototypeOf = Object.prototype.isPrototypeOf;
      const nativeWeakMapGet = WeakMap.prototype.get;
      const nativeWeakMapSet = WeakMap.prototype.set;
      const nativeWeakMapHas = WeakMap.prototype.has;
      const nativePromiseResolve = Promise.resolve;
      const nativePromiseThen = Promise.prototype.then;
      const invoke = (functionValue, receiver, argumentsList) =>
        nativeReflectApply(functionValue, receiver, argumentsList);
      const weakGet = (map, key) => invoke(nativeWeakMapGet, map, [key]);
      const weakSet = (map, key, value) => invoke(nativeWeakMapSet, map, [key, value]);
      const weakHas = (map, key) => invoke(nativeWeakMapHas, map, [key]);
      const resolvedPromise = value => invoke(nativePromiseResolve, NativePromise, [value]);
      const thenPromise = (promise, onFulfilled, onRejected) =>
        invoke(nativePromiseThen, promise, [onFulfilled, onRejected]);
      const nativeDocument = document;
      const NativeHTMLMediaElement = window.HTMLMediaElement;
      const mediaPrototype = NativeHTMLMediaElement && NativeHTMLMediaElement.prototype;
      const documentPrototype = window.Document && window.Document.prototype;
      const elementPrototype = window.Element && window.Element.prototype;
      const fragmentPrototype = window.DocumentFragment && window.DocumentFragment.prototype;
      const documentQuerySelectorAll = documentPrototype && documentPrototype.querySelectorAll;
      const elementQuerySelectorAll = elementPrototype && elementPrototype.querySelectorAll;
      const fragmentQuerySelectorAll = fragmentPrototype && fragmentPrototype.querySelectorAll;
      const audioParamPrototype = window.AudioParam && window.AudioParam.prototype;
      const nativeAudioParamValue = audioParamPrototype
        && nativeGetOwnPropertyDescriptor(audioParamPrototype, 'value');
      const setAudioParamValue = (parameter, value) => {
        if (nativeAudioParamValue && typeof nativeAudioParamValue.set === 'function') {
          invoke(nativeAudioParamValue.set, parameter, [value]);
        } else {
          parameter.value = value;
        }
      };
      const clamp = value => {
        const number = NativeNumber(value);
        if (!nativeNumberIsFinite(number) || number <= 0) return 0;
        return number >= 1 ? 1 : number;
      };
      const controlToken = \#(tokenLiteral);
      const gate = {
        enabled: false,
        volume: 0,
        suspended: false,
        media: [],
        mediaState: new NativeWeakMap(),
        contexts: [],
        contextState: new NativeWeakMap()
      };

      const nativeMuted = mediaPrototype && nativeGetOwnPropertyDescriptor(mediaPrototype, 'muted');
      const nativeVolume = mediaPrototype && nativeGetOwnPropertyDescriptor(mediaPrototype, 'volume');
      const nativePlay = mediaPrototype && mediaPrototype.play;

      const applyMedia = element => {
        const state = weakGet(gate.mediaState, element);
        if (!state) return;
        try {
          const canOutputAudio = gate.enabled && !gate.suspended;
          invoke(nativeMuted.set, element, [!canOutputAudio || state.muted]);
          invoke(
            nativeVolume.set,
            element,
            [canOutputAudio ? clamp(state.volume * gate.volume) : 0]
          );
        } catch (_) {}
      };
      const registerMedia = element => {
        if (!element || weakHas(gate.mediaState, element) || !nativeMuted || !nativeVolume) return;
        let muted = false;
        let volume = 1;
        try {
          muted = !!invoke(nativeMuted.get, element, []);
          volume = clamp(invoke(nativeVolume.get, element, []));
        } catch (_) {}
        weakSet(gate.mediaState, element, { muted, volume });
        gate.media[gate.media.length] = element;
        applyMedia(element);
      };
      const queryMediaElements = root => {
        try {
          if (root === nativeDocument && typeof documentQuerySelectorAll === 'function') {
            return invoke(documentQuerySelectorAll, root, ['audio,video']);
          }
          if (elementPrototype && invoke(nativeIsPrototypeOf, elementPrototype, [root])
              && typeof elementQuerySelectorAll === 'function') {
            return invoke(elementQuerySelectorAll, root, ['audio,video']);
          }
          if (fragmentPrototype && invoke(nativeIsPrototypeOf, fragmentPrototype, [root])
              && typeof fragmentQuerySelectorAll === 'function') {
            return invoke(fragmentQuerySelectorAll, root, ['audio,video']);
          }
          if (typeof root.querySelectorAll === 'function') return root.querySelectorAll('audio,video');
        } catch (_) {}
        return [];
      };
      const registerTree = root => {
        if (!root) return;
        if (mediaPrototype && invoke(nativeIsPrototypeOf, mediaPrototype, [root])) registerMedia(root);
        const mediaElements = queryMediaElements(root);
        for (let index = 0; index < mediaElements.length; index += 1) {
          registerMedia(mediaElements[index]);
        }
      };
      const applyAllMedia = () => {
        const retainedMedia = [];
        for (let index = 0; index < gate.media.length; index += 1) {
          const element = gate.media[index];
          if (!weakHas(gate.mediaState, element)) continue;
          applyMedia(element);
          retainedMedia[retainedMedia.length] = element;
        }
        gate.media = retainedMedia;
      };

      if (mediaPrototype && nativeMuted && nativeMuted.get && nativeMuted.set
          && nativeVolume && nativeVolume.get && nativeVolume.set) {
        try {
          nativeDefineProperty(mediaPrototype, 'muted', {
            configurable: false,
            enumerable: nativeMuted.enumerable,
            get() {
              const state = weakGet(gate.mediaState, this);
              return state ? state.muted : invoke(nativeMuted.get, this, []);
            },
            set(value) {
              registerMedia(this);
              const state = weakGet(gate.mediaState, this);
              if (state) state.muted = !!value;
              applyMedia(this);
            }
          });
        } catch (_) {}
        try {
          nativeDefineProperty(mediaPrototype, 'volume', {
            configurable: false,
            enumerable: nativeVolume.enumerable,
            get() {
              const state = weakGet(gate.mediaState, this);
              return state ? state.volume : invoke(nativeVolume.get, this, []);
            },
            set(value) {
              registerMedia(this);
              const state = weakGet(gate.mediaState, this);
              if (state) state.volume = clamp(value);
              applyMedia(this);
            }
          });
        } catch (_) {}
        if (typeof nativePlay === 'function') {
          try {
            nativeDefineProperty(mediaPrototype, 'play', {
              configurable: false,
              enumerable: false,
              writable: false,
              value: function(...argumentsList) {
                registerMedia(this);
                return invoke(nativePlay, this, argumentsList);
              }
            });
          } catch (_) {}
        }
      }

      const contextConstructors = [];
      if (window.AudioContext) contextConstructors[contextConstructors.length] = window.AudioContext;
      if (window.webkitAudioContext && window.webkitAudioContext !== window.AudioContext) {
        contextConstructors[contextConstructors.length] = window.webkitAudioContext;
      }
      for (let constructorIndex = 0;
          constructorIndex < contextConstructors.length;
          constructorIndex += 1) {
        const NativeContext = contextConstructors[constructorIndex];
        const contextPrototype = NativeContext.prototype;
        const nativeResume = contextPrototype.resume;
        const nativeSuspend = contextPrototype.suspend;
        const nativeClose = contextPrototype.close;
        const nativeCreateGain = contextPrototype.createGain;
        const audioNodePrototype = window.AudioNode && window.AudioNode.prototype;
        const nativeConnect = audioNodePrototype && audioNodePrototype.connect;

        const registerContext = context => {
          if (!context || weakHas(gate.contextState, context)) {
            return weakGet(gate.contextState, context);
          }
          const state = {
            desiredRunning: context.state === 'running',
            closed: false,
            gain: null,
            nativeResume,
            nativeSuspend,
            nativeClose,
            transition: resolvedPromise(),
            reconcile: null
          };
          state.reconcile = () => {
            const reconcile = () => {
                if (state.closed) return;
                const mustSuspend = gate.suspended || (!state.gain && !gate.enabled);
                const shouldRun = !mustSuspend && state.desiredRunning;
                try {
                  if (!shouldRun && context.state === 'running'
                      && typeof state.nativeSuspend === 'function') {
                    return invoke(state.nativeSuspend, context, []);
                  }
                  if (shouldRun && context.state === 'suspended'
                      && typeof state.nativeResume === 'function') {
                    return invoke(state.nativeResume, context, []);
                  }
                } catch (_) {}
              };
            state.transition = thenPromise(state.transition, reconcile, reconcile);
            return state.transition;
          };
          if (typeof nativeCreateGain === 'function' && typeof nativeConnect === 'function') {
            try {
              state.gain = invoke(nativeCreateGain, context, []);
              invoke(nativeConnect, state.gain, [context.destination]);
              setAudioParamValue(
                state.gain.gain,
                gate.enabled && !gate.suspended ? gate.volume : 0
              );
            } catch (_) {
              state.gain = null;
            }
          }
          weakSet(gate.contextState, context, state);
          gate.contexts[gate.contexts.length] = context;
          state.reconcile();
          return state;
        };

        if (typeof nativeResume === 'function') {
          const guardedResume = function(...argumentsList) {
            const state = registerContext(this);
            if (state) state.desiredRunning = true;
            return state ? state.reconcile() : invoke(nativeResume, this, argumentsList);
          };
          try {
            nativeDefineProperty(contextPrototype, 'resume', {
              configurable: false,
              enumerable: false,
              writable: false,
              value: guardedResume
            });
          } catch (_) {}
        }
        if (typeof nativeSuspend === 'function') {
          const guardedSuspend = function(...argumentsList) {
            const state = registerContext(this);
            if (state) state.desiredRunning = false;
            return state ? state.reconcile() : invoke(nativeSuspend, this, argumentsList);
          };
          try {
            nativeDefineProperty(contextPrototype, 'suspend', {
              configurable: false,
              enumerable: false,
              writable: false,
              value: guardedSuspend
            });
          } catch (_) {}
        }
        if (typeof nativeClose === 'function') {
          const guardedClose = function(...argumentsList) {
            const state = registerContext(this);
            if (state) {
              state.closed = true;
              state.desiredRunning = false;
              const close = () => invoke(nativeClose, this, argumentsList);
              state.transition = thenPromise(state.transition, close, close);
              return state.transition;
            }
            return invoke(nativeClose, this, argumentsList);
          };
          try {
            nativeDefineProperty(contextPrototype, 'close', {
              configurable: false,
              enumerable: false,
              writable: false,
              value: guardedClose
            });
          } catch (_) {}
        }

        if (audioNodePrototype && typeof nativeConnect === 'function'
            && !audioNodePrototype.__backgroundEngineConnectPatched) {
          const routedConnect = function(...argumentsList) {
            const destination = argumentsList[0];
            const context = this.context;
            const state = registerContext(context);
            if (state && state.gain && destination === context.destination && this !== state.gain) {
              argumentsList[0] = state.gain;
              invoke(nativeConnect, this, argumentsList);
              return destination;
            }
            return invoke(nativeConnect, this, argumentsList);
          };
          try {
            nativeDefineProperty(audioNodePrototype, '__backgroundEngineConnectPatched', {
              configurable: false,
              enumerable: false,
              value: true
            });
            nativeDefineProperty(audioNodePrototype, 'connect', {
              configurable: false,
              enumerable: false,
              writable: false,
              value: routedConnect
            });
          } catch (_) {}
        }

        function WrappedAudioContext(...argumentsList) {
          const context = nativeReflectConstruct(
            NativeContext,
            argumentsList,
            new.target || WrappedAudioContext
          );
          registerContext(context);
          return context;
        }
        nativeSetPrototypeOf(WrappedAudioContext, NativeContext);
        WrappedAudioContext.prototype = contextPrototype;
        if (window.AudioContext === NativeContext) {
          try {
            nativeDefineProperty(window, 'AudioContext', {
              configurable: false,
              enumerable: false,
              writable: false,
              value: WrappedAudioContext
            });
          } catch (_) {}
        }
        if (window.webkitAudioContext === NativeContext) {
          try {
            nativeDefineProperty(window, 'webkitAudioContext', {
              configurable: false,
              enumerable: false,
              writable: false,
              value: WrappedAudioContext
            });
          } catch (_) {}
        }
      }

      const applyContexts = () => {
        const retainedContexts = [];
        for (let index = 0; index < gate.contexts.length; index += 1) {
          const context = gate.contexts[index];
          const state = weakGet(gate.contextState, context);
          if (!state || state.closed) continue;
          if (state.gain) {
            try {
              setAudioParamValue(
                state.gain.gain,
                gate.enabled && !gate.suspended ? gate.volume : 0
              );
            } catch (_) {}
          }
          state.reconcile();
          retainedContexts[retainedContexts.length] = context;
        }
        gate.contexts = retainedContexts;
      };

      nativeDefineProperty(window, '__backgroundEngineApplyAudioPolicy', {
        configurable: false,
        enumerable: false,
        writable: false,
        value: (providedToken, enabled, volume) => {
          if (providedToken !== controlToken) return false;
          gate.enabled = enabled === true;
          gate.volume = clamp(volume);
          applyAllMedia();
          applyContexts();
          return true;
        }
      });
      nativeDefineProperty(window, '__backgroundEngineApplyAudioSuspension', {
        configurable: false,
        enumerable: false,
        writable: false,
        value: (providedToken, suspended) => {
          if (providedToken !== controlToken) return false;
          gate.suspended = suspended === true;
          applyAllMedia();
          applyContexts();
          return true;
        }
      });

      registerTree(nativeDocument);
      if (NativeMutationObserver && nativeDocument.documentElement) {
        const observer = nativeReflectConstruct(NativeMutationObserver, [records => {
          for (let recordIndex = 0; recordIndex < records.length; recordIndex += 1) {
            const addedNodes = records[recordIndex].addedNodes || [];
            for (let nodeIndex = 0; nodeIndex < addedNodes.length; nodeIndex += 1) {
              registerTree(addedNodes[nodeIndex]);
            }
          }
        }]);
        observer.observe(nativeDocument.documentElement, { childList: true, subtree: true });
      }
    })();
    """#
    }

    static func updateScript(controlToken: String, enabled: Bool, volume: Double) -> String {
        let safeVolume = min(max(volume.isFinite ? volume : 0, 0), 1)
        let tokenLiteral = javascriptStringLiteral(controlToken)
        return #"""
        (() => {
          const apply = frame => {
            try {
              if (typeof frame.__backgroundEngineApplyAudioPolicy === 'function') {
                frame.__backgroundEngineApplyAudioPolicy(
                  \#(tokenLiteral),
                  \#(enabled ? "true" : "false"),
                  \#(safeVolume)
                );
              }
              for (let index = 0; index < frame.frames.length; index += 1) apply(frame.frames[index]);
            } catch (_) {}
          };
          apply(window);
        })();
        """#
    }

    static func suspensionScript(controlToken: String, suspended: Bool) -> String {
        let tokenLiteral = javascriptStringLiteral(controlToken)
        return #"""
        (() => {
          const apply = frame => {
            try {
              if (typeof frame.__backgroundEngineApplyAudioSuspension === 'function') {
                frame.__backgroundEngineApplyAudioSuspension(
                  \#(tokenLiteral),
                  \#(suspended ? "true" : "false")
                );
              }
              for (let index = 0; index < frame.frames.length; index += 1) apply(frame.frames[index]);
            } catch (_) {}
          };
          apply(window);
        })();
        """#
    }

    private static func javascriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else {
            return #"""""#
        }
        return literal
    }
}

@MainActor
final class RestrictedWebWallpaperView: NSView,
    WKNavigationDelegate,
    PausableWallpaperContent,
    AudioControllableWallpaperContent,
    WallpaperContentLifecycle {
    private let webView: PlashWebView
    private let url: URL
    private let readAccessURL: URL
    private let networkAccessAllowed: Bool
    private let remoteConfiguration: RemoteWebWallpaperConfiguration?
    private let audioControlToken: String
    private var failureLabel: NSTextField?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryBudgetResetTask: Task<Void, Never>?
    private var nativeMediaSuspensionTask: Task<Void, Never>?
    private var nativeMediaSuspensionRequested = false
    private var recoveryAttempts = 0
    private var isSuspended = false
    private var isClosed = false
    private var audioEnabled: Bool
    private var audioVolume: Double

    init(
        url: URL,
        readAccessURL: URL,
        frame: CGRect,
        networkAccessAllowed: Bool = false,
        audioEnabled: Bool = false,
        audioVolume: Double = 0.5
    ) {
        self.url = url
        self.readAccessURL = readAccessURL
        self.networkAccessAllowed = networkAccessAllowed
        self.audioEnabled = audioEnabled
        self.audioVolume = min(max(audioVolume.isFinite ? audioVolume : 0, 0), 1)
        audioControlToken = UUID().uuidString
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
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: WebWallpaperAudioBridge.bootstrapScript(controlToken: audioControlToken),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
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

    func setAudioEnabled(_ enabled: Bool, volume: Double) {
        audioEnabled = enabled
        audioVolume = min(max(volume.isFinite ? volume : 0, 0), 1)
        applyAudioSettings()
    }

    func prepareForClose() {
        guard !isClosed else { return }
        audioEnabled = false
        isSuspended = true
        applyAudioSettings()
        applyPlaybackSuspension()
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
        applyAudioSettings()
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
        let suspended = isSuspended
        webView.evaluateJavaScript(
            "window.__backgroundEngineSetPaused?.(\(suspended ? "true" : "false"));"
        )
        if suspended {
            applyAudioSuspensionScript(true)
            enqueueNativeMediaSuspension(true)
        } else if nativeMediaSuspensionRequested {
            enqueueNativeMediaSuspension(false) { [weak self] in
                self?.applyAudioSuspensionScript(false)
            }
        } else {
            applyAudioSuspensionScript(false)
        }
    }

    private func applyAudioSuspensionScript(_ suspended: Bool) {
        guard !isClosed else { return }
        webView.evaluateJavaScript(
            WebWallpaperAudioBridge.suspensionScript(
                controlToken: audioControlToken,
                suspended: suspended
            )
        )
    }

    private func enqueueNativeMediaSuspension(
        _ suspended: Bool,
        completion: (@MainActor () -> Void)? = nil
    ) {
        guard nativeMediaSuspensionRequested != suspended else {
            completion?()
            return
        }
        let previousTask = nativeMediaSuspensionTask
        previousTask?.cancel()
        nativeMediaSuspensionRequested = suspended
        let webView = webView
        nativeMediaSuspensionTask = Task { @MainActor [weak self] in
            await previousTask?.value
            guard !Task.isCancelled else { return }
            await webView.setAllMediaPlaybackSuspended(suspended)
            guard !Task.isCancelled,
                  self?.nativeMediaSuspensionRequested == suspended else { return }
            completion?()
        }
    }

    private func applyAudioSettings() {
        guard !isClosed else { return }
        webView.evaluateJavaScript(
            WebWallpaperAudioBridge.updateScript(
                controlToken: audioControlToken,
                enabled: audioEnabled,
                volume: audioVolume
            )
        )
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
