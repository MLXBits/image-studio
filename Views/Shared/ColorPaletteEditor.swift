import AppKit
import SwiftUI

// MARK: - Color palette editor

/// Inline hex-color palette editor: each entry is a circular swatch (click to
/// open the system color picker) with an editable hex field alongside. "Add color"
/// appends a new entry and opens the picker for it.
struct ColorPaletteEditor: View {
    @Binding var colors: [String]

    /// Wide enough for swatch + editable 6-char hex + remove button without the
    /// capsule contents overflowing into the next grid column.
    private let columns = [GridItem(.adaptive(minimum: 116), spacing: 6, alignment: .leading)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !colors.isEmpty {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                    ForEach(Array(colors.enumerated()), id: \.offset) { idx, hex in
                        chip(idx: idx, hex: hex)
                    }
                }
            }
            Button {
                let idx = colors.count
                colors.append("#808080")
                editColor(at: idx)
            } label: {
                Label("Add color", systemImage: "plus.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add a color")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(idx: Int, hex: String) -> some View {
        HStack(spacing: 4) {
            Button {
                editColor(at: idx)
            } label: {
                Circle()
                    .fill(Color(hexString: hex) ?? .black)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Edit color")
            HexInputField(hex: hex) { newHex in
                guard colors.indices.contains(idx) else { return }
                colors[idx] = newHex
            }
            Button {
                guard colors.indices.contains(idx) else { return }
                colors.remove(at: idx)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove color")
        }
        .padding(.leading, 4)
        .padding(.trailing, 2)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.06))
        .clipShape(Capsule())
        .help(hex.uppercased())
    }

    /// Opens the shared system color panel seeded with the entry at `idx`,
    /// writing each live change back into the palette.
    private func editColor(at idx: Int) {
        guard colors.indices.contains(idx) else { return }
        ColorPanelController.shared.present(initial: Color(hexString: colors[idx]) ?? .black) { picked in
            if colors.indices.contains(idx) { colors[idx] = picked.hexString }
        }
    }
}

// MARK: - Hex input field

/// Editable `#RRGGBB` field shown beside each swatch. Lets the user type or
/// paste an exact hex so the same color can be reused across elements without
/// eyeballing the color wheel. Commits on Return or focus loss; reverts to the
/// bound value when the input doesn't parse as a 6-digit hex.
private struct HexInputField: View {
    let hex: String
    let onCommit: (String) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("RRGGBB", text: $text)
            .textFieldStyle(.plain)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            .onChange(of: hex) { _, newValue in
                if !focused { text = display(newValue) }
            }
            .onAppear { text = display(hex) }
            .help("Type or paste a hex color (e.g. 1A2B3C)")
    }

    /// Hex without the leading `#`, uppercased, for compact display.
    private func display(_ value: String) -> String {
        value.uppercased().replacingOccurrences(of: "#", with: "")
    }

    /// Parses the typed value; on success normalizes and commits, otherwise reverts.
    private func commit() {
        let candidate = "#" + text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "#", with: "")
        if let color = Color(hexString: candidate) {
            let normalized = color.hexString
            text = display(normalized)
            if normalized != hex { onCommit(normalized) }
        } else {
            text = display(hex)
        }
    }
}

// MARK: - Color panel controller

/// Bridges the shared `NSColorPanel` to a SwiftUI callback so a custom swatch
/// button can present the native picker. Re-targeting on each present means
/// only the most recently opened swatch receives updates.
@MainActor
final class ColorPanelController: NSObject {
    static let shared = ColorPanelController()

    private var onChange: ((Color) -> Void)?

    func present(initial: Color, onChange: @escaping (Color) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = NSColor(initial)
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.isContinuous = true
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        onChange?(Color(nsColor: sender.color))
    }
}

// MARK: - Hex <-> Color

extension Color {
    /// Renders as `#RRGGBB` in sRGB.
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Parses `#RRGGBB` (with or without the leading `#`). Returns nil on bad input.
    init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self = Color(
            .sRGB,
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}
