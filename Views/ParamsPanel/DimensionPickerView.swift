import SwiftUI

// MARK: - Aspect ratio presets

enum AspectPreset: String, CaseIterable, Identifiable {
    case free = "Free"
    case w21h9 = "21:9"
    case w16h9 = "16:9"
    case w3h2 = "3:2"
    case w4h3 = "4:3"
    case sq1h1 = "1:1"
    case w3h4 = "3:4"
    case w2h3 = "2:3"
    case w9h16 = "9:16"
    case w9h21 = "9:21"

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

    var id: String {
        rawValue
    }

    var ratio: Double? {
        switch self {
        case .free: nil
        case .w21h9: 21.0 / 9.0
        case .w16h9: 16.0 / 9.0
        case .w3h2: 3.0 / 2.0
        case .w4h3: 4.0 / 3.0
        case .sq1h1: 1.0
        case .w3h4: 3.0 / 4.0
        case .w2h3: 2.0 / 3.0
        case .w9h16: 9.0 / 16.0
        case .w9h21: 9.0 / 21.0
        }
    }

    var swapped: Self {
        switch self {
        case .free: .free
        case .w21h9: .w9h21
        case .w16h9: .w9h16
        case .w3h2: .w2h3
        case .w4h3: .w3h4
        case .sq1h1: .sq1h1
        case .w3h4: .w4h3
        case .w2h3: .w3h2
        case .w9h16: .w16h9
        case .w9h21: .w21h9
        }
    }

    /// Canonical dimensions for this ratio at a target total area, so pressing a preset
    /// is always deterministic. The target comes from settings (normal vs rapid
    /// iteration); the constraints supply the step, per-axis range, and area cap.
    func dimensions(megapixels: Double, constraints: DimensionConstraints) -> (width: Int, height: Int)? {
        guard let ratio else { return nil }
        return constraints.dimensions(ratio: ratio, megapixels: megapixels)
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

    let constraints: DimensionConstraints

    @Environment(AppSettings.self) private var settings

    @State private var selectedAspect: AspectPreset
    @State private var aspectLocked: Bool
    @State private var hoveredPreset: AspectPreset?
    @State private var halfRes: Bool = false

    private var effectiveRatio: Double? {
        guard aspectLocked else { return nil }
        return selectedAspect.ratio
    }

    /// The area the preset buttons currently aim for, in megapixels.
    private var targetMegapixels: Double {
        halfRes ? settings.rapidTargetMegapixels : settings.targetMegapixels
    }

    private var previewRatio: Double {
        if let ratio = hoveredPreset?.ratio { return ratio }
        return Double(width) / Double(max(height, 1))
    }

    private var dimensionsInfoText: String {
        var text = "Output image size. Preset buttons set common aspect ratios at"
            + " \(mpText(settings.targetMegapixels)) MP —"
            + " \(mpText(settings.rapidTargetMegapixels)) MP with rapid iteration (⚡) on,"
            + " both configurable in Settings › Generation."
            + " Width and height snap to multiples of \(constraints.step)."
        if let maxArea = constraints.maxArea {
            text += " Total size is capped at ~\(maxArea / 1_000_000) MP across any aspect ratio."
        }
        return text + " The grid preview animates on hover."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            DimensionSliderRow(label: "Width", value: widthBinding, range: constraints.range, step: constraints.step)
            DimensionSliderRow(label: "Height", value: heightBinding, range: constraints.range, step: constraints.step)
        }
        .onChange(of: width) { _, w in resyncAspect(w: w, h: height) }
        .onChange(of: height) { _, h in resyncAspect(w: width, h: h) }
        .onChange(of: aspectLocked) { _, locked in
            if !locked { halfRes = false }
        }
    }

    // MARK: - Header row

    /// The widest row in every params panel, and the one that sets the whole panel's
    /// minimum width — so it has a hard budget: **305pt**. That is the 350pt pane less
    /// the panel's 12pt side padding, the scroll view's 5pt trailing content margin and
    /// the section container's 8pt side padding. Overflow here is not clipped locally:
    /// the panel's content column grows past the pane, the fixed-width frame centres it,
    /// and *every* label in the panel loses its leading edge. Measure before adding to
    /// this row (currently 295pt).
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
                // Utility controls in a 2×2 block to save horizontal width: at the 28pt
                // icon-button standard a single row of four would cost 124pt, and even
                // the info button hanging off the end of this HStack put the row 18pt
                // over budget.
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Button { aspectLocked.toggle() } label: {
                            Image(systemName: aspectLocked ? "lock.fill" : "lock.open")
                                .font(.caption)
                        }
                        .buttonStyle(.iconButton)
                        .foregroundStyle(aspectLocked ? Color.orange : Color.secondary)
                        .help(aspectLocked ? "Unlock aspect ratio" : "Lock aspect ratio")

                        Button(action: swapDimensions) {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.caption)
                        }
                        .buttonStyle(.iconButton)
                        .help("Swap width and height")
                    }

                    HStack(spacing: 4) {
                        Button(action: toggleHalfRes) {
                            Image(systemName: "bolt.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.iconButton)
                        .foregroundStyle(halfRes ? Color.yellow : Color.secondary)
                        .disabled(!aspectLocked)
                        .help(
                            "Rapid iteration: generate at \(mpText(settings.rapidTargetMegapixels)) MP"
                                + " instead of \(mpText(settings.targetMegapixels)) MP,"
                                + " and upscale later with img-2-img mode."
                        )

                        InfoButton(
                            title: "Dimensions",
                            description: dimensionsInfoText
                        )
                    }
                }

                canvasPreview
            }
        }
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
                let h = effectiveRatio.map { constraints.snap(Double(newVal) / $0) } ?? height
                applyDimensions(width: newVal, height: h, preserveRatio: effectiveRatio != nil)
            }
        )
    }

    private var heightBinding: Binding<Int> {
        Binding(
            get: { height },
            set: { newVal in
                if let ratio = effectiveRatio {
                    let w = constraints.snap(Double(newVal) * ratio)
                    applyDimensions(width: w, height: newVal, preserveRatio: true)
                } else {
                    applyDimensions(width: width, height: newVal, preserveRatio: false, reduceHeight: true)
                }
            }
        )
    }

    init(width: Binding<Int>, height: Binding<Int>, constraints: DimensionConstraints = .legacy) {
        _width = width
        _height = height
        self.constraints = constraints
        let asp = AspectPreset.detect(w: width.wrappedValue, h: height.wrappedValue)
        _selectedAspect = State(initialValue: asp == .free ? .w16h9 : asp)
        _aspectLocked = State(initialValue: asp != .free)
    }

    // MARK: - Actions

    private func presetDimensions(for preset: AspectPreset) -> (width: Int, height: Int)? {
        preset.dimensions(megapixels: targetMegapixels, constraints: constraints)
    }

    private func resyncAspect(w: Int, h: Int) {
        // Auto-detection must never re-lock: once the user unlocks, typing a value
        // that happens to line up with a preset ratio should keep the aspect unlocked.
        guard aspectLocked else { return }
        let detected = AspectPreset.detect(w: w, h: h)
        if detected != .free {
            selectedAspect = detected
        } else {
            aspectLocked = false
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
            if let (w, h) = presetDimensions(for: preset) {
                applyDimensions(width: w, height: h, preserveRatio: true)
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

    private func swapDimensions() {
        Swift.swap(&width, &height)
        if selectedAspect != .free {
            selectedAspect = selectedAspect.swapped
        }
    }

    private func toggleHalfRes() {
        halfRes.toggle()
        if let (w, h) = presetDimensions(for: selectedAspect) {
            applyDimensions(width: w, height: h, preserveRatio: true)
        }
    }

    // MARK: - Math helpers

    /// Trims a megapixel target for display: 1 rather than 1.00, 0.25 rather than 0.3.
    private func mpText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0 ... 2)))
    }

    /// Snaps + area-fits a (width, height) pair via the active constraints, then
    /// commits both bindings. For the unlocked single-axis case, `reduceHeight`
    /// selects which side absorbs any area-cap reduction (the just-edited axis).
    private func applyDimensions(
        width w: Int, height h: Int, preserveRatio: Bool, reduceHeight: Bool = false
    ) {
        let fitted: (width: Int, height: Int)
        if !preserveRatio, reduceHeight {
            // `fit` reduces `width` to satisfy the area cap; swap so it reduces height.
            let swapped = constraints.fit(width: h, height: w, preserveRatio: false)
            fitted = (swapped.height, swapped.width)
        } else {
            fitted = constraints.fit(width: w, height: h, preserveRatio: preserveRatio)
        }
        width = fitted.width
        height = fitted.height
    }
}

// MARK: - Grid lines shape

private struct CanvasGridLines: Shape {
    let cols: Int
    let rows: Int

    func path(in rect: CGRect) -> Path {
        var p = Path()
        for col in 1 ..< cols {
            let x = rect.width * CGFloat(col) / CGFloat(cols)
            p.move(to: CGPoint(x: x, y: rect.minY))
            p.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        for row in 1 ..< rows {
            let y = rect.height * CGFloat(row) / CGFloat(rows)
            p.move(to: CGPoint(x: rect.minX, y: y))
            p.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return p
    }
}
