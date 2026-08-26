import AppKit
import SwiftUI
import BackgroundEngineCore

/// Native editor for the scalar Web user properties declared by Wallpaper
/// Engine project.json. File and directory properties stay in the More menu
/// because they require an NSOpenPanel and security-scoped copy workflow.
struct WebWallpaperPropertiesEditorView: View {
    let asset: WallpaperAsset
    let properties: [WebWallpaperCompatibilityBridge.EditableProperty]
    let onSave: ([String: WebWallpaperPropertyValue]) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: WebWallpaperPropertyValue]
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        asset: WallpaperAsset,
        properties: [WebWallpaperCompatibilityBridge.EditableProperty],
        onSave: @escaping ([String: WebWallpaperPropertyValue]) async throws -> Void
    ) {
        self.asset = asset
        self.properties = properties
        self.onSave = onSave
        _values = State(initialValue: properties.reduce(into: [:]) {
            $0[$1.name] = $1.currentValue
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(properties) { property in
                        propertyCard(property)
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 420, idealHeight: 600)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Web Properties")
                    .font(.title3.weight(.semibold))
                Text(asset.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(properties.count)")
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
                .accessibilityLabel("\(properties.count) editable properties")
        }
        .padding(16)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Reset to Defaults") {
                    values = properties.reduce(into: [:]) { $0[$1.name] = $1.defaultValue }
                    errorMessage = nil
                }
                .disabled(isSaving)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button {
                    save()
                } label: {
                    HStack(spacing: 6) {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityHidden(true)
                        }
                        Text(isSaving ? "Saving…" : "Save")
                    }
                    .frame(minWidth: 58)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
                .accessibilityLabel(isSaving ? "Saving Web properties" : "Save Web properties")
            }
            Text("Saving refreshes only the displays currently using this Web wallpaper.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    @ViewBuilder
    private func propertyCard(_ property: WebWallpaperCompatibilityBridge.EditableProperty) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(property.label)
                    .font(.body.weight(.medium))
                Spacer()
                Text(property.name)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            propertyControl(property)
        }
        .padding(12)
        .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private func propertyControl(_ property: WebWallpaperCompatibilityBridge.EditableProperty) -> some View {
        switch property.kind {
        case .bool:
            Toggle("Enabled", isOn: boolBinding(for: property))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel(property.label)
        case .slider:
            let bounds = sliderBounds(for: property)
            let step = sliderStep(for: property, bounds: bounds)
            let binding = numberBinding(for: property, bounds: bounds, step: step)
            HStack(spacing: 12) {
                Slider(
                    value: binding,
                    in: bounds
                )
                .accessibilityLabel(property.label)
                .accessibilityValue(numberAccessibilityValue(for: property))
                TextField(
                    property.label,
                    value: binding,
                    format: .number.precision(.fractionLength(0...3))
                )
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 78)
            }
        case .color:
            HStack(spacing: 12) {
                ColorPicker(
                    property.label,
                    selection: colorBinding(for: property),
                    supportsOpacity: false
                )
                .labelsHidden()
                TextField(property.label, text: textBinding(for: property))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityHint("RGB value such as 0.2 0.5 1 or hexadecimal #337FFF")
            }
        case .combo:
            Picker(property.label, selection: textBinding(for: property)) {
                if property.options.isEmpty {
                    Text(textValue(for: property)).tag(textValue(for: property))
                } else {
                    ForEach(property.options) { option in
                        Text(option.label).tag(option.value)
                    }
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        case .text:
            TextField(property.label, text: textBinding(for: property))
                .textFieldStyle(.roundedBorder)
        }
    }

    private func boolBinding(
        for property: WebWallpaperCompatibilityBridge.EditableProperty
    ) -> Binding<Bool> {
        Binding(
            get: {
                guard case .bool(let value) = values[property.name] else { return false }
                return value
            },
            set: { values[property.name] = .bool($0) }
        )
    }

    private func numberBinding(
        for property: WebWallpaperCompatibilityBridge.EditableProperty,
        bounds: ClosedRange<Double>,
        step: Double
    ) -> Binding<Double> {
        Binding(
            get: {
                guard case .number(let value) = values[property.name] else { return bounds.lowerBound }
                return min(bounds.upperBound, max(bounds.lowerBound, value))
            },
            set: { value in
                let clamped = min(bounds.upperBound, max(bounds.lowerBound, value))
                let quantized = bounds.lowerBound
                    + ((clamped - bounds.lowerBound) / step).rounded() * step
                values[property.name] = .number(
                    min(bounds.upperBound, max(bounds.lowerBound, quantized))
                )
            }
        )
    }

    private func textBinding(
        for property: WebWallpaperCompatibilityBridge.EditableProperty
    ) -> Binding<String> {
        Binding(
            get: { textValue(for: property) },
            set: { values[property.name] = .text($0) }
        )
    }

    private func textValue(
        for property: WebWallpaperCompatibilityBridge.EditableProperty
    ) -> String {
        guard case .text(let value) = values[property.name] else { return "" }
        return value
    }

    private func numberAccessibilityValue(
        for property: WebWallpaperCompatibilityBridge.EditableProperty
    ) -> String {
        guard case .number(let value) = values[property.name] else { return "" }
        return value.formatted(.number.precision(.fractionLength(0...3)))
    }

    private func sliderBounds(
        for property: WebWallpaperCompatibilityBridge.EditableProperty
    ) -> ClosedRange<Double> {
        let minimum = property.minimum ?? 0
        let maximum = property.maximum ?? 100
        return minimum < maximum ? minimum...maximum : 0...100
    }

    private func sliderStep(
        for property: WebWallpaperCompatibilityBridge.EditableProperty,
        bounds: ClosedRange<Double>
    ) -> Double {
        guard let step = property.step, step.isFinite, step > 0,
              step <= bounds.upperBound - bounds.lowerBound else {
            return 1
        }
        return step
    }

    private func colorBinding(
        for property: WebWallpaperCompatibilityBridge.EditableProperty
    ) -> Binding<Color> {
        Binding(
            get: { Self.color(from: textValue(for: property)) },
            set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                values[property.name] = .text(WebWallpaperColorCodec.encode(
                    red: rgb.redComponent,
                    green: rgb.greenComponent,
                    blue: rgb.blueComponent,
                    preservingFormatOf: textValue(for: property)
                ))
            }
        )
    }

    private static func color(from value: String) -> Color {
        guard let rgb = WebWallpaperColorCodec.decode(value) else { return .black }
        return Color(
            .sRGB,
            red: rgb.red,
            green: rgb.green,
            blue: rgb.blue,
            opacity: 1
        )
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await onSave(values)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

/// Wallpaper Engine serializes colors as normalized RGB triples while Lively
/// uses CSS hexadecimal strings. Keeping the input format stable lets the same
/// native property editor drive both compatibility bridges without silently
/// changing the value shape delivered to JavaScript.
enum WebWallpaperColorCodec {
    struct RGB: Equatable {
        let red: Double
        let green: Double
        let blue: Double
    }

    static func decode(_ value: String) -> RGB? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") {
            let digits = String(trimmed.dropFirst())
            let expanded: String
            switch digits.count {
            case 3:
                expanded = digits.map { "\($0)\($0)" }.joined()
            case 6:
                expanded = digits
            default:
                return nil
            }
            guard let raw = UInt32(expanded, radix: 16) else { return nil }
            return RGB(
                red: Double((raw >> 16) & 0xff) / 255,
                green: Double((raw >> 8) & 0xff) / 255,
                blue: Double(raw & 0xff) / 255
            )
        }

        let components = trimmed
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .compactMap { Double($0) }
        guard components.count >= 3 else { return nil }
        return RGB(
            red: clamp(components[0]),
            green: clamp(components[1]),
            blue: clamp(components[2])
        )
    }

    static func encode(
        red: Double,
        green: Double,
        blue: Double,
        preservingFormatOf template: String
    ) -> String {
        let components = [clamp(red), clamp(green), clamp(blue)]
        if template.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#") {
            let bytes = components.map { Int(($0 * 255).rounded()) }
            return String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2])
        }
        return components.map { String(format: "%.5g", $0) }.joined(separator: " ")
    }

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value.isFinite ? value : 0))
    }
}
