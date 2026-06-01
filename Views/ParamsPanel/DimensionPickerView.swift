import SwiftUI

private struct AspectPreset: Identifiable {
    let id = UUID()
    let label: String
    let width: Int
    let height: Int

    var accessibilityDescription: String { "\(label) — \(width) by \(height) pixels" }
}

// Layout: 1:1 solo, then portrait/landscape pairs stacked vertically
private let solo: AspectPreset = AspectPreset(label: "1:1", width: 1024, height: 1024)

private let pairs: [(AspectPreset, AspectPreset)] = [
    (AspectPreset(label: "3:2",  width: 1152, height: 768),
     AspectPreset(label: "2:3",  width: 768,  height: 1152)),
    (AspectPreset(label: "16:9", width: 1360, height: 768),
     AspectPreset(label: "9:16", width: 768,  height: 1360)),
    (AspectPreset(label: "4:3",  width: 1024, height: 768),
     AspectPreset(label: "3:4",  width: 768,  height: 1024)),
    (AspectPreset(label: "21:9", width: 1680, height: 720),
     AspectPreset(label: "9:21", width: 720,  height: 1680)),
]

private var allPresets: [AspectPreset] {
    [solo] + pairs.flatMap { [$0.0, $0.1] }
}

struct DimensionPickerView: View {
    @Binding var width: Int
    @Binding var height: Int

    @State private var hoveredPreset: AspectPreset? = nil

    private var activePreset: AspectPreset? {
        allPresets.first { $0.width == width && $0.height == height }
    }

    private var previewW: Int { hoveredPreset?.width  ?? width }
    private var previewH: Int { hoveredPreset?.height ?? height }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            DimensionSliderRow(label: "Width",  value: $width)
            DimensionSliderRow(label: "Height", value: $height)
        }
    }

    // MARK: - Header row: 1:1 | paired columns | canvas ⓘ

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 5) {
            // 1:1 — vertically centred against the two-row pairs
            presetPill(solo)

            // Paired columns: landscape on top, portrait below
            HStack(alignment: .center, spacing: 4) {
                ForEach(pairs.indices, id: \.self) { i in
                    let (top, bottom) = pairs[i]
                    VStack(spacing: 3) {
                        presetPill(top)
                        presetPill(bottom)
                    }
                }
            }

            Spacer(minLength: 4)

            // Canvas preview + help icon to its right
            HStack(alignment: .center, spacing: 4) {
                canvasPreview
                InfoButton(
                    title: "Dimensions",
                    description: "Output image size. Preset buttons set common aspect ratios at ~1 MP. Width and height snap to multiples of 16. The grid preview animates on hover."
                )
            }
        }
    }

    // MARK: - Preset pill

    @ViewBuilder
    private func presetPill(_ p: AspectPreset) -> some View {
        let isActive = activePreset?.id == p.id
        let isHovered = hoveredPreset?.id == p.id
        Button {
            width = p.width; height = p.height
        } label: {
            Text(p.label)
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
        .onHover { inside in hoveredPreset = inside ? p : nil }
        .accessibilityLabel(p.accessibilityDescription)
        .accessibilityHint(isActive ? "Currently selected" : "Set canvas to \(p.label) aspect ratio")
    }

    // MARK: - Animated canvas preview

    private var canvasPreview: some View {
        let maxSide: CGFloat = 38
        let aspect = CGFloat(previewW) / CGFloat(max(previewH, 1))
        let boxW: CGFloat = aspect >= 1 ? maxSide : maxSide * aspect
        let boxH: CGFloat = aspect >= 1 ? maxSide / aspect : maxSide

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
        .animation(.easeInOut(duration: 0.15), value: previewW)
        .animation(.easeInOut(duration: 0.15), value: previewH)
        .accessibilityHidden(true)
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
