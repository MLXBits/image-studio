import SwiftUI

// MARK: - Metrics

/// Global icon-button metrics. **Only these two sizes exist — do not introduce a third.**
///
/// Before this existed the app had nine different icon-button sizes and ~45 buttons with
/// no frame at all, so the clickable region was the glyph's own ~11pt bounding box. Every
/// icon-only control now routes through `IconButtonStyle` (or `iconHitTarget`) so the
/// target is uniform, generous, and visible on hover.
enum IconButtonMetrics {
    /// Default target for every icon-only button — macOS's comfortable minimum.
    static let size: CGFloat = 28

    /// Dense inline rows built around a ~22pt line height (gallery filter bar, list-row
    /// accessories, param chips). Use **only** where `size` would break the row.
    static let compact: CGFloat = 22

    static let cornerRadius: CGFloat = 5
}

// MARK: - Button style

/// Gives an icon-only button a uniform square hit target, a hover fill that reveals where
/// that target actually is, and a pressed/disabled dim.
///
/// Deliberately does **not** set a font — callers keep their own glyph sizing. The frame is
/// what fixes the target; how big the glyph is drawn is a separate concern.
struct IconButtonStyle: ButtonStyle {
    var side: CGFloat = IconButtonMetrics.size

    func makeBody(configuration: Configuration) -> some View {
        // A separate view, not `configuration.label` directly: ButtonStyle bodies can't
        // hold @State (hover) or read @Environment(\.isEnabled).
        IconButtonBody(configuration: configuration, side: side)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let side: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .frame(width: side, height: side)
            .background {
                RoundedRectangle(cornerRadius: IconButtonMetrics.cornerRadius)
                    .fill(Color.primary.opacity(hovering && isEnabled ? 0.08 : 0))
            }
            // Must come after the frame: this is what makes the empty area around the
            // glyph clickable rather than the glyph's own path.
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.5 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

extension ButtonStyle where Self == IconButtonStyle {
    /// Standard 28pt icon button. The default for every icon-only control.
    static var iconButton: IconButtonStyle {
        IconButtonStyle()
    }

    /// 22pt icon button for dense inline rows. See `IconButtonMetrics.compact`.
    static var iconButtonCompact: IconButtonStyle {
        IconButtonStyle(side: IconButtonMetrics.compact)
    }
}

// MARK: - Non-Button targets

extension View {
    /// Hit target for controls a `ButtonStyle` can't reach — `Menu` labels (`Menu` ignores
    /// `ButtonStyle`), `Image` + `.onTapGesture`, and bare shapes whose filled path would
    /// otherwise be the only hit-testable region.
    func iconHitTarget(_ side: CGFloat = IconButtonMetrics.size) -> some View {
        frame(width: side, height: side)
            .contentShape(Rectangle())
    }

    /// `iconHitTarget` for `Menu` labels, which need the frame on the label content itself.
    /// Pair with `.menuStyle(.borderlessButton)`.
    func iconMenuLabel(_ side: CGFloat = IconButtonMetrics.size) -> some View {
        iconHitTarget(side)
    }
}
