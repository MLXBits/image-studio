import SwiftUI

// MARK: - Aspect ratio presets

enum AspectPreset: String, CaseIterable, Identifiable {
    case free   = "Free"
    case w21h9  = "21:9"
    case w16h9  = "16:9"
    case w3h2   = "3:2"
    case w4h3   = "4:3"
    case sq1h1  = "1:1"
    case w3h4   = "3:4"
    case w2h3   = "2:3"
    case w9h16  = "9:16"
    case w9h21  = "9:21"

    var id: String { rawValue }

    var ratio: Double? {
        switch self {
        case .free:  return nil
        case .w21h9: return 21.0 / 9.0
        case .w16h9: return 16.0 / 9.0
        case .w3h2:  return 3.0 / 2.0
        case .w4h3:  return 4.0 / 3.0
        case .sq1h1: return 1.0
        case .w3h4:  return 3.0 / 4.0
        case .w2h3:  return 2.0 / 3.0
        case .w9h16: return 9.0 / 16.0
        case .w9h21: return 9.0 / 21.0
        }
    }

    // Fixed ~1MP canonical dimensions so pressing a preset is always deterministic.
    var targetDimensions: (width: Int, height: Int)? {
        switch self {
        case .free:  return nil
        case .sq1h1: return (1024, 1024)  // 1.05 MP
        case .w16h9: return (1360, 768)   // 1.04 MP
        case .w9h16: return (768, 1360)
        case .w3h2:  return (1248, 832)   // 1.04 MP
        case .w2h3:  return (832, 1248)
        case .w4h3:  return (1152, 864)   // 0.99 MP
        case .w3h4:  return (864, 1152)
        case .w21h9: return (1568, 672)   // 1.05 MP
        case .w9h21: return (672, 1568)
        }
    }

    var swapped: Self {
        switch self {
        case .free:  return .free
        case .w21h9: return .w9h21
        case .w16h9: return .w9h16
        case .w3h2:  return .w2h3
        case .w4h3:  return .w3h4
        case .sq1h1: return .sq1h1
        case .w3h4:  return .w4h3
        case .w2h3:  return .w3h2
        case .w9h16: return .w16h9
        case .w9h21: return .w21h9
        }
    }

    static func detect(w: Int, h: Int) -> Self {
        let ratio = Double(w) / Double(h)
        guard let closest = Self.allCases
            .filter({ $0 != .free })
            .min(by: { abs(($0.ratio ?? 1) - ratio) < abs(($1.ratio ?? 1) - ratio) }),
              let r = closest.ratio,
              abs(r - ratio) / ratio < 0.06
        else { return .free }
        return closest
    }
}

// MARK: - Pill layout constants

private let dimSoloPreset: AspectPreset = .sq1h1

private let dimPresetPairs: [(AspectPreset, AspectPreset)] = [
    (.w3h2, .w2h3),
    (.w16h9, .w9h16),
    (.w4h3, .w3h4),
    (.w21h9, .w9h21),
]

// MARK: - DimensionPickerView

struct DimensionPickerView: View {
    @Binding var width: Int
    @Binding var height: Int

    @State private var selectedAspect: AspectPreset
    @State private var aspectLocked: Bool
    @State private var hoveredPreset: AspectPreset?

    init(width: Binding<Int>, height: Binding<Int>) {
        _width  = width
        _height = height
        let asp = AspectPreset.detect(w: width.wrappedValue, h: height.wrappedValue)
        _selectedAspect = State(initialValue: asp == .free ? .w16h9 : asp)
        _aspectLocked   = State(initialValue: asp != .free)
    }

    private var effectiveRatio: Double? {
        guard aspectLocked else { return nil }
        return selectedAspect.ratio
    }

    private var previewRatio: Double {
        if let ratio = hoveredPreset?.ratio { return ratio }
        return Double(width) / Double(max(height, 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            DimensionSliderRow(label: "Width", value: widthBinding)
            DimensionSliderRow(label: "Height", value: heightBinding)
        }
    }

    // MARK: - Header row

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 5) {
            presetPill(dimSoloPreset)

            HStack(alignment: .center, spacing: 4) {
                ForEach(dimPresetPairs.indices, id: \.self) { idx in
                    let (top, bottom) = dimPresetPairs[idx]
                    VStack(spacing: 3) {
                        presetPill(top)
                        presetPill(bottom)
                    }
                }
            }

            Spacer(minLength: 4)

            HStack(alignment: .center, spacing: 6) {
                Button { aspectLocked.toggle() } label: {
                    Image(systemName: aspectLocked ? "lock.fill" : "lock.open")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(aspectLocked ? Color.orange : Color.secondary)
                .help(aspectLocked ? "Unlock aspect ratio" : "Lock aspect ratio")

                Button(action: swapDimensions) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Swap width and height")

                canvasPreview

                InfoButton(
                    title: "Dimensions",
                    description: "Output image size. Preset buttons set common aspect ratios."
                        + " Width and height snap to multiples of 16. The grid preview animates on hover."
                )
            }
        }
    }

    // MARK: - Preset pill

    @ViewBuilder
    private func presetPill(_ preset: AspectPreset) -> some View {
        let isActive = aspectLocked && selectedAspect == preset
        let isHovered = hoveredPreset == preset
        Button {
            selectedAspect = preset
            aspectLocked = true
            if let (w, h) = preset.targetDimensions {
                width  = w
                height = h
            }
        } label: {
            Text(preset.rawValue)
                .font(.system(size: 11))
                .fontWeight(isActive ? .semibold : .regular)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .frame(minWidth: 32)
                .foregroundStyle(isActive ? .white : .primary)
                .background {
                    if isActive {
                        RoundedRectangle(cornerRadius: 5).fill(Color.accentColor)
                    } else {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.secondary.opacity(isHovered ? 0.2 : 0.12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
                            )
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { inside in hoveredPreset = inside ? preset : nil }
        .accessibilityLabel("\(preset.rawValue) aspect ratio")
        .accessibilityHint(isActive ? "Currently selected" : "Set to \(preset.rawValue) aspect ratio")
    }

    // MARK: - Canvas preview

    private var canvasPreview: some View {
        let maxSide: CGFloat = 38
        let ratio = CGFloat(previewRatio)
        let boxW: CGFloat = ratio >= 1 ? maxSide : maxSide * ratio
        let boxH: CGFloat = ratio >= 1 ? maxSide / ratio : maxSide

        return ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.08))
            CanvasGridLines(cols: 3, rows: 3)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
        }
        .frame(width: boxW, height: boxH)
        .frame(width: maxSide, height: maxSide, alignment: .center)
        .animation(.easeInOut(duration: 0.15), value: previewRatio)
        .accessibilityHidden(true)
    }

    // MARK: - Ratio-enforcing bindings

    private var widthBinding: Binding<Int> {
        Binding(
            get: { width },
            set: { newVal in
                width = newVal
                if let ratio = effectiveRatio {
                    height = snapTo16(Double(newVal) / ratio)
                }
            }
        )
    }

    private var heightBinding: Binding<Int> {
        Binding(
            get: { height },
            set: { newVal in
                height = newVal
                if let ratio = effectiveRatio {
                    width = snapTo16(Double(newVal) * ratio)
                }
            }
        )
    }

    // MARK: - Actions

    private func swapDimensions() {
        Swift.swap(&width, &height)
        if selectedAspect != .free {
            selectedAspect = selectedAspect.swapped
        }
    }

    // MARK: - Math helpers

    private func snapTo16(_ val: Double) -> Int {
        guard val.isFinite, val > 0 else { return 64 }
        return max(64, min(2048, Int((val / 16).rounded() * 16)))
    }
}

// MARK: - Grid lines shape

private struct CanvasGridLines: Shape {
    let cols: Int
    let rows: Int

    func path(in rect: CGRect) -> Path {
        var p = Path()
        for col in 1..<cols {
            let x = rect.width * CGFloat(col) / CGFloat(cols)
            p.move(to: CGPoint(x: x, y: rect.minY))
            p.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        for row in 1..<rows {
            let y = rect.height * CGFloat(row) / CGFloat(rows)
            p.move(to: CGPoint(x: rect.minX, y: y))
            p.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return p
    }
}
