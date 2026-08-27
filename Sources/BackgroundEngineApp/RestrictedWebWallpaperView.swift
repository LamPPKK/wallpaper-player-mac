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

enum WebWallpaperButtonTarget: String, Equatable, Sendable {
    case lively
    case wallpaperEngine
}

/// A validated, momentary Web-property action. Buttons deliberately have no
/// stored value: Lively and Wallpaper Engine both treat a click as a one-shot
/// `true` event delivered only to currently running wallpaper instances.
struct WebWallpaperButtonEvent: Equatable, Sendable {
    let propertyName: String
    let target: WebWallpaperButtonTarget

    init?(propertyName: String, target: WebWallpaperButtonTarget) {
        let byteCount = propertyName.lengthOfBytes(using: .utf8)
        guard !propertyName.isEmpty,
              !propertyName.contains("\0"),
              byteCount <= WebWallpaperUserFileStore.maximumPropertyNameBytes else {
            return nil
        }
        self.propertyName = propertyName
        self.target = target
    }
}

enum WebWallpaperButtonEventScript {
    /// The only script admitted by the native button path. The caller supplies
    /// data, never executable JavaScript; JSONEncoder provides the string
    /// literal so quotes, line separators, and backslashes cannot escape it.
    static func source(
        for event: WebWallpaperButtonEvent,
        deliveryID: String = UUID().uuidString
    ) -> String {
        let name = javascriptStringLiteral(event.propertyName)
        let identifier = javascriptStringLiteral(deliveryID)
        switch event.target {
        case .lively:
            return #"""
            (() => {
              'use strict';
              const deliveryID = \#(identifier);
              let delivered = window.__backgroundEngineDeliveredButtonEvents;
              if (!(delivered instanceof Set)) {
                try {
                  delivered = new Set();
                  Object.defineProperty(window, '__backgroundEngineDeliveredButtonEvents', {
                    configurable: false, enumerable: false, writable: false, value: delivered
                  });
                } catch (_) {
                  return false;
                }
              }
              if (delivered.has(deliveryID)) return true;
              const listener = window.livelyPropertyListener;
              if (typeof listener !== 'function') return false;
              try {
                listener.call(window, \#(name), true);
                delivered.add(deliveryID);
                return true;
              } catch (_) {
                return false;
              }
            })();
            """#
        case .wallpaperEngine:
            return #"""
            (() => {
              'use strict';
              const deliveryID = \#(identifier);
              let delivered = window.__backgroundEngineDeliveredButtonEvents;
              if (!(delivered instanceof Set)) {
                try {
                  delivered = new Set();
                  Object.defineProperty(window, '__backgroundEngineDeliveredButtonEvents', {
                    configurable: false, enumerable: false, writable: false, value: delivered
                  });
                } catch (_) {
                  return false;
                }
              }
              if (delivered.has(deliveryID)) return true;
              const listener = window.wallpaperPropertyListener;
              if (!listener || typeof listener.applyUserProperties !== 'function') return false;
              try {
                const name = \#(name);
                listener.applyUserProperties({ [name]: { value: true } });
                delivered.add(deliveryID);
                return true;
              } catch (_) {
                return false;
              }
            })();
            """#
        }
    }

    private static func javascriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else {
            return #"""""#
        }
        return literal
    }
}

enum WebWallpaperCompatibilityBridge {
    private static let livelyTypeKey = "backgroundEngineLivelyType"

    enum EditablePropertyKind: String, Equatable, Sendable {
        case bool
        case slider
        case color
        case combo
        case text
        case button
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
        let buttonTitle: String?
        let buttonEvent: WebWallpaperButtonEvent?
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
                  let kind = editableKind(type: type) else {
                return nil
            }
            let defaultValue: WebWallpaperPropertyValue
            let currentValue: WebWallpaperPropertyValue
            let buttonEvent: WebWallpaperButtonEvent?
            let buttonTitle: String?
            if kind == .button {
                let target: WebWallpaperButtonTarget =
                    (descriptor[livelyTypeKey] as? String)?.lowercased() == "button"
                        ? .lively
                        : .wallpaperEngine
                guard let event = WebWallpaperButtonEvent(propertyName: name, target: target) else {
                    return nil
                }
                defaultValue = .bool(false)
                currentValue = .bool(false)
                buttonEvent = event
                if target == .lively {
                    buttonTitle = nonEmpty(descriptor["value"] as? String)
                        ?? nonEmpty(descriptor["text"] as? String)
                        ?? name
                } else {
                    buttonTitle = nonEmpty(descriptor["text"] as? String)
                        ?? nonEmpty(descriptor["value"] as? String)
                        ?? name
                }
            } else {
                guard let rawDefault = descriptor["value"],
                      let parsedDefault = propertyValue(type: type, value: rawDefault) else {
                    return nil
                }
                defaultValue = parsedDefault
                currentValue = scalarOverrides[name]
                    .flatMap { propertyValue(type: type, override: $0) }
                    ?? parsedDefault
                buttonEvent = nil
                buttonTitle = nil
            }
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
                buttonTitle: buttonTitle,
                buttonEvent: buttonEvent,
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

    /// Lively and Wallpaper Engine use different callback types for dropdowns:
    /// Lively sends a numeric array index while Wallpaper Engine combo values
    /// are strings. Imported Lively properties carry a private marker so the
    /// two callback payloads can coexist without changing generic combo data.
    static func livelyCallbackProperties(
        projectRoot: URL,
        mappedValues: [String: WebWallpaperPropertyValue]
    ) -> [String: Any] {
        guard let raw = rawProperties(projectRoot: projectRoot) else { return [:] }
        // Local file overrides are absolute paths before the loopback bridge
        // maps them to the display session's private virtual origin. Callers
        // constructing a WebView must pass those mapped values so the Lively
        // callback neither leaks a host path nor receives an unusable URL.
        return raw.reduce(into: [String: Any]()) { result, item in
            guard let descriptor = item.value as? [String: Any],
                  let value = mappedValues[item.key] else {
                return
            }
            switch (descriptor[livelyTypeKey] as? String)?.lowercased() {
            case "dropdown":
                guard case .text(let selected) = value,
                      let index = Int(selected),
                      String(index) == selected,
                      comboOptionValues(descriptor).contains(selected) else {
                    return
                }
                result[item.key] = index
            case "folderdropdown":
                guard case .text(let selected) = value,
                      !selected.isEmpty,
                      comboOptionValues(descriptor).contains(selected) else {
                    result[item.key] = NSNull()
                    return
                }
                result[item.key] = selected
            default:
                result[item.key] = value.jsonObject
            }
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
        livelyProperties: [String: Any]? = nil,
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
        let livelyPropertyJSON = jsonString(
            livelyProperties ?? properties.mapValues(\.jsonObject)
        )
        let directoryPayload = directories.mapValues {
            ["mode": $0.mode.rawValue, "files": $0.files] as [String: Any]
        }
        let directoryJSON = jsonString(directoryPayload)
        let generalJSON = jsonString(["fps": max(1, framesPerSecond)])
        return #"""
        (() => {
          'use strict';
          const userProperties = \#(propertyJSON);
          const livelyUserProperties = \#(livelyPropertyJSON);
          const directoryProperties = \#(directoryJSON);
          const fetchAllProperties = new Set(
            Object.entries(directoryProperties)
              .filter(([, property]) => property.mode === 'fetchall')
              .map(([name]) => name)
          );
          for (const name of fetchAllProperties) delete userProperties[name];
          const generalProperties = \#(generalJSON);
          const neutralAudioData = new Array(128).fill(0);
          const neutralSystemInformation = JSON.stringify({
            NameCpu: 'Unavailable', CurrentCpu: 0,
            NameGpu: 'Unavailable', CurrentGpu3D: 0,
            NameNetCard: 'Unavailable', CurrentNetDown: 0, CurrentNetUp: 0,
            TotalRam: 1, CurrentRamAvail: 1
          });
          let neutralAudioTimer = null;
          let wallpaperAudioListener = null;
          let currentPausedState = false;
          let lastAppliedListener = null;
          let lastAppliedLivelyPropertyListener = null;
          let lastAppliedLivelyPlaybackListener = null;
          let lastAppliedLivelyPlaybackState = null;
          let lastAppliedLivelyTrackListener = null;
          let lastAppliedLivelySystemListener = null;
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
          const dispatchNeutralAudio = () => {
            if (currentPausedState || !isDOMReady()) return;
            safelyInvoke(window, wallpaperAudioListener, [neutralAudioData.slice()]);
            safelyInvoke(window, window.livelyAudioListener, [neutralAudioData.slice()]);
          };
          const updateNeutralAudioTimer = () => {
            const hasListener = typeof wallpaperAudioListener === 'function'
              || typeof window.livelyAudioListener === 'function';
            if (!hasListener) {
              if (neutralAudioTimer !== null) window.clearInterval(neutralAudioTimer);
              neutralAudioTimer = null;
              return;
            }
            if (neutralAudioTimer !== null) return;
            dispatchNeutralAudio();
            neutralAudioTimer = window.setInterval(dispatchNeutralAudio, 1000 / 30);
          };
          window.wallpaperRegisterAudioListener = (listener) => {
            wallpaperAudioListener = typeof listener === 'function' ? listener : null;
            updateNeutralAudioTimer();
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
          const applyLivelyProperties = () => {
            if (!isDOMReady()) return false;
            const listener = window.livelyPropertyListener;
            if (typeof listener !== 'function') return false;
            if (listener === lastAppliedLivelyPropertyListener) return true;
            let delivered = true;
            for (const name of Object.keys(livelyUserProperties).sort()) {
              delivered = safelyInvoke(
                window,
                listener,
                [name, livelyUserProperties[name]]
              ) && delivered;
            }
            if (delivered) lastAppliedLivelyPropertyListener = listener;
            return delivered;
          };
          const applyLivelyPlaybackState = () => {
            if (!isDOMReady()) return false;
            const listener = window.livelyWallpaperPlaybackChanged;
            if (typeof listener !== 'function') return false;
            if (listener === lastAppliedLivelyPlaybackListener
                && currentPausedState === lastAppliedLivelyPlaybackState) return true;
            const delivered = safelyInvoke(
              window,
              listener,
              [JSON.stringify({ IsPaused: currentPausedState })]
            );
            if (delivered) {
              lastAppliedLivelyPlaybackListener = listener;
              lastAppliedLivelyPlaybackState = currentPausedState;
            }
            return delivered;
          };
          const applyLivelyCurrentTrack = () => {
            if (!isDOMReady()) return false;
            const listener = window.livelyCurrentTrack;
            if (typeof listener !== 'function') return false;
            if (listener === lastAppliedLivelyTrackListener) return true;
            const delivered = safelyInvoke(window, listener, ['null']);
            if (delivered) lastAppliedLivelyTrackListener = listener;
            return delivered;
          };
          const applyLivelySystemInformation = () => {
            if (!isDOMReady()) return false;
            const listener = window.livelySystemInformation;
            if (typeof listener !== 'function') return false;
            if (listener === lastAppliedLivelySystemListener) return true;
            const delivered = safelyInvoke(window, listener, [neutralSystemInformation]);
            if (delivered) lastAppliedLivelySystemListener = listener;
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
          const installLivelyCallbackHook = (name, callbackInstalled) => {
            const descriptor = Object.getOwnPropertyDescriptor(window, name);
            if (descriptor && descriptor.configurable === false) return;
            let callbackValue = window[name] || null;
            Object.defineProperty(window, name, {
              configurable: true,
              enumerable: true,
              get: () => callbackValue,
              set: (callback) => {
                callbackValue = callback;
                window.setTimeout(callbackInstalled, 0);
              }
            });
          };
          installPropertyListenerHook();
          installLivelyCallbackHook('livelyPropertyListener', () => {
            lastAppliedLivelyPropertyListener = null;
            applyLivelyProperties();
          });
          installLivelyCallbackHook('livelyWallpaperPlaybackChanged', () => {
            lastAppliedLivelyPlaybackListener = null;
            lastAppliedLivelyPlaybackState = null;
            applyLivelyPlaybackState();
          });
          installLivelyCallbackHook('livelyAudioListener', updateNeutralAudioTimer);
          installLivelyCallbackHook('livelyCurrentTrack', () => {
            lastAppliedLivelyTrackListener = null;
            applyLivelyCurrentTrack();
          });
          installLivelyCallbackHook('livelySystemInformation', () => {
            lastAppliedLivelySystemListener = null;
            applyLivelySystemInformation();
          });
          window.__backgroundEngineSetPaused = (paused) => {
            currentPausedState = Boolean(paused);
            if (!isDOMReady()) return;
            const listener = window.wallpaperPropertyListener;
            if (listener) safelyInvoke(listener, listener.setPaused, [currentPausedState]);
            applyLivelyPlaybackState();
            if (!currentPausedState) dispatchNeutralAudio();
          };
          const applyRuntimeCallbacks = () => {
            applyProperties();
            applyLivelyProperties();
            applyLivelyPlaybackState();
            applyLivelyCurrentTrack();
            applyLivelySystemInformation();
            updateNeutralAudioTimer();
          };
          window.addEventListener('DOMContentLoaded', applyRuntimeCallbacks, { once: true });
          let listenerProbeAttempts = 0;
          const probeForListener = () => {
            applyRuntimeCallbacks();
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

    private static func comboOptionValues(_ descriptor: [String: Any]) -> Set<String> {
        Set((descriptor["options"] as? [[String: Any]] ?? []).compactMap { option in
            option["value"] as? String
        })
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
        case "button": .button
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
        case (.button, _):
            false
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
        "apng", "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg",
        "png", "svg", "tif", "tiff", "webp"
    ]
    private static let videoDirectoryExtensions: Set<String> = [
        "avi", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "ogg", "ogv", "webm"
    ]

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

enum WebProjectResourceError: Error, Equatable {
    case invalidProjectRoot
    case unsafeLocalFile
    case invalidVirtualURL
    case unsatisfiableRange
}

struct WebProjectPreparedResource: Equatable, Sendable {
    let sourceURL: URL
    let preparedURL: URL
    let mimeType: String

    init(sourceURL: URL, preparedURL: URL, mimeType: String) {
        self.sourceURL = sourceURL
        self.preparedURL = preparedURL
        self.mimeType = mimeType
    }
}

struct WebProjectResolvedResource: Equatable, Sendable {
    let fileURL: URL
    let mimeType: String
    let projectRelativePathComponents: [String]?
    /// Canonical authored source path used to address an already-pinned
    /// prepared resource. Unlike `fileURL`, this identity stays valid after a
    /// cache clear unlinks the prepared pathname while a display is playing.
    let preparedSourcePath: String?
}

/// Maps an authored Web project onto a unique, non-network WebKit origin.
/// Requests are resolved from canonical path components instead of trusting a
/// URL path string, so percent-encoded traversal and symlink escapes never
/// gain read access outside the imported wallpaper. A prepared media file may
/// replace the bytes and MIME type for one exact source without changing the
/// imported project or weakening its `media-src 'self'` policy.
struct WebProjectResourceResolver: Sendable {
    static let scheme = "background-engine-web"
    static let projectPathComponent = "project"

    let projectRoot: URL
    let sessionHost: String
    private let preparedBySourcePath: [String: WebProjectPreparedResource]
    private let mimeTypeOverrideBySourcePath: [String: WebLocalResourceMIMEOverride]

    init(
        projectRoot: URL,
        sessionHost: String = "session-\(UUID().uuidString.lowercased())",
        preparedResources: [WebProjectPreparedResource] = [],
        mimeTypeOverrides: [WebLocalResourceMIMEOverride] = []
    ) throws {
        let lexicalRoot = projectRoot.standardizedFileURL
        let canonicalRoot = lexicalRoot.resolvingSymlinksInPath()
        guard projectRoot.isFileURL,
              lexicalRoot == canonicalRoot,
              let values = try? lexicalRoot.resourceValues(
                  forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ),
              values.isDirectory == true,
              values.isSymbolicLink != true,
              Self.isValidHost(sessionHost) else {
            throw WebProjectResourceError.invalidProjectRoot
        }
        self.projectRoot = canonicalRoot
        self.sessionHost = sessionHost.lowercased()
        var prepared = [String: WebProjectPreparedResource]()
        for resource in preparedResources {
            guard let source = Self.safeRegularFile(
                resource.sourceURL,
                inside: canonicalRoot
            ),
                  Self.safeRegularFile(resource.preparedURL, inside: nil) != nil,
                  !resource.mimeType.isEmpty else {
                throw WebProjectResourceError.unsafeLocalFile
            }
            prepared[source.path] = resource
        }
        preparedBySourcePath = prepared
        var overrides = [String: WebLocalResourceMIMEOverride]()
        for override in mimeTypeOverrides {
            guard let source = Self.safeRegularFile(
                override.sourceURL,
                inside: canonicalRoot
            ), Self.allowedMIMEOverrides.contains(override.mimeType) else {
                throw WebProjectResourceError.unsafeLocalFile
            }
            overrides[source.path] = WebLocalResourceMIMEOverride(
                sourceURL: source,
                mimeType: override.mimeType
            )
        }
        mimeTypeOverrideBySourcePath = overrides
    }

    func replacingPreparedResources(
        _ resources: [WebProjectPreparedResource],
        mimeTypeOverrides: [WebLocalResourceMIMEOverride]? = nil
    ) throws -> WebProjectResourceResolver {
        try WebProjectResourceResolver(
            projectRoot: projectRoot,
            sessionHost: sessionHost,
            preparedResources: resources,
            mimeTypeOverrides: mimeTypeOverrides
                ?? Array(mimeTypeOverrideBySourcePath.values)
        )
    }

    func virtualURL(for localFile: URL) throws -> URL {
        guard let canonical = Self.safeRegularFile(localFile, inside: projectRoot) else {
            throw WebProjectResourceError.unsafeLocalFile
        }
        return try virtualURL(forCanonicalResource: canonical, isDirectory: false)
    }

    func virtualDirectoryURL(for localDirectory: URL) throws -> URL {
        guard let canonical = Self.safeDirectory(localDirectory, inside: projectRoot) else {
            throw WebProjectResourceError.unsafeLocalFile
        }
        return try virtualURL(forCanonicalResource: canonical, isDirectory: true)
    }

    private func virtualURL(forCanonicalResource canonical: URL, isDirectory: Bool) throws -> URL {
        let relativeComponents = canonical.pathComponents.dropFirst(projectRoot.pathComponents.count)
        guard !relativeComponents.isEmpty else {
            throw WebProjectResourceError.unsafeLocalFile
        }
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = sessionHost
        let encoded = relativeComponents.map(Self.percentEncodePathComponent).joined(separator: "/")
        components.percentEncodedPath = "/\(Self.projectPathComponent)/\(encoded)"
            + (isDirectory ? "/" : "")
        guard let result = components.url else {
            throw WebProjectResourceError.invalidVirtualURL
        }
        return result
    }

    func resolve(_ virtualURL: URL) throws -> WebProjectResolvedResource {
        guard virtualURL.scheme?.lowercased() == Self.scheme,
              virtualURL.host?.lowercased() == sessionHost,
              virtualURL.user == nil,
              virtualURL.password == nil,
              virtualURL.port == nil,
              let components = URLComponents(url: virtualURL, resolvingAgainstBaseURL: false) else {
            throw WebProjectResourceError.invalidVirtualURL
        }
        let encodedParts = components.percentEncodedPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard encodedParts.count > 2,
              encodedParts[0].isEmpty,
              encodedParts[1] == Substring(Self.projectPathComponent) else {
            throw WebProjectResourceError.invalidVirtualURL
        }
        var candidate = projectRoot
        for encodedPart in encodedParts.dropFirst(2) {
            guard !encodedPart.isEmpty,
                  let decoded = String(encodedPart).removingPercentEncoding,
                  !decoded.isEmpty,
                  decoded != ".",
                  decoded != "..",
                  !decoded.contains("/"),
                  !decoded.contains("\\"),
                  !decoded.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw WebProjectResourceError.invalidVirtualURL
            }
            candidate.append(path: decoded)
        }
        guard let source = Self.safeRegularFile(candidate, inside: projectRoot) else {
            throw WebProjectResourceError.unsafeLocalFile
        }
        if let prepared = preparedBySourcePath[source.path] {
            return WebProjectResolvedResource(
                fileURL: prepared.preparedURL,
                mimeType: prepared.mimeType,
                projectRelativePathComponents: nil,
                preparedSourcePath: source.path
            )
        }
        return WebProjectResolvedResource(
            fileURL: source,
            mimeType: mimeTypeOverrideBySourcePath[source.path]?.mimeType
                ?? WebLoopbackMIMEType.mimeType(for: source.pathExtension),
            projectRelativePathComponents: encodedParts.dropFirst(2).compactMap {
                String($0).removingPercentEncoding
            },
            preparedSourcePath: nil
        )
    }

    private static func safeRegularFile(_ file: URL, inside root: URL?) -> URL? {
        guard file.isFileURL else { return nil }
        let lexical = file.standardizedFileURL
        let canonical = lexical.resolvingSymlinksInPath()
        if let root {
            let rootComponents = root.pathComponents
            let candidateComponents = canonical.pathComponents
            guard candidateComponents.count > rootComponents.count,
                  Array(candidateComponents.prefix(rootComponents.count)) == rootComponents else {
                return nil
            }
        }
        guard let values = try? lexical.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ), values.isRegularFile == true, values.isSymbolicLink != true else {
            return nil
        }
        return canonical
    }

    private static func safeDirectory(_ directory: URL, inside root: URL?) -> URL? {
        guard directory.isFileURL else { return nil }
        let lexical = directory.standardizedFileURL
        let canonical = lexical.resolvingSymlinksInPath()
        if let root {
            let rootComponents = root.pathComponents
            let candidateComponents = canonical.pathComponents
            guard candidateComponents.count > rootComponents.count,
                  Array(candidateComponents.prefix(rootComponents.count)) == rootComponents else {
                return nil
            }
        }
        guard let values = try? lexical.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ), values.isDirectory == true, values.isSymbolicLink != true else {
            return nil
        }
        return canonical
    }

    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host == host.lowercased() else { return false }
        return host.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0)
        }
    }

    private static let allowedMIMEOverrides: Set<String> = [
        "text/css", "text/html", "text/javascript"
    ]

    private static func percentEncodePathComponent(_ component: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%?#\\")
        return component.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

}

struct WebProjectByteRange: Equatable, Sendable {
    let offset: UInt64
    let length: UInt64

    static func resolve(header: String?, totalLength: UInt64) throws -> WebProjectByteRange {
        guard totalLength > 0 else {
            if header == nil { return WebProjectByteRange(offset: 0, length: 0) }
            throw WebProjectResourceError.unsatisfiableRange
        }
        guard let header else {
            return WebProjectByteRange(offset: 0, length: totalLength)
        }
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes="),
              !trimmed.contains(",") else {
            throw WebProjectResourceError.unsatisfiableRange
        }
        let specification = trimmed.dropFirst(6)
        let bounds = specification.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2 else {
            throw WebProjectResourceError.unsatisfiableRange
        }
        if bounds[0].isEmpty {
            guard let requested = UInt64(bounds[1]), requested > 0 else {
                throw WebProjectResourceError.unsatisfiableRange
            }
            let length = min(requested, totalLength)
            return WebProjectByteRange(offset: totalLength - length, length: length)
        }
        guard let start = UInt64(bounds[0]), start < totalLength else {
            throw WebProjectResourceError.unsatisfiableRange
        }
        let inclusiveEnd: UInt64
        if bounds[1].isEmpty {
            inclusiveEnd = totalLength - 1
        } else {
            guard let requestedEnd = UInt64(bounds[1]), requestedEnd >= start else {
                throw WebProjectResourceError.unsatisfiableRange
            }
            inclusiveEnd = min(requestedEnd, totalLength - 1)
        }
        return WebProjectByteRange(
            offset: start,
            length: inclusiveEnd - start + 1
        )
    }
}

/// Streams local project resources in bounded chunks. The handler opens every
/// file with `O_NOFOLLOW`, pins the inode for the lifetime of a response and
/// implements single byte ranges used by HTMLMediaElement seeking and loops.
@MainActor
final class WebProjectURLSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    private final class PinnedPreparedResource: @unchecked Sendable {
        let url: URL
        let mimeType: String
        private let descriptor: Int32

        init(url: URL, mimeType: String) throws {
            guard url.isFileURL else {
                throw WebProjectResourceError.unsafeLocalFile
            }
            var canonicalBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            let canonicalPath = url.withUnsafeFileSystemRepresentation { path -> String? in
                guard let path, realpath(path, &canonicalBuffer) != nil else { return nil }
                return String(
                    decoding: canonicalBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                    as: UTF8.self
                )
            }
            guard let canonicalPath else {
                throw WebProjectResourceError.unsafeLocalFile
            }
            let canonicalURL = URL(filePath: canonicalPath)
            // `standardizedFileURL.pathComponents` rewrites Darwin aliases
            // such as `/private/var` back to `/var`. Walking that result from
            // `/` with O_NOFOLLOW would encounter the `/var` compatibility
            // symlink and fail. `realpath` already returned a canonical
            // absolute path, so split those exact bytes instead.
            let components = canonicalPath.split(
                separator: "/",
                omittingEmptySubsequences: true
            ).map(String.init)
            var expected = stat()
            let inspected = canonicalURL.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return lstat(path, &expected)
            }
            guard canonicalPath.hasPrefix("/"), !components.isEmpty,
                  inspected == 0, (expected.st_mode & S_IFMT) == S_IFREG else {
                throw WebProjectResourceError.unsafeLocalFile
            }
            var current = open("/", O_RDONLY | O_CLOEXEC | O_DIRECTORY)
            guard current >= 0 else { throw WebProjectResourceError.unsafeLocalFile }
            for (index, component) in components.enumerated() {
                let isFinal = index == components.count - 1
                let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | (isFinal ? 0 : O_DIRECTORY)
                let next = component.withCString { openat(current, $0, flags) }
                close(current)
                guard next >= 0 else {
                    throw WebProjectResourceError.unsafeLocalFile
                }
                current = next
            }
            var metadata = stat()
            guard fstat(current, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_dev == expected.st_dev,
                  metadata.st_ino == expected.st_ino,
                  metadata.st_size == expected.st_size else {
                close(current)
                throw WebProjectResourceError.unsafeLocalFile
            }
            self.url = canonicalURL
            self.mimeType = mimeType
            descriptor = current
        }

        deinit { close(descriptor) }

        func duplicateDescriptor() -> Int32? {
            let result = dup(descriptor)
            return result >= 0 ? result : nil
        }
    }

    private final class SchemeTaskBox: @unchecked Sendable {
        let value: any WKURLSchemeTask
        init(_ value: any WKURLSchemeTask) { self.value = value }
    }

    /// Owns exactly one descriptor and makes queued/cancelled scheme
    /// transfers fail-safe. `OperationQueue` is allowed to discard a
    /// cancelled operation without invoking its closure, so raw descriptors
    /// cannot rely on `Transfer.run()` for cleanup.
    private final class OwnedFileDescriptor: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptor: Int32

        init(_ descriptor: Int32) {
            self.descriptor = descriptor
        }

        deinit { closeNow() }

        func take() -> Int32? {
            lock.lock()
            defer { lock.unlock() }
            guard descriptor >= 0 else { return nil }
            let result = descriptor
            descriptor = -1
            return result
        }

        func closeNow() {
            lock.lock()
            let current = descriptor
            descriptor = -1
            lock.unlock()
            if current >= 0 { close(current) }
        }
    }

    private final class Transfer: @unchecked Sendable {
        let identifier: ObjectIdentifier
        let task: SchemeTaskBox
        let request: URLRequest
        let resource: WebProjectResolvedResource
        private let projectRootDescriptor: OwnedFileDescriptor?
        private let preparedDescriptor: OwnedFileDescriptor?
        private let lock = NSLock()
        private var cancelled = false
        private var started = false

        init(
            identifier: ObjectIdentifier,
            task: SchemeTaskBox,
            request: URLRequest,
            resource: WebProjectResolvedResource,
            projectRootDescriptor: Int32?,
            preparedDescriptor: Int32?
        ) {
            self.identifier = identifier
            self.task = task
            self.request = request
            self.resource = resource
            self.projectRootDescriptor = projectRootDescriptor.map(OwnedFileDescriptor.init)
            self.preparedDescriptor = preparedDescriptor.map(OwnedFileDescriptor.init)
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let canCloseImmediately = !started
            lock.unlock()
            if canCloseImmediately {
                closeUnusedProjectRootDescriptor()
                closeUnusedPreparedDescriptor()
            }
        }

        func run() {
            guard beginRun() else { return }
            defer {
                closeUnusedProjectRootDescriptor()
                closeUnusedPreparedDescriptor()
            }
            guard !isCancelled else { return }
            let descriptor = openResource()
            guard descriptor >= 0 else {
                fail(code: .cannotOpenFile)
                return
            }
            defer { close(descriptor) }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_size >= 0 else {
                fail(code: .cannotOpenFile)
                return
            }
            let totalLength = UInt64(metadata.st_size)
            let requestedRange: WebProjectByteRange
            do {
                requestedRange = try WebProjectByteRange.resolve(
                    header: request.value(forHTTPHeaderField: "Range"),
                    totalLength: totalLength
                )
            } catch {
                sendUnsatisfiableRange(totalLength: totalLength)
                return
            }
            guard !isCancelled else { return }
            let isPartial = request.value(forHTTPHeaderField: "Range") != nil
            var headers = [
                "Accept-Ranges": "bytes",
                "Content-Length": String(requestedRange.length),
                "Content-Type": resource.mimeType,
                "Cache-Control": "no-store"
            ]
            if isPartial, requestedRange.length > 0 {
                headers["Content-Range"] = "bytes \(requestedRange.offset)-\(requestedRange.offset + requestedRange.length - 1)/\(totalLength)"
            }
            guard let response = HTTPURLResponse(
                url: request.url ?? resource.fileURL,
                statusCode: isPartial ? 206 : 200,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) else {
                fail(code: .badServerResponse)
                return
            }
            guard deliver({ $0.didReceive(response) }) else { return }
            var remaining = requestedRange.length
            var offset = requestedRange.offset
            var buffer = [UInt8](repeating: 0, count: 256 * 1_024)
            while remaining > 0, !isCancelled {
                let requested = min(UInt64(buffer.count), remaining)
                let count = pread(descriptor, &buffer, Int(requested), off_t(offset))
                guard count > 0 else {
                    fail(code: .cannotDecodeContentData)
                    return
                }
                guard !isCancelled else { return }
                let data = Data(bytes: buffer, count: count)
                guard deliver({ $0.didReceive(data) }) else { return }
                offset += UInt64(count)
                remaining -= UInt64(count)
            }
            _ = deliver { $0.didFinish() }
        }

        private func openResource() -> Int32 {
            guard let components = resource.projectRelativePathComponents else {
                closeUnusedProjectRootDescriptor()
                return preparedDescriptor?.take() ?? -1
            }
            guard !components.isEmpty,
                  var directoryDescriptor = projectRootDescriptor?.take() else {
                closeUnusedProjectRootDescriptor()
                return -1
            }
            for (index, component) in components.enumerated() {
                let isFinal = index == components.count - 1
                let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | (isFinal ? 0 : O_DIRECTORY)
                let nextDescriptor = component.withCString {
                    openat(directoryDescriptor, $0, flags)
                }
                close(directoryDescriptor)
                guard nextDescriptor >= 0 else { return -1 }
                if isFinal { return nextDescriptor }
                directoryDescriptor = nextDescriptor
            }
            close(directoryDescriptor)
            return -1
        }

        private func closeUnusedProjectRootDescriptor() {
            projectRootDescriptor?.closeNow()
        }

        private func closeUnusedPreparedDescriptor() {
            preparedDescriptor?.closeNow()
        }

        private func beginRun() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { return false }
            started = true
            return true
        }

        private var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        private func sendUnsatisfiableRange(totalLength: UInt64) {
            guard !isCancelled,
                  let response = HTTPURLResponse(
                      url: request.url ?? resource.fileURL,
                      statusCode: 416,
                      httpVersion: "HTTP/1.1",
                      headerFields: [
                          "Accept-Ranges": "bytes",
                          "Content-Range": "bytes */\(totalLength)",
                          "Content-Length": "0",
                          "Cache-Control": "no-store"
                      ]
                  ) else { return }
            guard deliver({ $0.didReceive(response) }) else { return }
            _ = deliver { $0.didFinish() }
        }

        private func fail(code: URLError.Code) {
            let error = URLError(code, userInfo: [
                NSURLErrorKey: request.url as Any
            ])
            _ = deliver { $0.didFailWithError(error) }
        }

        /// `WKURLSchemeTask` forbids callbacks after WebKit invokes `stop`.
        /// Both `stop` and every callback are serialized on the main queue,
        /// with cancellation checked inside that serialization boundary.
        private func deliver(
            _ body: @escaping @MainActor @Sendable (any WKURLSchemeTask) -> Void
        ) -> Bool {
            var delivered = false
            DispatchQueue.main.sync {
                guard !isCancelled else { return }
                body(task.value)
                delivered = true
            }
            return delivered
        }
    }

    private let stateLock = NSLock()
    private var resolver: WebProjectResourceResolver
    private let projectRootDescriptor: Int32
    private var preparedBySourcePath = [String: PinnedPreparedResource]()
    private var transfers = [ObjectIdentifier: Transfer]()
    private var isClosed = false
    private let workerQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.lamppkk.backgroundengine.web-project"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 8
        return queue
    }()
    private static let maximumActiveTransfers = 64

    init(projectRoot: URL) throws {
        let initialResolver = try WebProjectResourceResolver(projectRoot: projectRoot)
        let rootDescriptor = open(
            initialResolver.projectRoot.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
        )
        var metadata = stat()
        guard rootDescriptor >= 0,
              fstat(rootDescriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR else {
            if rootDescriptor >= 0 { close(rootDescriptor) }
            throw WebProjectResourceError.invalidProjectRoot
        }
        resolver = initialResolver
        projectRootDescriptor = rootDescriptor
        super.init()
    }

    deinit {
        close(projectRootDescriptor)
    }

    var sessionHost: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return resolver.sessionHost
    }

    func virtualURL(for localFile: URL) throws -> URL {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try resolver.virtualURL(for: localFile)
    }

    func virtualDirectoryURL(for localDirectory: URL) throws -> URL {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try resolver.virtualDirectoryURL(for: localDirectory)
    }

    func installPreparedResources(_ resources: [WebProjectPreparedResource]) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isClosed else { throw WebProjectResourceError.invalidVirtualURL }
        let updatedResolver = try resolver.replacingPreparedResources(resources)
        var pinned = [String: PinnedPreparedResource]()
        for resource in resources {
            let virtualSource = try updatedResolver.virtualURL(for: resource.sourceURL)
            let resolved = try updatedResolver.resolve(virtualSource)
            guard let sourcePath = resolved.preparedSourcePath else {
                throw WebProjectResourceError.unsafeLocalFile
            }
            let prepared = try PinnedPreparedResource(
                url: resolved.fileURL,
                mimeType: resolved.mimeType
            )
            pinned[sourcePath] = prepared
        }
        resolver = updatedResolver
        preparedBySourcePath = pinned
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let box = SchemeTaskBox(urlSchemeTask)
        let identifier = ObjectIdentifier(urlSchemeTask as AnyObject)
        let resource: WebProjectResolvedResource
        let preparedDescriptor: Int32?
        stateLock.lock()
        guard !isClosed, transfers.count < Self.maximumActiveTransfers else {
            stateLock.unlock()
            urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
            return
        }
        do {
            resource = try resolver.resolve(urlSchemeTask.request.url ?? URL(filePath: "/"))
        } catch {
            stateLock.unlock()
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        if resource.projectRelativePathComponents == nil {
            guard let sourcePath = resource.preparedSourcePath,
                  let pinned = preparedBySourcePath[sourcePath],
                  let descriptor = pinned.duplicateDescriptor() else {
                stateLock.unlock()
                urlSchemeTask.didFailWithError(URLError(.cannotOpenFile))
                return
            }
            preparedDescriptor = descriptor
        } else {
            preparedDescriptor = nil
        }
        let transfer = Transfer(
            identifier: identifier,
            task: box,
            request: urlSchemeTask.request,
            resource: resource,
            projectRootDescriptor: resource.projectRelativePathComponents == nil
                ? nil
                : duplicateProjectRootDescriptor(),
            preparedDescriptor: preparedDescriptor
        )
        transfers[identifier]?.cancel()
        transfers[identifier] = transfer
        stateLock.unlock()
        workerQueue.addOperation { [weak self, transfer] in
            transfer.run()
            Task { @MainActor [weak self, transfer] in
                self?.finish(transfer)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let identifier = ObjectIdentifier(urlSchemeTask as AnyObject)
        stateLock.lock()
        let transfer = transfers.removeValue(forKey: identifier)
        stateLock.unlock()
        transfer?.cancel()
    }

    func cancelAll() {
        stateLock.lock()
        isClosed = true
        let active = Array(transfers.values)
        transfers.removeAll()
        preparedBySourcePath.removeAll()
        stateLock.unlock()
        active.forEach { $0.cancel() }
        workerQueue.cancelAllOperations()
    }

    private func finish(_ transfer: Transfer) {
        stateLock.lock()
        if transfers[transfer.identifier] === transfer {
            transfers.removeValue(forKey: transfer.identifier)
        }
        stateLock.unlock()
    }

    private func duplicateProjectRootDescriptor() -> Int32? {
        let descriptor = dup(projectRootDescriptor)
        return descriptor >= 0 ? descriptor : nil
    }
}

@MainActor
enum WebWallpaperVirtualURLBridge {
    static func remap(
        properties: [String: WebWallpaperPropertyValue],
        fileProperties: [WebWallpaperCompatibilityBridge.FileProperty],
        directories: [String: WebWallpaperCompatibilityBridge.DirectoryPropertyFiles],
        using handler: WebProjectURLSchemeHandler
    ) -> (
        properties: [String: WebWallpaperPropertyValue],
        directories: [String: WebWallpaperCompatibilityBridge.DirectoryPropertyFiles]
    ) {
        remap(
            properties: properties,
            fileProperties: fileProperties,
            directories: directories,
            virtualFileURL: handler.virtualURL(for:),
            virtualDirectoryURL: handler.virtualDirectoryURL(for:)
        )
    }

    static func redactingHostPaths(
        properties: [String: WebWallpaperPropertyValue],
        fileProperties: [WebWallpaperCompatibilityBridge.FileProperty],
        directories: [String: WebWallpaperCompatibilityBridge.DirectoryPropertyFiles]
    ) -> (
        properties: [String: WebWallpaperPropertyValue],
        directories: [String: WebWallpaperCompatibilityBridge.DirectoryPropertyFiles]
    ) {
        remap(
            properties: properties,
            fileProperties: fileProperties,
            directories: directories,
            virtualFileURL: { _ in throw WebProjectResourceError.invalidVirtualURL },
            virtualDirectoryURL: { _ in throw WebProjectResourceError.invalidVirtualURL }
        )
    }

    static func remap(
        properties: [String: WebWallpaperPropertyValue],
        fileProperties: [WebWallpaperCompatibilityBridge.FileProperty],
        directories: [String: WebWallpaperCompatibilityBridge.DirectoryPropertyFiles],
        using server: WebProjectLoopbackServer
    ) -> (
        properties: [String: WebWallpaperPropertyValue],
        directories: [String: WebWallpaperCompatibilityBridge.DirectoryPropertyFiles]
    ) {
        remap(
            properties: properties,
            fileProperties: fileProperties,
            directories: directories,
            virtualFileURL: server.virtualURL(for:),
            virtualDirectoryURL: server.virtualDirectoryURL(for:)
        )
    }

    private static func remap(
        properties: [String: WebWallpaperPropertyValue],
        fileProperties: [WebWallpaperCompatibilityBridge.FileProperty],
        directories: [String: WebWallpaperCompatibilityBridge.DirectoryPropertyFiles],
        virtualFileURL: (URL) throws -> URL,
        virtualDirectoryURL: (URL) throws -> URL
    ) -> (
        properties: [String: WebWallpaperPropertyValue],
        directories: [String: WebWallpaperCompatibilityBridge.DirectoryPropertyFiles]
    ) {
        let filePropertyKinds = Dictionary(
            uniqueKeysWithValues: fileProperties.map { ($0.name, $0.selectsDirectory) }
        )
        let mappedProperties = properties.mapValues { $0 }
        var propertiesResult = mappedProperties
        for (name, selectsDirectory) in filePropertyKinds {
            guard case .text(let path) = propertiesResult[name],
                  NSString(string: path).isAbsolutePath else { continue }
            let localURL = URL(filePath: path)
            let virtualURL = selectsDirectory
                ? try? virtualDirectoryURL(localURL)
                : try? virtualFileURL(localURL)
            if let virtualURL {
                propertiesResult[name] = .text(virtualURL.absoluteString)
            } else {
                // A file override is privileged host state. If its private
                // virtual URL cannot be minted (missing/raced file, remote
                // project, or failed local server), fail closed instead of
                // exposing an absolute macOS path to wallpaper JavaScript.
                propertiesResult[name] = .text("")
            }
        }
        let directoryResult = directories.mapValues { directory in
            WebWallpaperCompatibilityBridge.DirectoryPropertyFiles(
                mode: directory.mode,
                files: directory.files.compactMap { path in
                    guard NSString(string: path).isAbsolutePath else { return path }
                    return try? virtualFileURL(URL(filePath: path)).absoluteString
                }
            )
        }
        return (propertiesResult, directoryResult)
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
        trustedVirtualMainFrameURL: URL? = nil,
        trustedLoopbackMainFrameURL: URL? = nil,
        trustedRemoteMainFrameURL: URL? = nil
    ) -> Bool {
        guard !isDownload, let candidate else { return false }
        guard candidate.user == nil, candidate.password == nil else { return false }
        if allowsOpaqueSubframeNavigation(
            candidate,
            isMainFrame: isMainFrame,
            trustedLocalMainFrameURL: trustedLocalMainFrameURL,
            trustedVirtualMainFrameURL: trustedVirtualMainFrameURL,
            trustedLoopbackMainFrameURL: trustedLoopbackMainFrameURL,
            trustedRemoteMainFrameURL: trustedRemoteMainFrameURL
        ) {
            return true
        }
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
        if candidate.scheme?.lowercased() == WebProjectResourceResolver.scheme {
            guard let trustedVirtualMainFrameURL,
                  candidate.port == nil,
                  sameVirtualOrigin(candidate, trustedVirtualMainFrameURL),
                  candidate.pathComponents.starts(with: ["/", WebProjectResourceResolver.projectPathComponent]),
                  candidate.pathComponents.count > 2 else {
                return false
            }
            guard isMainFrame else { return true }
            return candidate.path == trustedVirtualMainFrameURL.path
        }
        if let trustedLoopbackMainFrameURL,
           sameLoopbackOrigin(candidate, trustedLoopbackMainFrameURL) {
            guard isTrustedLoopbackProjectPath(candidate, trustedLoopbackMainFrameURL) else {
                return false
            }
            guard isMainFrame else { return true }
            return exactLoopbackEntrypoint(candidate, trustedLoopbackMainFrameURL)
        }
        // Even with networking enabled, reject literal loopback hosts so a
        // wallpaper cannot directly target developer services or another
        // display's secret origin. Hostname DNS rebinding cannot be enforced
        // by WKContentRuleList and is explicitly disclosed before opt-in.
        if WebWallpaperNetworkPolicy.isBlockedExternalURL(candidate) { return false }
        guard networkAccessAllowed,
              ["https", "http"].contains(candidate.scheme?.lowercased() ?? "") else {
            return false
        }
        guard isMainFrame else { return true }
        guard let trustedRemoteMainFrameURL else { return false }
        return sameRemoteOrigin(candidate, trustedRemoteMainFrameURL)
    }

    /// Authored inline frames are part of normal Web wallpaper rendering.
    /// Keep these opaque/document-generated schemes out of the main frame,
    /// while permitting subframes only when the view has an established
    /// trusted top-level document. Blob URLs additionally have to inherit that
    /// trusted origin (or the browser's unforgeable opaque `null` origin).
    private static func allowsOpaqueSubframeNavigation(
        _ candidate: URL,
        isMainFrame: Bool,
        trustedLocalMainFrameURL: URL?,
        trustedVirtualMainFrameURL: URL?,
        trustedLoopbackMainFrameURL: URL?,
        trustedRemoteMainFrameURL: URL?
    ) -> Bool {
        guard !isMainFrame else { return false }
        let hasTrustedMainFrame = trustedLocalMainFrameURL != nil
            || trustedVirtualMainFrameURL != nil
            || trustedLoopbackMainFrameURL != nil
            || trustedRemoteMainFrameURL != nil
        guard hasTrustedMainFrame else { return false }
        switch candidate.scheme?.lowercased() {
        case "data":
            return candidate.host == nil && candidate.port == nil
        case "about":
            let serialized = candidate.absoluteString.lowercased()
            let documentName = serialized
                .dropFirst("about:".count)
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init)
            return candidate.host == nil
                && candidate.port == nil
                && candidate.query == nil
                && documentName.map({ ["blank", "srcdoc"].contains($0) }) == true
        case "blob":
            let serialized = candidate.absoluteString
            guard serialized.lowercased().hasPrefix("blob:") else { return false }
            let originAndIdentifier = String(serialized.dropFirst("blob:".count))
            if originAndIdentifier.lowercased().hasPrefix("null/") {
                return true
            }
            guard let embeddedOrigin = URL(string: originAndIdentifier),
                  embeddedOrigin.user == nil,
                  embeddedOrigin.password == nil else { return false }
            if let trustedLoopbackMainFrameURL,
               sameLoopbackOrigin(embeddedOrigin, trustedLoopbackMainFrameURL) {
                return true
            }
            if let trustedVirtualMainFrameURL,
               sameVirtualOrigin(embeddedOrigin, trustedVirtualMainFrameURL) {
                return true
            }
            if let trustedRemoteMainFrameURL,
               sameRemoteOrigin(embeddedOrigin, trustedRemoteMainFrameURL) {
                return true
            }
            return trustedLocalMainFrameURL != nil && embeddedOrigin.isFileURL
        default:
            return false
        }
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
        trustedVirtualMainFrameURL: URL? = nil,
        trustedLoopbackMainFrameURL: URL? = nil,
        trustedRemoteMainFrameURL: URL? = nil
    ) -> Bool {
        canShowMIMEType && allows(
            candidate,
            projectRoot: projectRoot,
            isMainFrame: isMainFrame,
            networkAccessAllowed: networkAccessAllowed,
            trustedLocalMainFrameURL: trustedLocalMainFrameURL,
            trustedVirtualMainFrameURL: trustedVirtualMainFrameURL,
            trustedLoopbackMainFrameURL: trustedLoopbackMainFrameURL,
            trustedRemoteMainFrameURL: trustedRemoteMainFrameURL
        )
    }

    private static func sameVirtualOrigin(_ candidate: URL, _ trusted: URL) -> Bool {
        candidate.scheme?.lowercased() == WebProjectResourceResolver.scheme
            && trusted.scheme?.lowercased() == WebProjectResourceResolver.scheme
            && candidate.host?.lowercased() == trusted.host?.lowercased()
            && candidate.user == nil
            && candidate.password == nil
            && trusted.user == nil
            && trusted.password == nil
            && candidate.port == nil
            && trusted.port == nil
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

    private static func sameLoopbackOrigin(_ candidate: URL, _ trusted: URL) -> Bool {
        candidate.scheme?.lowercased() == "http"
            && trusted.scheme?.lowercased() == "http"
            && candidate.host == "127.0.0.1"
            && trusted.host == "127.0.0.1"
            && candidate.port == trusted.port
            && candidate.port != nil
            && candidate.user == nil
            && candidate.password == nil
            && trusted.user == nil
            && trusted.password == nil
    }

    private static func isTrustedLoopbackProjectPath(_ candidate: URL, _ trusted: URL) -> Bool {
        guard let candidateComponents = URLComponents(
            url: candidate,
            resolvingAgainstBaseURL: false
        ),
              let trustedComponents = URLComponents(
                  url: trusted,
                  resolvingAgainstBaseURL: false
              ) else { return false }
        let trustedParts = trustedComponents.percentEncodedPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        let candidateParts = candidateComponents.percentEncodedPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard trustedParts.count > 3,
              trustedParts[0].isEmpty,
              trustedParts[2] == Substring(WebProjectResourceResolver.projectPathComponent),
              candidateParts.count > 3 else { return false }
        return candidateParts[0].isEmpty
            && candidateParts[1] == trustedParts[1]
            && candidateParts[2] == trustedParts[2]
    }

    private static func exactLoopbackEntrypoint(_ candidate: URL, _ trusted: URL) -> Bool {
        guard let candidateComponents = URLComponents(
            url: candidate,
            resolvingAgainstBaseURL: false
        ),
              let trustedComponents = URLComponents(
                  url: trusted,
                  resolvingAgainstBaseURL: false
              ) else { return false }
        return candidateComponents.percentEncodedPath == trustedComponents.percentEncodedPath
            && candidateComponents.percentEncodedQuery == trustedComponents.percentEncodedQuery
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

/// Repairs Wallpaper Engine's documented `file:///` property-consumer pattern
/// after selected files have been remapped onto this view's authenticated
/// loopback project origin. The bridge deliberately recognizes only one exact
/// canonical project capability and only passive resource consumers. It never
/// turns arbitrary `file:`, loopback, executable, or navigation URLs into HTTP.
enum WebWallpaperFileURLCompatibilityBridge {
    static func bootstrapScript(trustedProjectURLPrefix: URL) -> String {
        guard let components = URLComponents(
            url: trustedProjectURLPrefix,
            resolvingAgainstBaseURL: false
        ),
              components.scheme == "http",
              components.host == "127.0.0.1",
              let port = components.port,
              (1...Int(UInt16.max)).contains(port),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let canonicalURL = components.url,
              canonicalURL.absoluteString == trustedProjectURLPrefix.absoluteString else {
            return "(() => {})();"
        }
        let pathParts = components.percentEncodedPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard pathParts.count == 4,
              pathParts[0].isEmpty,
              pathParts[2] == Substring(WebProjectResourceResolver.projectPathComponent),
              pathParts[3].isEmpty else {
            return "(() => {})();"
        }
        let token = pathParts[1]
        guard token.utf8.count == 64,
              token.utf8.allSatisfy({ byte in
                  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                      || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
              }),
              let prefixData = try? JSONEncoder().encode(canonicalURL.absoluteString),
              let prefixLiteral = String(data: prefixData, encoding: .utf8) else {
            return "(() => {})();"
        }
        return #"""
        (() => {
          'use strict';
          if (window.__backgroundEngineFileURLCompatibilityBridgeInstalled) return;
          const trustedProjectPrefix = \#(prefixLiteral);
          const fileWrapper = 'file:///';
          const wrappedProjectPrefix = fileWrapper + trustedProjectPrefix;
          const NativeURL = window.URL;
          const NativeMutationObserver = window.MutationObserver;
          const NativeHTMLImageElement = window.HTMLImageElement;
          const NativeHTMLMediaElement = window.HTMLMediaElement;
          const NativeHTMLSourceElement = window.HTMLSourceElement;
          const NativeHTMLVideoElement = window.HTMLVideoElement;
          const NativeCSSStyleDeclaration = window.CSSStyleDeclaration;
          const NativeXMLHttpRequest = window.XMLHttpRequest;
          const nativeDocument = document;
          const nativeFetch = window.fetch;
          const nativeReflectApply = Reflect.apply;
          const nativeDefineProperty = Object.defineProperty;
          const nativeGetOwnPropertyDescriptor = Object.getOwnPropertyDescriptor;
          const nativeGetPrototypeOf = Object.getPrototypeOf;
          const nativeStartsWith = String.prototype.startsWith;
          const nativeSlice = String.prototype.slice;
          const nativeIndexOf = String.prototype.indexOf;
          const nativeSplit = String.prototype.split;
          const nativeCharAt = String.prototype.charAt;
          const nativeCharCodeAt = String.prototype.charCodeAt;
          const nativeToLowerCase = String.prototype.toLowerCase;
          const nativeDecodeURIComponent = window.decodeURIComponent;
          const nativeGetAttribute = window.Element && window.Element.prototype.getAttribute;
          const originalSetAttribute = window.Element && window.Element.prototype.setAttribute;
          const nativeDocumentQuerySelectorAll = window.Document
            && window.Document.prototype.querySelectorAll;
          const nativeElementQuerySelectorAll = window.Element
            && window.Element.prototype.querySelectorAll;
          const nativeFragmentQuerySelectorAll = window.DocumentFragment
            && window.DocumentFragment.prototype.querySelectorAll;
          const invoke = (functionValue, receiver, argumentsList) =>
            nativeReflectApply(functionValue, receiver, argumentsList);
          const descriptorGetter = (prototype, name) => {
            if (!prototype || typeof nativeGetOwnPropertyDescriptor !== 'function'
                || typeof nativeGetPrototypeOf !== 'function') return null;
            let current = prototype;
            for (let depth = 0; current && depth < 8; depth += 1) {
              const descriptor = nativeGetOwnPropertyDescriptor(current, name);
              if (descriptor && typeof descriptor.get === 'function') return descriptor.get;
              current = nativeGetPrototypeOf(current);
            }
            return null;
          };
          const urlPrototype = NativeURL && NativeURL.prototype;
          const urlHrefGetter = descriptorGetter(urlPrototype, 'href');
          const urlOriginGetter = descriptorGetter(urlPrototype, 'origin');
          const urlProtocolGetter = descriptorGetter(urlPrototype, 'protocol');
          const urlHostnameGetter = descriptorGetter(urlPrototype, 'hostname');
          const urlPortGetter = descriptorGetter(urlPrototype, 'port');
          const urlUsernameGetter = descriptorGetter(urlPrototype, 'username');
          const urlPasswordGetter = descriptorGetter(urlPrototype, 'password');
          const urlPathnameGetter = descriptorGetter(urlPrototype, 'pathname');
          const localNameGetter = descriptorGetter(
            window.Element && window.Element.prototype,
            'localName'
          );
          const namespaceURIGetter = descriptorGetter(
            window.Element && window.Element.prototype,
            'namespaceURI'
          );
          if (typeof NativeURL !== 'function' || typeof urlHrefGetter !== 'function'
              || typeof urlOriginGetter !== 'function' || typeof urlProtocolGetter !== 'function'
              || typeof urlHostnameGetter !== 'function' || typeof urlPortGetter !== 'function'
              || typeof urlUsernameGetter !== 'function' || typeof urlPasswordGetter !== 'function'
              || typeof urlPathnameGetter !== 'function' || typeof nativeDecodeURIComponent !== 'function') {
            return;
          }
          const readURL = (getter, value) => invoke(getter, value, []);
          const startsWith = (value, prefix) => invoke(nativeStartsWith, value, [prefix]);
          const slice = (value, start, end) => invoke(nativeSlice, value, [start, end]);
          const indexOf = (value, search, start) => invoke(nativeIndexOf, value, [search, start]);
          const split = (value, separator) => invoke(nativeSplit, value, [separator]);
          const charAt = (value, index) => invoke(nativeCharAt, value, [index]);
          const charCodeAt = (value, index) => invoke(nativeCharCodeAt, value, [index]);
          const lowercased = value => invoke(nativeToLowerCase, value, []);
          const isLowerHexToken = value => {
            if (typeof value !== 'string' || value.length !== 64) return false;
            for (let index = 0; index < value.length; index += 1) {
              const code = charCodeAt(value, index);
              if (!((code >= 0x30 && code <= 0x39) || (code >= 0x61 && code <= 0x66))) {
                return false;
              }
            }
            return true;
          };
          let trustedURL;
          let trustedHref = '';
          let trustedOrigin = '';
          let trustedProtocol = '';
          let trustedHostname = '';
          let trustedPort = '';
          let trustedPathname = '';
          try {
            trustedURL = new NativeURL(trustedProjectPrefix);
            trustedHref = readURL(urlHrefGetter, trustedURL);
            trustedOrigin = readURL(urlOriginGetter, trustedURL);
            trustedProtocol = readURL(urlProtocolGetter, trustedURL);
            trustedHostname = readURL(urlHostnameGetter, trustedURL);
            trustedPort = readURL(urlPortGetter, trustedURL);
            trustedPathname = readURL(urlPathnameGetter, trustedURL);
            const trustedParts = split(trustedPathname, '/');
            if (trustedHref !== trustedProjectPrefix || trustedProtocol !== 'http:'
                || trustedHostname !== '127.0.0.1' || !trustedPort
                || readURL(urlUsernameGetter, trustedURL) !== ''
                || readURL(urlPasswordGetter, trustedURL) !== ''
                || trustedParts.length !== 4 || trustedParts[0] !== ''
                || !isLowerHexToken(trustedParts[1]) || trustedParts[2] !== 'project'
                || trustedParts[3] !== '') return;
          } catch (_) {
            return;
          }
          const hasUnsafeControl = value => {
            for (let index = 0; index < value.length; index += 1) {
              const code = charCodeAt(value, index);
              if (code <= 0x1f || code === 0x7f) return true;
            }
            return false;
          };
          const pathIsSafeProjectDescendant = pathname => {
            if (!startsWith(pathname, trustedPathname)) return false;
            const relativePath = slice(pathname, trustedPathname.length);
            if (!relativePath) return false;
            const segments = split(relativePath, '/');
            for (let index = 0; index < segments.length; index += 1) {
              const segment = segments[index];
              if (!segment) {
                if (index === segments.length - 1 && index > 0) continue;
                return false;
              }
              let decoded;
              try {
                decoded = invoke(nativeDecodeURIComponent, undefined, [segment]);
              } catch (_) {
                return false;
              }
              if (!decoded || decoded === '.' || decoded === '..'
                  || indexOf(decoded, '/', 0) >= 0 || indexOf(decoded, '\\', 0) >= 0
                  || hasUnsafeControl(decoded)) return false;
            }
            return true;
          };
          const normalizeProjectFileURL = value => {
            if (typeof value !== 'string' || !startsWith(value, wrappedProjectPrefix)) {
              return value;
            }
            const embedded = slice(value, fileWrapper.length);
            if (indexOf(embedded, '\\', 0) >= 0
                || indexOf(embedded, '?', 0) >= 0
                || indexOf(embedded, '#', 0) >= 0
                || hasUnsafeControl(embedded)) return value;
            try {
              const candidate = new NativeURL(embedded);
              const href = readURL(urlHrefGetter, candidate);
              const pathname = readURL(urlPathnameGetter, candidate);
              if (readURL(urlProtocolGetter, candidate) !== trustedProtocol
                  || readURL(urlHostnameGetter, candidate) !== trustedHostname
                  || readURL(urlPortGetter, candidate) !== trustedPort
                  || readURL(urlOriginGetter, candidate) !== trustedOrigin
                  || readURL(urlUsernameGetter, candidate) !== ''
                  || readURL(urlPasswordGetter, candidate) !== ''
                  || !pathIsSafeProjectDescendant(pathname)) return value;
              return href;
            } catch (_) {
              return value;
            }
          };
          const isCSSWhitespace = code =>
            code === 0x09 || code === 0x0a || code === 0x0c || code === 0x0d || code === 0x20;
          const isCSSIdentifierCode = code =>
            (code >= 0x30 && code <= 0x39) || (code >= 0x41 && code <= 0x5a)
              || (code >= 0x61 && code <= 0x7a) || code === 0x2d || code === 0x5f
              || code >= 0x80;
          const findURLFunction = (value, start) => {
            for (let index = start; index + 3 < value.length; index += 1) {
              const first = charAt(value, index);
              const second = charAt(value, index + 1);
              const third = charAt(value, index + 2);
              if ((first === 'u' || first === 'U')
                  && (second === 'r' || second === 'R')
                  && (third === 'l' || third === 'L')
                  && charAt(value, index + 3) === '('
                  && (index === 0 || !isCSSIdentifierCode(charCodeAt(value, index - 1)))) {
                return index;
              }
            }
            return -1;
          };
          const normalizeCSSURLs = value => {
            if (typeof value !== 'string' || indexOf(value, wrappedProjectPrefix, 0) < 0) {
              return value;
            }
            let searchIndex = 0;
            let outputCursor = 0;
            let output = '';
            let changed = false;
            while (searchIndex < value.length) {
              const functionIndex = findURLFunction(value, searchIndex);
              if (functionIndex < 0) break;
              let cursor = functionIndex + 4;
              while (cursor < value.length && isCSSWhitespace(charCodeAt(value, cursor))) cursor += 1;
              let candidateStart = cursor;
              let candidateEnd = -1;
              let closingIndex = -1;
              let invalid = false;
              const quote = charAt(value, cursor);
              if (quote === '"' || quote === "'") {
                candidateStart = cursor + 1;
                cursor = candidateStart;
                while (cursor < value.length) {
                  const character = charAt(value, cursor);
                  if (character === '\\') {
                    invalid = true;
                    break;
                  }
                  if (character === quote) {
                    candidateEnd = cursor;
                    cursor += 1;
                    while (cursor < value.length && isCSSWhitespace(charCodeAt(value, cursor))) {
                      cursor += 1;
                    }
                    if (charAt(value, cursor) === ')') closingIndex = cursor;
                    break;
                  }
                  cursor += 1;
                }
              } else {
                while (cursor < value.length) {
                  const character = charAt(value, cursor);
                  if (character === ')' || isCSSWhitespace(charCodeAt(value, cursor))) break;
                  if (character === '\\' || character === '"' || character === "'"
                      || character === '(') {
                    invalid = true;
                    break;
                  }
                  cursor += 1;
                }
                candidateEnd = cursor;
                while (cursor < value.length && isCSSWhitespace(charCodeAt(value, cursor))) {
                  cursor += 1;
                }
                if (charAt(value, cursor) === ')') closingIndex = cursor;
              }
              if (!invalid && candidateEnd > candidateStart && closingIndex >= 0) {
                const candidate = slice(value, candidateStart, candidateEnd);
                const normalized = normalizeProjectFileURL(candidate);
                if (normalized !== candidate) {
                  output += slice(value, outputCursor, candidateStart) + normalized;
                  outputCursor = candidateEnd;
                  changed = true;
                }
              }
              searchIndex = closingIndex >= 0 ? closingIndex + 1 : functionIndex + 4;
            }
            return changed ? output + slice(value, outputCursor) : value;
          };
          const installSetterHook = (constructor, property, normalizer) => {
            const prototype = constructor && constructor.prototype;
            if (!prototype || typeof nativeGetOwnPropertyDescriptor !== 'function'
                || typeof nativeDefineProperty !== 'function') return;
            try {
              const descriptor = nativeGetOwnPropertyDescriptor(prototype, property);
              if (!descriptor || typeof descriptor.set !== 'function') return;
              nativeDefineProperty(prototype, property, {
                configurable: descriptor.configurable,
                enumerable: descriptor.enumerable,
                get: descriptor.get,
                set: function(value) {
                  return invoke(descriptor.set, this, [normalizer(value)]);
                }
              });
            } catch (_) {}
          };
          installSetterHook(NativeHTMLImageElement, 'src', normalizeProjectFileURL);
          installSetterHook(NativeHTMLMediaElement, 'src', normalizeProjectFileURL);
          installSetterHook(NativeHTMLSourceElement, 'src', normalizeProjectFileURL);
          installSetterHook(NativeHTMLVideoElement, 'poster', normalizeProjectFileURL);
          const stylePrototype = NativeCSSStyleDeclaration && NativeCSSStyleDeclaration.prototype;
          installSetterHook(NativeCSSStyleDeclaration, 'cssText', normalizeCSSURLs);
          installSetterHook(NativeCSSStyleDeclaration, 'background', normalizeCSSURLs);
          installSetterHook(NativeCSSStyleDeclaration, 'backgroundImage', normalizeCSSURLs);
          if (stylePrototype && typeof nativeGetOwnPropertyDescriptor === 'function'
              && typeof nativeDefineProperty === 'function') {
            try {
              const descriptor = nativeGetOwnPropertyDescriptor(stylePrototype, 'setProperty');
              if (descriptor && typeof descriptor.value === 'function') {
                nativeDefineProperty(stylePrototype, 'setProperty', {
                  configurable: descriptor.configurable,
                  enumerable: descriptor.enumerable,
                  writable: descriptor.writable,
                  value: function(...args) {
                    if (args.length > 1) args[1] = normalizeCSSURLs(args[1]);
                    return invoke(descriptor.value, this, args);
                  }
                });
              }
            } catch (_) {}
          }
          const htmlNamespace = 'http://www.w3.org/1999/xhtml';
          const elementKind = element => {
            if (!element || typeof localNameGetter !== 'function'
                || typeof namespaceURIGetter !== 'function') return '';
            try {
              if (invoke(namespaceURIGetter, element, []) !== htmlNamespace) return '';
              const name = invoke(localNameGetter, element, []);
              return typeof name === 'string' ? name : '';
            } catch (_) {
              return '';
            }
          };
          const passiveURLAttribute = (kind, attribute) =>
            (attribute === 'src'
              && (kind === 'img' || kind === 'audio' || kind === 'video' || kind === 'source'))
              || (attribute === 'poster' && kind === 'video');
          if (typeof originalSetAttribute === 'function' && window.Element
              && window.Element.prototype && typeof nativeGetOwnPropertyDescriptor === 'function'
              && typeof nativeDefineProperty === 'function') {
            try {
              const descriptor = nativeGetOwnPropertyDescriptor(
                window.Element.prototype,
                'setAttribute'
              );
              if (descriptor && typeof descriptor.value === 'function') {
                nativeDefineProperty(window.Element.prototype, 'setAttribute', {
                  configurable: descriptor.configurable,
                  enumerable: descriptor.enumerable,
                  writable: descriptor.writable,
                  value: function(...args) {
                    if (args.length > 1 && typeof args[0] === 'string') {
                      const attribute = lowercased(args[0]);
                      if (attribute === 'style') {
                        args[1] = normalizeCSSURLs(args[1]);
                      } else if (passiveURLAttribute(elementKind(this), attribute)) {
                        args[1] = normalizeProjectFileURL(args[1]);
                      }
                    }
                    return invoke(originalSetAttribute, this, args);
                  }
                });
              }
            } catch (_) {}
          }
          if (typeof nativeFetch === 'function' && typeof nativeGetOwnPropertyDescriptor === 'function'
              && typeof nativeDefineProperty === 'function') {
            try {
              const descriptor = nativeGetOwnPropertyDescriptor(window, 'fetch');
              if (descriptor && typeof descriptor.value === 'function') {
                nativeDefineProperty(window, 'fetch', {
                  configurable: descriptor.configurable,
                  enumerable: descriptor.enumerable,
                  writable: descriptor.writable,
                  value: function(...args) {
                    if (args.length > 0) args[0] = normalizeProjectFileURL(args[0]);
                    return invoke(nativeFetch, this, args);
                  }
                });
              }
            } catch (_) {}
          }
          const xhrPrototype = NativeXMLHttpRequest && NativeXMLHttpRequest.prototype;
          if (xhrPrototype && typeof nativeGetOwnPropertyDescriptor === 'function'
              && typeof nativeDefineProperty === 'function') {
            try {
              const descriptor = nativeGetOwnPropertyDescriptor(xhrPrototype, 'open');
              if (descriptor && typeof descriptor.value === 'function') {
                nativeDefineProperty(xhrPrototype, 'open', {
                  configurable: descriptor.configurable,
                  enumerable: descriptor.enumerable,
                  writable: descriptor.writable,
                  value: function(...args) {
                    if (args.length > 1) args[1] = normalizeProjectFileURL(args[1]);
                    return invoke(descriptor.value, this, args);
                  }
                });
              }
            } catch (_) {}
          }
          const normalizeElement = element => {
            if (!element || typeof nativeGetAttribute !== 'function'
                || typeof originalSetAttribute !== 'function') return;
            const kind = elementKind(element);
            if (!kind) return;
            const attributes = kind === 'video'
              ? ['src', 'poster']
              : (kind === 'img' || kind === 'audio' || kind === 'source') ? ['src'] : [];
            for (let index = 0; index < attributes.length; index += 1) {
              const attribute = attributes[index];
              try {
                const value = invoke(nativeGetAttribute, element, [attribute]);
                const normalized = normalizeProjectFileURL(value);
                if (normalized !== value) {
                  invoke(originalSetAttribute, element, [attribute, normalized]);
                }
              } catch (_) {}
            }
            try {
              const style = invoke(nativeGetAttribute, element, ['style']);
              const normalizedStyle = normalizeCSSURLs(style);
              if (normalizedStyle !== style) {
                invoke(originalSetAttribute, element, ['style', normalizedStyle]);
              }
            } catch (_) {}
          };
          const scan = root => {
            normalizeElement(root);
            let elements = [];
            try {
              if (root === nativeDocument && typeof nativeDocumentQuerySelectorAll === 'function') {
                elements = invoke(nativeDocumentQuerySelectorAll, root, [
                  'img[src],audio[src],video[src],video[poster],source[src],[style]'
                ]);
              } else if (root && typeof nativeElementQuerySelectorAll === 'function') {
                try {
                  elements = invoke(nativeElementQuerySelectorAll, root, [
                    'img[src],audio[src],video[src],video[poster],source[src],[style]'
                  ]);
                } catch (_) {
                  if (typeof nativeFragmentQuerySelectorAll === 'function') {
                    elements = invoke(nativeFragmentQuerySelectorAll, root, [
                      'img[src],audio[src],video[src],video[poster],source[src],[style]'
                    ]);
                  }
                }
              }
            } catch (_) {}
            for (let index = 0; index < elements.length; index += 1) normalizeElement(elements[index]);
          };
          nativeDefineProperty(window, '__backgroundEngineFileURLCompatibilityBridgeInstalled', {
            configurable: false,
            enumerable: false,
            writable: false,
            value: true
          });
          scan(nativeDocument);
          if (NativeMutationObserver) {
            try {
              const observer = new NativeMutationObserver(records => {
                for (let recordIndex = 0; recordIndex < records.length; recordIndex += 1) {
                  const record = records[recordIndex];
                  if (record.type === 'attributes') {
                    normalizeElement(record.target);
                    continue;
                  }
                  const addedNodes = record.addedNodes || [];
                  for (let nodeIndex = 0; nodeIndex < addedNodes.length; nodeIndex += 1) {
                    scan(addedNodes[nodeIndex]);
                  }
                }
              });
              observer.observe(nativeDocument, {
                childList: true,
                subtree: true,
                attributes: true,
                attributeFilter: ['src', 'poster', 'style']
              });
            } catch (_) {}
          }
        })();
        """#
    }
}

/// Wallpaper Engine projects commonly declare legacy Ogg/WebM containers in
/// a `<source type>` hint. WebKit is allowed to reject that hint before it
/// requests the URL, which would bypass the prepared MP4/M4A mapping in our
/// local HTTP origin. This document-start observer removes authored type hints
/// only for same-origin project resources; WebKit then requests the URL and
/// selects the validated MIME returned by the server. Attribute changes
/// are observed as well as inserted nodes because many wallpapers construct
/// or retarget their `<source>` elements after startup.
enum WebWallpaperMediaSourceBridge {
    static func bootstrapScript(preparedKindsByPath: [String: String] = [:]) -> String {
        let safeMappings = preparedKindsByPath.filter {
            $0.key.hasPrefix("/") && ($0.value == "video" || $0.value == "audio")
        }
        let mappingLiteral: String
        if let data = try? JSONSerialization.data(
            withJSONObject: safeMappings,
            options: [.sortedKeys]
        ), let value = String(data: data, encoding: .utf8) {
            mappingLiteral = value
        } else {
            mappingLiteral = "{}"
        }
        return #"""
    (() => {
      if (window.__backgroundEngineMediaSourceBridgeInstalled) return;
      const NativeMutationObserver = window.MutationObserver;
      const NativeURL = window.URL;
      const NativeHTMLMediaElement = window.HTMLMediaElement;
      const NativeHTMLSourceElement = window.HTMLSourceElement;
      const nativeDocument = document;
      const nativeGetAttribute = window.Element && window.Element.prototype.getAttribute;
      const nativeSetAttribute = window.Element && window.Element.prototype.setAttribute;
      const nativeRemoveAttribute = window.Element && window.Element.prototype.removeAttribute;
      const nativeQuerySelectorAll = window.Document && window.Document.prototype.querySelectorAll;
      const nativeElementQuerySelectorAll = window.Element && window.Element.prototype.querySelectorAll;
      const nativeFragmentQuerySelectorAll = window.DocumentFragment
        && window.DocumentFragment.prototype.querySelectorAll;
      const nativeReflectApply = Reflect.apply;
      const nativeDefineProperty = Object.defineProperty;
      const nativeGetOwnPropertyDescriptor = Object.getOwnPropertyDescriptor;
      const canonicalPreparedLookupPath = value => String(value || '').replace(
        /%[0-9a-f]{2}/gi,
        encoded => {
          const code = parseInt(encoded.slice(1), 16);
          const isUnreserved = (code >= 0x41 && code <= 0x5a)
            || (code >= 0x61 && code <= 0x7a)
            || (code >= 0x30 && code <= 0x39)
            || code === 0x2d || code === 0x2e || code === 0x5f || code === 0x7e;
          return isUnreserved
            ? String.fromCharCode(code)
            : '%' + encoded.slice(1).toUpperCase();
        }
      );
      const serializedPreparedKindsByPath = \#(mappingLiteral);
      const normalizedPreparedKindsByPath = Object.create(null);
      for (const mappingPath of Object.keys(serializedPreparedKindsByPath)) {
        normalizedPreparedKindsByPath[canonicalPreparedLookupPath(mappingPath)]
          = serializedPreparedKindsByPath[mappingPath];
      }
      const preparedKindsByPath = Object.freeze(
        normalizedPreparedKindsByPath
      );
      const preparedKindByElement = typeof WeakMap === 'function' ? new WeakMap() : null;
      const preparedKindForPath = pathname => {
        const canonicalPath = canonicalPreparedLookupPath(pathname);
        const directKind = preparedKindsByPath[canonicalPath] || '';
        if (directKind) return directKind;
        const parts = canonicalPath.split('/');
        if (parts.length <= 5 || parts[0] !== '' || !parts[1]
            || parts[2] !== '__background_engine_prepared'
            || (parts[3] !== 'video' && parts[3] !== 'audio')
            || parts[4] !== 'project') return '';
        const kind = parts[3];
        const suffix = kind === 'video'
          ? '.__background_engine_prepared.mp4'
          : '.__background_engine_prepared.m4a';
        const authoredParts = parts.slice(5);
        const finalPart = authoredParts[authoredParts.length - 1] || '';
        if (!finalPart.endsWith(suffix)) return '';
        authoredParts[authoredParts.length - 1]
          = finalPart.slice(0, finalPart.length - suffix.length);
        const authoredPath = '/' + parts[1] + '/project/' + authoredParts.join('/');
        return preparedKindsByPath[canonicalPreparedLookupPath(authoredPath)] === kind
          ? kind
          : '';
      };
      const invoke = (functionValue, receiver, argumentsList) =>
        nativeReflectApply(functionValue, receiver, argumentsList);
      let projectOrigin = '';
      let projectHost = '';
      let projectPathPrefix = '';
      try {
        const base = new NativeURL(nativeDocument.baseURI);
        projectOrigin = base.origin || '';
        projectHost = base.host || '';
        const parts = (base.pathname || '').split('/');
        if (base.protocol === 'background-engine-web:') {
          projectPathPrefix = '/project/';
        } else if (base.protocol === 'http:' && base.hostname === '127.0.0.1'
            && parts.length > 3 && parts[1] && parts[2] === 'project') {
          projectPathPrefix = '/' + parts[1] + '/project/';
        }
      } catch (_) {}
      const normalize = element => {
        const tagName = String((element && element.tagName) || '').toLowerCase();
        if (!element || (tagName !== 'source' && tagName !== 'video' && tagName !== 'audio')
            || typeof nativeGetAttribute !== 'function'
            || typeof nativeRemoveAttribute !== 'function'
            || typeof NativeURL !== 'function') return;
        try {
          const rawType = invoke(nativeGetAttribute, element, ['type']);
          const rawSource = invoke(nativeGetAttribute, element, ['src']);
          if (typeof rawSource !== 'string') return;
          const resolved = new NativeURL(rawSource, nativeDocument.baseURI);
          const sourceParts = resolved.pathname.split('/');
          let preparedKind = preparedKindForPath(resolved.pathname);
          if (!preparedKind && preparedKindByElement && sourceParts.length > 5
              && sourceParts[2] === '__background_engine_prepared'
              && (sourceParts[3] === 'video' || sourceParts[3] === 'audio')
              && sourceParts[4] === 'project') {
            const cachedKind = preparedKindByElement.get(element) || '';
            const cachedSuffix = cachedKind === 'video'
              ? '.__background_engine_prepared.mp4'
              : cachedKind === 'audio'
                ? '.__background_engine_prepared.m4a'
                : '';
            if (cachedSuffix && resolved.pathname.endsWith(cachedSuffix)) {
              preparedKind = cachedKind;
            }
          }
          const preparedAliasSuffix = preparedKind === 'video'
            ? '.__background_engine_prepared.mp4'
            : preparedKind === 'audio'
              ? '.__background_engine_prepared.m4a'
              : '';
          const isPreparedAliasPath = preparedAliasSuffix.length > 0
            && resolved.pathname.endsWith(preparedAliasSuffix)
            && sourceParts.length > 5
            && sourceParts[2] === '__background_engine_prepared'
            && sourceParts[3] === preparedKind
            && sourceParts[4] === 'project';
          // The scheme handler returns the validated MIME for both authored
          // and normalized media. Removing a same-origin hint lets WebKit ask
          // the handler instead of rejecting legacy/unknown containers before
          // it requests their successfully prepared MP4/M4A replacement.
          const isProjectProtocol = resolved.protocol === 'background-engine-web:'
            && resolved.host === projectHost;
          const isLoopbackHTTP = resolved.protocol === 'http:'
            && resolved.hostname === '127.0.0.1'
            && resolved.origin === projectOrigin;
          const pathIsTrusted = (projectPathPrefix.length > 0
              && resolved.pathname.indexOf(projectPathPrefix) === 0)
            || (isLoopbackHTTP && isPreparedAliasPath);
          if ((isProjectProtocol || isLoopbackHTTP) && pathIsTrusted) {
            // URL.pathname preserves percent-encoded unreserved characters,
            // while the server's canonical URL uses their literal spelling.
            // Normalize only RFC 3986 unreserved bytes. Reserved separators
            // such as `%2F`/`%5C` remain encoded and can never alias a path.
            if (preparedKind && preparedKindByElement) {
              preparedKindByElement.set(element, preparedKind);
            }
            const aliasSuffix = preparedAliasSuffix;
            // WebKit may reject a legacy authored extension (for example
            // `.ogv`) before issuing HTTP. A same-origin alias with the
            // prepared output extension forces normal HTTP probing; the
            // loopback server accepts this suffix only under its reserved
            // prepared route and only when the exact original source has a
            // pinned mapping. Authored filenames can therefore never collide.
            const alreadyAliased = aliasSuffix.length > 0
              && resolved.pathname.endsWith(aliasSuffix)
              && sourceParts.length > 5
              && sourceParts[2] === '__background_engine_prepared'
              && sourceParts[3] === preparedKind
              && sourceParts[4] === 'project';
            if (isLoopbackHTTP && aliasSuffix.length > 0 && !alreadyAliased
                && typeof nativeSetAttribute === 'function'
                && sourceParts.length > 3 && sourceParts[1]
                && sourceParts[2] === 'project') {
              resolved.pathname = '/' + sourceParts[1]
                + '/__background_engine_prepared/' + preparedKind
                + '/project/' + sourceParts.slice(3).join('/') + aliasSuffix;
              invoke(nativeSetAttribute, element, ['src', resolved.href]);
            }
            if (aliasSuffix.length > 0
                && typeof rawType === 'string' && rawType.trim().length > 0) {
              invoke(nativeRemoveAttribute, element, ['type']);
            }
          }
        } catch (_) {}
      };
      const scan = root => {
        normalize(root);
        let sources = [];
        try {
          if (root === nativeDocument && typeof nativeQuerySelectorAll === 'function') {
            sources = invoke(nativeQuerySelectorAll, root, ['video[src],audio[src],source[src]']);
          } else if (root && typeof nativeElementQuerySelectorAll === 'function'
              && window.Element.prototype.isPrototypeOf(root)) {
            sources = invoke(nativeElementQuerySelectorAll, root, ['video[src],audio[src],source[src]']);
          } else if (root && typeof nativeFragmentQuerySelectorAll === 'function'
              && window.DocumentFragment.prototype.isPrototypeOf(root)) {
            sources = invoke(nativeFragmentQuerySelectorAll, root, ['video[src],audio[src],source[src]']);
          }
        } catch (_) {}
        for (let index = 0; index < sources.length; index += 1) normalize(sources[index]);
      };
      const installSourceSetterHook = constructor => {
        const prototype = constructor && constructor.prototype;
        if (!prototype || typeof nativeGetOwnPropertyDescriptor !== 'function'
            || typeof nativeDefineProperty !== 'function') return;
        try {
          const descriptor = nativeGetOwnPropertyDescriptor(prototype, 'src');
          if (!descriptor || typeof descriptor.set !== 'function') return;
          nativeDefineProperty(prototype, 'src', {
            configurable: descriptor.configurable,
            enumerable: descriptor.enumerable,
            get: descriptor.get,
            set: function(value) {
              const result = invoke(descriptor.set, this, [value]);
              normalize(this);
              return result;
            }
          });
        } catch (_) {}
      };
      const installMediaMethodHook = name => {
        const prototype = NativeHTMLMediaElement && NativeHTMLMediaElement.prototype;
        if (!prototype || typeof nativeGetOwnPropertyDescriptor !== 'function'
            || typeof nativeDefineProperty !== 'function') return;
        try {
          const descriptor = nativeGetOwnPropertyDescriptor(prototype, name);
          if (!descriptor || typeof descriptor.value !== 'function') return;
          nativeDefineProperty(prototype, name, {
            configurable: descriptor.configurable,
            enumerable: descriptor.enumerable,
            writable: descriptor.writable,
            value: function(...args) {
              scan(this);
              return invoke(descriptor.value, this, args);
            }
          });
        } catch (_) {}
      };
      if (typeof nativeSetAttribute === 'function'
          && window.Element && window.Element.prototype
          && typeof nativeGetOwnPropertyDescriptor === 'function'
          && typeof nativeDefineProperty === 'function') {
        try {
          const descriptor = nativeGetOwnPropertyDescriptor(
            window.Element.prototype,
            'setAttribute'
          );
          if (descriptor && typeof descriptor.value === 'function') {
            nativeDefineProperty(window.Element.prototype, 'setAttribute', {
              configurable: descriptor.configurable,
              enumerable: descriptor.enumerable,
              writable: descriptor.writable,
              value: function(name, value) {
                const result = invoke(nativeSetAttribute, this, [name, value]);
                const attributeName = String(name || '').toLowerCase();
                if (attributeName === 'src' || attributeName === 'type') normalize(this);
                return result;
              }
            });
          }
        } catch (_) {}
      }
      installSourceSetterHook(NativeHTMLMediaElement);
      installSourceSetterHook(NativeHTMLSourceElement);
      installMediaMethodHook('load');
      installMediaMethodHook('play');
      nativeDefineProperty(window, '__backgroundEngineMediaSourceBridgeInstalled', {
        configurable: false,
        enumerable: false,
        writable: false,
        value: true
      });
      scan(nativeDocument);
      if (NativeMutationObserver) {
        try {
          const observer = new NativeMutationObserver(records => {
            for (let recordIndex = 0; recordIndex < records.length; recordIndex += 1) {
              const record = records[recordIndex];
              if (record.type === 'attributes') {
                normalize(record.target);
                continue;
              }
              const addedNodes = record.addedNodes || [];
              for (let nodeIndex = 0; nodeIndex < addedNodes.length; nodeIndex += 1) {
                scan(addedNodes[nodeIndex]);
              }
            }
          });
          observer.observe(nativeDocument, {
            childList: true,
            subtree: true,
            attributes: true,
            attributeFilter: ['src', 'type']
          });
        } catch (_) {}
      }
    })();
    """#
    }
}

enum WebWallpaperLocalNetworkPolicy {
    /// Blocks ambient local/private HTTP targets for a wallpaper that opted
    /// into the public internet, then exempts only its exact per-view
    /// loopback port. URL filtering also covers literal localhost,
    /// IPv4 private/link-local/CGNAT and IPv6 loopback/private/link-local
    /// origins. Hostname-based DNS rebinding remains an acknowledged residual
    /// limitation of URL-pattern filtering; the trusted listener separately
    /// enforces its exact numeric Host header, port, and secret URL path.
    static func encodedRules(trustedLoopbackPort: UInt16?) throws -> String {
        if let trustedLoopbackPort, trustedLoopbackPort == 0 {
            throw WebProjectResourceError.invalidVirtualURL
        }
        // WebKit's content-blocker regex subset does not support alternation,
        // so each private range is intentionally a separate rule.
        let privateHTTPOriginPatterns = WebWallpaperNetworkPolicy.blockedHTTPOriginPatterns
        let privateWebSocketOriginPatterns = privateHTTPOriginPatterns.map { pattern in
            pattern.replacingOccurrences(of: "^https?://", with: "^wss?://")
        }
        var rules: [[String: Any]] = (privateHTTPOriginPatterns + privateWebSocketOriginPatterns).map { pattern in
            [
                "trigger": [
                    "url-filter": pattern,
                    "url-filter-is-case-sensitive": false
                ],
                "action": ["type": "block"]
            ]
        }
        if let trustedLoopbackPort {
            // The ephemeral port identifies this view. The secret path token
            // is deliberately absent so WebKit's compiled-rule store never
            // serializes it; the HTTP server still authenticates every URL.
            rules.append([
                "trigger": [
                    "url-filter": "^http://127\\.0\\.0\\.1:\(trustedLoopbackPort)/",
                    "url-filter-is-case-sensitive": true
                ],
                "action": ["type": "ignore-previous-rules"]
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw WebProjectResourceError.invalidVirtualURL
        }
        return encoded
    }

    /// Out-of-band network denylist for an offline local project. Server CSP
    /// remains useful, but a same-origin service worker can synthesize a new
    /// response without those headers. The WebKit content rule therefore
    /// blocks every HTTP/WebSocket request and re-allows only this view's exact
    /// ephemeral loopback origin; the server still authenticates its secret
    /// path token and strict Host header.
    static func encodedOfflineRules(trustedLoopbackPort: UInt16?) throws -> String {
        if let trustedLoopbackPort, trustedLoopbackPort == 0 {
            throw WebProjectResourceError.invalidVirtualURL
        }
        var rules: [[String: Any]] = ["^https?://.*", "^wss?://.*"].map { pattern in
            [
                "trigger": [
                    "url-filter": pattern,
                    "url-filter-is-case-sensitive": false
                ],
                "action": ["type": "block"]
            ]
        }
        if let trustedLoopbackPort {
            rules.append([
                "trigger": [
                    "url-filter": "^http://127\\.0\\.0\\.1:\(trustedLoopbackPort)/",
                    "url-filter-is-case-sensitive": true
                ],
                "action": ["type": "ignore-previous-rules"]
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw WebProjectResourceError.invalidVirtualURL
        }
        return encoded
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
      const NativeWeakRef = window.WeakRef;
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
      const nativeWeakMapDelete = WeakMap.prototype.delete;
      const nativeWeakRefDeref = NativeWeakRef && NativeWeakRef.prototype
        && NativeWeakRef.prototype.deref;
      const nativePromiseResolve = Promise.resolve;
      const nativePromiseThen = Promise.prototype.then;
      const invoke = (functionValue, receiver, argumentsList) =>
        nativeReflectApply(functionValue, receiver, argumentsList);
      const weakGet = (map, key) => invoke(nativeWeakMapGet, map, [key]);
      const weakSet = (map, key, value) => invoke(nativeWeakMapSet, map, [key, value]);
      const weakHas = (map, key) => invoke(nativeWeakMapHas, map, [key]);
      const weakDelete = (map, key) => invoke(nativeWeakMapDelete, map, [key]);
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
      const usesWeakMediaReferences = typeof NativeWeakRef === 'function'
        && typeof nativeWeakRefDeref === 'function';
      const maximumStrongMediaReferences = 256;
      const makeMediaReference = element => usesWeakMediaReferences
        ? nativeReflectConstruct(NativeWeakRef, [element])
        : element;
      const mediaFromReference = reference => usesWeakMediaReferences
        ? invoke(nativeWeakRefDeref, reference, [])
        : reference;

      const silenceMedia = element => {
        if (!element || !nativeMuted || !nativeVolume) return;
        try {
          invoke(nativeMuted.set, element, [true]);
          invoke(nativeVolume.set, element, [0]);
        } catch (_) {}
      };
      const makeRoomForStrongMediaReference = () => {
        if (usesWeakMediaReferences || gate.media.length < maximumStrongMediaReferences) return;
        const evictedElement = gate.media[0];
        if (evictedElement) {
          weakDelete(gate.mediaState, evictedElement);
          silenceMedia(evictedElement);
        }
        for (let index = 1; index < gate.media.length; index += 1) {
          gate.media[index - 1] = gate.media[index];
        }
        gate.media.length -= 1;
      };

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
        makeRoomForStrongMediaReference();
        gate.media[gate.media.length] = makeMediaReference(element);
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
          const reference = gate.media[index];
          const element = mediaFromReference(reference);
          if (!element) continue;
          if (!weakHas(gate.mediaState, element)) continue;
          applyMedia(element);
          retainedMedia[retainedMedia.length] = reference;
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

struct WebMediaPreparationWarningPresentation: Equatable, Sendable {
    let message: String
    let automaticallyDismisses: Bool

    static func make(
        failureCount: Int,
        noticeCount: Int = 0,
        allLocalPreparationFailed: Bool
    ) -> WebMediaPreparationWarningPresentation? {
        guard failureCount > 0 || noticeCount > 0 else { return nil }
        if allLocalPreparationFailed {
            return WebMediaPreparationWarningPresentation(
                message: "Local media could not be prepared. The page may use another "
                    + "authored source. Replay the wallpaper or clear Web Media Cache to retry.",
                automaticallyDismisses: false
            )
        }
        if failureCount == 0 {
            return WebMediaPreparationWarningPresentation(
                message: "Local media discovery reached its safety limit. The wallpaper is "
                    + "continuing with the bounded set of eligible sources.",
                automaticallyDismisses: true
            )
        }
        if noticeCount > 0 {
            return WebMediaPreparationWarningPresentation(
                message: "Some local media could not be prepared, and discovery reached its "
                    + "safety limit. The wallpaper is continuing with available sources.",
                automaticallyDismisses: true
            )
        }
        return WebMediaPreparationWarningPresentation(
            message: "Some local media could not be prepared. The wallpaper is continuing "
                + "with available authored sources.",
            automaticallyDismisses: true
        )
    }
}

@MainActor
protocol WebWallpaperButtonEventReceiving: AnyObject {
    @discardableResult
    func dispatchWebButtonEvent(_ event: WebWallpaperButtonEvent) async -> Bool
}

/// Resolves a WebKit callback or its deadline exactly once. WebKit normally
/// calls back promptly, but a wedged/restarting content process must not leave
/// the property editor waiting forever.
private final class WebButtonJavaScriptResolution: @unchecked Sendable {
    private let lock = NSLock()
    private var isResolved = false
    private let continuation: CheckedContinuation<Bool, Never>

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resolve(_ value: Bool) {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        lock.unlock()
        continuation.resume(returning: value)
    }
}

@MainActor
final class RestrictedWebWallpaperView: NSView,
    WKNavigationDelegate,
    PausableWallpaperContent,
    AudioControllableWallpaperContent,
    WebWallpaperButtonEventReceiving,
    WallpaperContentLifecycle {
    private let webView: PlashWebView
    private let url: URL
    private let readAccessURL: URL
    private let networkAccessAllowed: Bool
    private let remoteConfiguration: RemoteWebWallpaperConfiguration?
    private let localLoopbackServer: WebProjectLoopbackServer?
    private let localEntrypointURL: URL?
    private let localSetupFailureMessage: String?
    private let mediaRuntimeCoordinator: WebMediaRuntimeCoordinator
    private let mediaPlaybackScope: PlaybackLifecycleScope
    private let audioControlToken: String
    private var failureLabel: NSTextField?
    private var mediaPreparationWarningLabel: NSTextField?
    private var pendingMediaPreparationWarning: WebMediaPreparationWarningPresentation?
    private var mediaPreparationTask: Task<Void, Never>?
    private var mediaPreparationWarningDismissTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryBudgetResetTask: Task<Void, Never>?
    private var nativeMediaSuspensionTask: Task<Void, Never>?
    private var localNetworkRuleIdentifier: String?
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
        audioVolume: Double = 0.5,
        mediaRuntimeCoordinator: WebMediaRuntimeCoordinator = .shared
    ) {
        self.url = url
        self.readAccessURL = readAccessURL
        self.networkAccessAllowed = networkAccessAllowed
        self.audioEnabled = audioEnabled
        self.audioVolume = min(max(audioVolume.isFinite ? audioVolume : 0, 0), 1)
        self.mediaRuntimeCoordinator = mediaRuntimeCoordinator
        mediaPlaybackScope = mediaRuntimeCoordinator.makePlaybackScope()
        audioControlToken = UUID().uuidString
        let remoteConfigurationState = RemoteWebWallpaperConfiguration.state(
            projectRoot: readAccessURL
        )
        let loadedRemoteConfiguration: RemoteWebWallpaperConfiguration?
        if case .valid(let configuration) = remoteConfigurationState {
            loadedRemoteConfiguration = configuration
        } else {
            loadedRemoteConfiguration = nil
        }
        remoteConfiguration = loadedRemoteConfiguration
        let localSetup: (
            server: WebProjectLoopbackServer?,
            entrypoint: URL?,
            failure: String?
        )
        switch remoteConfigurationState {
        case .valid:
            localSetup = (nil, nil, nil)
        case .invalid:
            localSetup = (
                nil,
                nil,
                "This website wallpaper has invalid or legacy remote metadata. "
                    + "Re-import it using an HTTPS URL."
            )
        case .absent:
            do {
                let server = try WebProjectLoopbackServer(
                    projectRoot: readAccessURL,
                    networkAccessAllowed: networkAccessAllowed
                )
                localSetup = (server, try server.virtualURL(for: url), nil)
            } catch {
                localSetup = (
                    nil,
                    nil,
                    "This local Web wallpaper failed secure file validation and was not loaded."
                )
            }
        }
        localLoopbackServer = localSetup.server
        localEntrypointURL = localSetup.entrypoint
        localSetupFailureMessage = localSetup.failure
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "development"
        let configuration = PlashRuntime.makeConfiguration(
            applicationName: "Background Engine/\(version)",
            usesPersistentWebsiteData: false
        )
        var properties = WebWallpaperCompatibilityBridge.defaultProperties(projectRoot: readAccessURL)
        let fileProperties = WebWallpaperCompatibilityBridge.fileProperties(
            projectRoot: readAccessURL
        )
        let comboDisplayTexts = WebWallpaperCompatibilityBridge.comboDisplayTexts(
            projectRoot: readAccessURL
        )
        var directories = WebWallpaperCompatibilityBridge.directoryProperties(
            projectRoot: readAccessURL
        )
        if let localLoopbackServer {
            let mapped = WebWallpaperVirtualURLBridge.remap(
                properties: properties,
                fileProperties: fileProperties,
                directories: directories,
                using: localLoopbackServer
            )
            properties = mapped.properties
            directories = mapped.directories
            if !fileProperties.isEmpty {
                let trustedProjectURLPrefix = localLoopbackServer.originURL
                    .appendingPathComponent(
                        WebProjectResourceResolver.projectPathComponent,
                        isDirectory: true
                    )
                configuration.userContentController.addUserScript(
                    WKUserScript(
                        source: WebWallpaperFileURLCompatibilityBridge.bootstrapScript(
                            trustedProjectURLPrefix: trustedProjectURLPrefix
                        ),
                        injectionTime: .atDocumentStart,
                        forMainFrameOnly: true
                    )
                )
            }
        } else {
            let redacted = WebWallpaperVirtualURLBridge.redactingHostPaths(
                properties: properties,
                fileProperties: fileProperties,
                directories: directories
            )
            properties = redacted.properties
            directories = redacted.directories
        }
        let livelyProperties = WebWallpaperCompatibilityBridge.livelyCallbackProperties(
            projectRoot: readAccessURL,
            mappedValues: properties
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: WebWallpaperCompatibilityBridge.bootstrapScript(
                    properties: properties,
                    comboDisplayTexts: comboDisplayTexts,
                    livelyProperties: livelyProperties,
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
        prepareLocalMediaAndLoad()
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

    @discardableResult
    func dispatchWebButtonEvent(_ event: WebWallpaperButtonEvent) async -> Bool {
        guard !isClosed else { return false }
        // Reuse one token while waiting for a listener. If an evaluation
        // finishes after its native deadline, the per-document Set prevents a
        // retry from invoking the one-shot callback twice.
        let script = WebWallpaperButtonEventScript.source(
            for: event,
            deliveryID: UUID().uuidString
        )
        for attempt in 0..<20 {
            guard !isClosed, !Task.isCancelled else { return false }
            if await evaluateButtonJavaScript(script) { return true }
            guard attempt < 19 else { break }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return false
            }
        }
        return false
    }

    private func evaluateButtonJavaScript(_ script: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let resolution = WebButtonJavaScriptResolution(continuation)
            webView.evaluateJavaScript(script) { result, error in
                let accepted = error == nil
                    && ((result as? Bool) == true || (result as? NSNumber)?.boolValue == true)
                resolution.resolve(accepted)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(250)) {
                resolution.resolve(false)
            }
        }
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
        mediaPreparationTask?.cancel()
        mediaPreparationTask = nil
        mediaPreparationWarningDismissTask?.cancel()
        mediaPreparationWarningDismissTask = nil
        pendingMediaPreparationWarning = nil
        mediaPreparationWarningLabel?.removeFromSuperview()
        mediaPreparationWarningLabel = nil
        nativeMediaSuspensionTask?.cancel()
        nativeMediaSuspensionTask = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        removeLocalNetworkRuleFromStore()
        localLoopbackServer?.stopAsync()
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
            trustedLocalMainFrameURL: nil,
            trustedVirtualMainFrameURL: nil,
            trustedLoopbackMainFrameURL: localEntrypointURL,
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
            trustedLocalMainFrameURL: nil,
            trustedVirtualMainFrameURL: nil,
            trustedLoopbackMainFrameURL: localEntrypointURL,
            trustedRemoteMainFrameURL: remoteConfiguration?.targetURL
        )
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !isClosed else { return }
        showFailure("This Web wallpaper could not be loaded: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !isClosed else { return }
        showFailure("This Web wallpaper could not be loaded: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !isClosed else { return }
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
        guard !isClosed else { return }
        failureLabel?.removeFromSuperview()
        failureLabel = nil
        presentPendingMediaPreparationWarning()
        applyPlaybackSuspension()
        applyAudioSettings()
        scheduleRecoveryBudgetReset()
    }

    private func installRemoteBlockerAndLoad(
        trustedLoopbackServer: WebProjectLoopbackServer? = nil
    ) {
        let rules: String
        do {
            rules = try WebWallpaperLocalNetworkPolicy.encodedOfflineRules(
                trustedLoopbackPort: trustedLoopbackServer?.port
            )
        } catch {
            showFailure("Background Engine could not create the offline Web security rules.")
            return
        }
        installContentRulesAndLoad(
            rules,
            identifierPrefix: "OfflineBoundary",
            failureMessage: "Background Engine could not install the offline Web security rules. "
                + "Enable network access for this wallpaper or replay it to retry."
        )
    }

    private func prepareLocalMediaAndLoad() {
        if let localSetupFailureMessage {
            showFailure(localSetupFailureMessage)
            return
        }
        guard remoteConfiguration == nil else {
            installAudioBridgeUserScript()
            installNetworkPolicyAndLoad()
            return
        }
        guard let localLoopbackServer else {
            showFailure("This local Web wallpaper could not be opened securely.")
            return
        }
        showFailure("Preparing this Web wallpaper's local media…")
        let entrypoint = url
        let projectRoot = readAccessURL
        let coordinator = mediaRuntimeCoordinator
        let lifecycleScope = mediaPlaybackScope
        mediaPreparationTask = Task { @MainActor [weak self, localLoopbackServer] in
            do {
                let resources = try await coordinator.prepareResources(
                    entrypoint: entrypoint,
                    projectRoot: projectRoot,
                    lifecycleScope: lifecycleScope
                )
                defer { resources.releaseCacheHandoff() }
                try Task.checkCancellation()
                guard let self, !self.isClosed else { return }
                let preparedProjectResources = resources.map {
                    WebProjectPreparedResource(
                        sourceURL: $0.sourceURL,
                        preparedURL: $0.preparedURL,
                        mimeType: $0.mimeType
                    )
                }
                try localLoopbackServer.installPreparedResources(
                    preparedProjectResources,
                    mimeTypeOverrides: resources.localResourceMIMEOverrides
                )
                var preparedKindsByPath = [String: String]()
                for resource in preparedProjectResources {
                    let sourceURL = try localLoopbackServer.virtualURL(
                        for: resource.sourceURL
                    )
                    guard let sourcePath = URLComponents(
                        url: sourceURL,
                        resolvingAgainstBaseURL: false
                    )?.percentEncodedPath else {
                        throw WebProjectResourceError.invalidVirtualURL
                    }
                    preparedKindsByPath[sourcePath] = resource.mimeType.hasPrefix("video/")
                        ? "video"
                        : "audio"
                }
                self.webView.configuration.userContentController.addUserScript(
                    WKUserScript(
                        source: WebWallpaperMediaSourceBridge.bootstrapScript(
                            preparedKindsByPath: preparedKindsByPath
                        ),
                        injectionTime: .atDocumentStart,
                        forMainFrameOnly: false
                    )
                )
                // The audio bridge deliberately seals HTMLMediaElement.play
                // against page tampering. Install it after the source bridge
                // so its sealed wrapper invokes source normalization first,
                // including for media that has not entered the DOM yet.
                self.installAudioBridgeUserScript()
                self.stageMediaPreparationWarning(
                    failureCount: resources.failures.count,
                    noticeCount: resources.notices.count,
                    allLocalPreparationFailed: resources.isEmpty
                        && !resources.failures.isEmpty
                )
                self.mediaPreparationTask = nil
                self.installNetworkPolicyAndLoad()
            } catch is CancellationError {
                // Closing one display removes only its coordinator waiter. A
                // shared conversion continues while another display needs it.
                guard let self, !self.isClosed else { return }
                self.mediaPreparationTask = nil
                self.showFailure(
                    "Preparing this Web wallpaper was interrupted. Replay it to retry."
                )
            } catch {
                guard let self, !self.isClosed else { return }
                self.mediaPreparationTask = nil
                self.showFailure(
                    "Background Engine could not prepare this Web wallpaper's local media: "
                        + error.localizedDescription
                )
            }
        }
    }

    private func installAudioBridgeUserScript() {
        webView.configuration.userContentController.addUserScript(
            WKUserScript(
                source: WebWallpaperAudioBridge.bootstrapScript(
                    controlToken: audioControlToken
                ),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
    }

    private func installNetworkPolicyAndLoad() {
        if networkAccessAllowed {
            installPrivateNetworkBoundaryAndLoad(trustedLoopbackServer: localLoopbackServer)
        } else if let localLoopbackServer {
            installRemoteBlockerAndLoad(trustedLoopbackServer: localLoopbackServer)
        } else {
            installRemoteBlockerAndLoad()
        }
    }

    private func installPrivateNetworkBoundaryAndLoad(
        trustedLoopbackServer: WebProjectLoopbackServer?
    ) {
        let rules: String
        do {
            rules = try WebWallpaperLocalNetworkPolicy.encodedRules(
                trustedLoopbackPort: trustedLoopbackServer?.port
            )
        } catch {
            showFailure("Background Engine could not create the local network security rules.")
            return
        }
        installContentRulesAndLoad(
            rules,
            identifierPrefix: "LocalBoundary",
            failureMessage: "Background Engine could not install the local network security rules. "
                + "Replay this wallpaper to retry."
        )
    }

    private func installContentRulesAndLoad(
        _ rules: String,
        identifierPrefix: String,
        failureMessage: String
    ) {
        let identifier = "com.lamppkk.backgroundengine.\(identifierPrefix).\(UUID().uuidString)"
        guard let store = WKContentRuleListStore.default() else {
            showFailure("Background Engine could not open the local network security rule store.")
            return
        }
        localNetworkRuleIdentifier = identifier
        store.compileContentRuleList(
            forIdentifier: identifier,
            encodedContentRuleList: rules
        ) { [weak self] ruleList, error in
            DispatchQueue.main.async {
                guard let self, !self.isClosed,
                      self.localNetworkRuleIdentifier == identifier else {
                    store.removeContentRuleList(forIdentifier: identifier) { _ in }
                    return
                }
                guard error == nil, let ruleList else {
                    self.localNetworkRuleIdentifier = nil
                    store.removeContentRuleList(forIdentifier: identifier) { _ in }
                    self.showFailure(failureMessage)
                    return
                }
                self.webView.configuration.userContentController.add(ruleList)
                self.loadProject()
            }
        }
    }

    private func removeLocalNetworkRuleFromStore() {
        guard let identifier = localNetworkRuleIdentifier else { return }
        localNetworkRuleIdentifier = nil
        WKContentRuleListStore.default()?.removeContentRuleList(
            forIdentifier: identifier
        ) { _ in }
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
        } else if let localEntrypointURL {
            webView.load(URLRequest(
                url: localEntrypointURL,
                cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                timeoutInterval: 30
            ))
        } else {
            showFailure("This local Web wallpaper could not be opened securely.")
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
        guard !isClosed else { return }
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

    /// Preparation failures are advisory: HTML may still select a direct,
    /// remote, image/canvas, or JavaScript-authored fallback. Store only a
    /// path-free summary here; `didFinish` presents it after confirming that
    /// the authored page loaded successfully.
    private func stageMediaPreparationWarning(
        failureCount: Int,
        noticeCount: Int,
        allLocalPreparationFailed: Bool
    ) {
        guard !isClosed else {
            pendingMediaPreparationWarning = nil
            return
        }
        pendingMediaPreparationWarning = WebMediaPreparationWarningPresentation.make(
            failureCount: failureCount,
            noticeCount: noticeCount,
            allLocalPreparationFailed: allLocalPreparationFailed
        )
    }

    private func presentPendingMediaPreparationWarning() {
        guard let presentation = pendingMediaPreparationWarning, !isClosed else { return }
        pendingMediaPreparationWarning = nil
        mediaPreparationWarningDismissTask?.cancel()
        mediaPreparationWarningDismissTask = nil
        mediaPreparationWarningLabel?.removeFromSuperview()
        mediaPreparationWarningLabel = nil
        let label = NSTextField(wrappingLabelWithString: presentation.message)
        label.identifier = NSUserInterfaceItemIdentifier(
            "BackgroundEngine.WebMediaPreparationWarning"
        )
        label.toolTip = presentation.message
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.alignment = .center
        label.textColor = .labelColor
        label.drawsBackground = true
        label.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.88)
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityLabel("Web media preparation warning")
        label.setAccessibilityValue(presentation.message)
        addSubview(label, positioned: .above, relativeTo: webView)
        NSLayoutConstraint.activate([
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.8)
        ])
        mediaPreparationWarningLabel = label

        guard presentation.automaticallyDismisses else { return }
        mediaPreparationWarningDismissTask = Task { @MainActor [weak self, weak label] in
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return
            }
            guard let self, let label,
                  !Task.isCancelled,
                  self.mediaPreparationWarningLabel === label else { return }
            label.removeFromSuperview()
            self.mediaPreparationWarningLabel = nil
            self.mediaPreparationWarningDismissTask = nil
        }
    }

}
