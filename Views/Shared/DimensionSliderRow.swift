import SwiftUI

/// A labeled row with a continuous slider and an attached stepper-box on the right.
/// Used for width/height inputs in both the params panel and settings.
struct DimensionSliderRow: View {
    let label: String
    @Binding var value: Int
    var range: ClosedRange<Int> = 64 ... 2048
    var step: Int = 16

    // Typing is buffered here so intermediate keystrokes never reach `value`.
    // Committing every digit lets coupled logic (locked-ratio recompute, area
    // fit) rewrite the field mid-edit, which corrupts what the user is typing —
    // so we only commit on Return or focus-out. Slider/stepper stay live.
    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.primary)
                .frame(width: 46, alignment: .leading)

            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { value = snap(Int($0)) }
                ),
                in: Double(range.lowerBound) ... Double(range.upperBound)
            )
            .accessibilityLabel(label)
            .accessibilityValue("\(value) pixels")
            .accessibilityHint("Drag to resize. Snaps to nearest \(step) pixels.")

            // Number box with stepper arrows — label IS the text field
            Stepper(
                value: $value,
                in: range,
                step: step
            ) {
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                    .focused($focused)
                    .onSubmit(commitText)
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused { commitText() }
                    }
                    .onChange(of: value) { _, newValue in
                        // Reflect slider/stepper/preset-driven changes, but never
                        // clobber the field while the user is actively typing.
                        if !focused { text = String(newValue) }
                    }
                    .accessibilityLabel(label)
                    .accessibilityValue("\(value)")
                    .accessibilityHint("Type a value or use arrows. Snaps to nearest \(step) pixels.")
            }
        }
        .onAppear { text = String(value) }
    }

    private func commitText() {
        let digits = text.filter(\.isNumber)
        value = snap(Int(digits) ?? value)
        text = String(value)
    }

    private func snap(_ n: Int) -> Int {
        let clamped = n.clamped(to: range)
        let snapped = range.lowerBound + ((clamped - range.lowerBound + step / 2) / step) * step
        return snapped.clamped(to: range)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
