import SwiftUI

/// Editable card for a single Ideogram caption element: a type-specific text
/// field, a description field (both growing/expanding), a remove button, a
/// type tag, and a bounding-box coordinate tooltip.
///
/// Shared by the structured caption editor's element list and the expanded bbox
/// viewer's side panel so both present elements identically. The bbox viewer
/// additionally passes `accentColor` (the box's canvas shade), `isSelected`, and
/// `onSelect` to tie each card to its rectangle.
struct IdeogramElementCard: View {
    @Binding var element: IdeogramCaptionElement
    var accentColor: Color?
    var isSelected: Bool = false
    var onSelect: (() -> Void)?
    var onRemove: () -> Void

    /// Tints the type tag and selection chrome. Defaults to the type's family
    /// colour (blue text / green object); the bbox viewer overrides with the
    /// box's per-rectangle shade.
    private var tagColor: Color {
        accentColor ?? (element.type == .text ? .blue : .green)
    }

    var body: some View {
        card
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? tagColor.opacity(0.12) : Color.secondary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isSelected ? tagColor : Color.secondary.opacity(0.2),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .modifier(SelectOnTap(action: onSelect))
    }

    @ViewBuilder
    private var card: some View {
        let el = element
        HStack(alignment: .top, spacing: 2) {
            if el.type == .text {
                GrowingPromptField(
                    text: Binding(
                        get: { element.text ?? "" },
                        set: { element.text = $0.isEmpty ? nil : $0 }
                    ),
                    placeholder: "text…",
                    label: "Element text",
                    hint: "The literal text this element renders",
                    minHeight: 38
                )
            }
            GrowingPromptField(
                text: $element.desc,
                placeholder: "description…",
                label: "Element description",
                hint: "Describe this element",
                minHeight: 38
            )

            VStack {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove element")

                Text(el.type == .text ? "T" : "O")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(tagColor)
                    .frame(width: 18, height: 18)
                    .background(tagColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .help(el.type == .text ? "Text" : "Object")

                if el.bbox.count == 4 {
                    // Coordinates are noise in the list — surface them in a tooltip
                    // on a bounding-box icon instead of a cryptic numeric label.
                    Image(systemName: "viewfinder")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("Bounding box (0–1000): "
                            + "x \(el.bbox[1])–\(el.bbox[3]), y \(el.bbox[0])–\(el.bbox[2])")
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

/// Applies a tap-to-select gesture only when an action is provided, using a
/// simultaneous gesture so the embedded text editors still receive clicks.
private struct SelectOnTap: ViewModifier {
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded(action))
        } else {
            content
        }
    }
}
