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
    /// Called when one of the card's text editors gains focus. Lets the bbox
    /// viewer select the matching rectangle when the user clicks into a field
    /// (the embedded NSTextView swallows the tap that drives `onSelect`).
    var onTextFocus: (() -> Void)?
    var onRemove: () -> Void
    /// Stacking-order controls (bbox side panel only). Array order is the front/back
    /// order the model reads on overlap. Nil hides the buttons (e.g. single element).
    var onMoveForward: (() -> Void)?
    var onMoveBackward: (() -> Void)?

    @State private var showPalette = false

    /// Tints the type tag and selection chrome. Defaults to the type's family
    /// colour (blue text / green object); the bbox viewer overrides with the
    /// box's per-rectangle shade.
    private var tagColor: Color {
        accentColor ?? (element.type == .text ? .blue : .green)
    }

    /// Hex strings for this element's optional color palette (`[]` when unset).
    private var paletteColors: [String] {
        element.colorPalette ?? []
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

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            elementRow
            if showPalette {
                Divider()
                elementPaletteSection
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var elementRow: some View {
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
                    minHeight: 38,
                    onFocus: onTextFocus
                )
            }
            GrowingPromptField(
                text: $element.desc,
                placeholder: "description…",
                label: "Element description",
                hint: "Describe this element",
                minHeight: 38,
                onFocus: onTextFocus
            )

            // Fixed spacing + a uniform 24pt slot per row so the action buttons,
            // the type chip, and the bbox icon are evenly distributed.
            VStack(spacing: 6) {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove element")

                if onMoveForward != nil || onMoveBackward != nil {
                    zOrderButtons
                }

                paletteButton

                Text(el.type == .text ? "T" : "O")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(tagColor)
                    .frame(width: 18, height: 18)
                    .background(tagColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .frame(width: 24, height: 24)
                    .help(el.type == .text ? "Text" : "Object")

                if el.bbox.count == 4 {
                    // Coordinates are noise in the list — surface them in a tooltip
                    // on a bounding-box icon instead of a cryptic numeric label.
                    Image(systemName: "viewfinder")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 24, height: 24)
                        .help("Bounding box (0–1000): "
                            + "x \(el.bbox[1])–\(el.bbox[3]), y \(el.bbox[0])–\(el.bbox[2])")
                }
            }
        }
    }

    /// Colour-wheel toggle for the element's palette. Translucent when no colours
    /// are set, full-colour once the element carries a palette. Expands an inline
    /// editor rather than a popover — a popover presented from the bbox overlay
    /// sheet is dismissed the moment the system colour panel becomes key.
    private var paletteButton: some View {
        let hasColors = !paletteColors.isEmpty
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { showPalette.toggle() }
        } label: {
            Image(systemName: "paintpalette.fill")
                .symbolRenderingMode(hasColors ? .multicolor : .monochrome)
                .font(.body)
                .foregroundStyle(.secondary)
                .opacity(hasColors || showPalette ? 1 : 0.35)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(showPalette ? Color.secondary.opacity(0.18) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hasColors
            ? "Edit element colors (\(paletteColors.count))"
            : "Add element colors")
    }

    /// Bring-forward / send-backward controls stacked in one 24pt slot.
    private var zOrderButtons: some View {
        HStack(spacing: 1) {
            Button { onMoveBackward?() } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 11, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onMoveBackward == nil)
            .help("Send backward")

            Button { onMoveForward?() } label: {
                Image(systemName: "chevron.forward")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 11, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onMoveForward == nil)
            .help("Bring forward")
        }
        .frame(width: 24, height: 24)
    }

    private var elementPaletteSection: some View {
        let binding = Binding<[String]>(
            get: { element.colorPalette ?? [] },
            set: { element.colorPalette = $0.isEmpty ? nil : $0 }
        )
        return VStack(alignment: .leading, spacing: 6) {
            Text("Element Colors")
                .font(.caption)
                .foregroundStyle(.secondary)
            ColorPaletteEditor(colors: binding)
        }
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
