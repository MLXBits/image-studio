import SwiftUI

// MARK: - Canvas drawing & resize handles

extension BBoxEditorView {
    /// Draws only the box fills and strokes. Labels are rendered separately as
    /// native `Text` overlays (see `labelOverlay`) — drawing them inside the
    /// Canvas rasterizes the glyphs into the canvas bitmap, which looks soft /
    /// blurry over a background image.
    func drawBoxes(ctx: GraphicsContext, size _: CGSize, canvasSize: CGSize) {
        let overImage = backgroundImage != nil
        for (index, element) in elements.enumerated() {
            let rect = BBoxGeometry.normRect(element.bbox, in: canvasSize)
            let isSelected = element.id == selectedID
            let color = BBoxGeometry.boxColor(at: index, type: element.type)

            ctx.fill(Path(rect), with: .color(color.opacity(overImage ? 0.10 : 0.12)))
            // Dark halo under the coloured stroke keeps boxes legible over imagery.
            if overImage {
                ctx.stroke(
                    Path(rect),
                    with: .color(.black.opacity(0.55)),
                    style: StrokeStyle(lineWidth: (isSelected ? 2 : 1.5) + 2)
                )
            }
            ctx.stroke(
                Path(rect),
                with: .color(color.opacity(isSelected ? 1.0 : 0.7)),
                style: StrokeStyle(lineWidth: isSelected ? 2 : 1.5)
            )
        }
    }

    /// Native-text label overlay sitting above the box Canvas. Using real SwiftUI
    /// `Text` (vector glyphs) instead of `GraphicsContext.draw(Text:)` keeps the
    /// labels crisp, especially over a background image. A soft black shadow
    /// stands in for the old per-pixel outline when drawn over imagery.
    func labelOverlay(canvasSize: CGSize) -> some View {
        let overImage = backgroundImage != nil
        return ZStack(alignment: .topLeading) {
            ForEach(Array(elements.enumerated()), id: \.element.id) { index, element in
                let rect = BBoxGeometry.normRect(element.bbox, in: canvasSize)
                let color = BBoxGeometry.boxColor(at: index, type: element.type)
                let fontSize: CGFloat = max(8, min(12, rect.height * 0.18))
                let inset = rect.insetBy(dx: 4, dy: 3)
                let line1 = element.type == .text
                    ? (element.text.map { "\"\($0)\"" } ?? "T")
                    : "•"

                if inset.width > 12 && inset.height > 14 {
                    VStack(alignment: .leading, spacing: 2) {
                        labelText(line1, size: fontSize, weight: .semibold, color: color)
                        if inset.height > 26 {
                            labelText(
                                element.desc, size: max(7, fontSize - 1),
                                weight: .regular, color: color.opacity(0.85)
                            )
                        }
                    }
                    // Solid dark chip behind the labels so the busy background image
                    // doesn't bleed through the (now opaque) glyphs. Without a
                    // backdrop, translucent text over a photo reads as blurry.
                    .padding(.horizontal, overImage ? 3 : 0)
                    .padding(.vertical, overImage ? 1 : 0)
                    .background {
                        if overImage {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.black.opacity(0.6))
                        }
                    }
                    .frame(width: inset.width, alignment: .leading)
                    .offset(x: inset.minX, y: inset.minY)
                }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func labelText(
        _ string: String, size: CGFloat, weight: Font.Weight, color: Color
    ) -> some View {
        Text(string)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder
    func handleOverlay(for element: IdeogramCaptionElement, canvasSize: CGSize) -> some View {
        let rect = BBoxGeometry.normRect(element.bbox, in: canvasSize)
        let index = elements.firstIndex { $0.id == element.id } ?? 0
        let color = BBoxGeometry.boxColor(at: index, type: element.type)

        ForEach(BBoxResizeHandle.allCases, id: \.self) { handle in
            let pt = BBoxGeometry.handlePoint(handle, in: rect)
            Circle()
                .fill(color)
                .stroke(.white, lineWidth: 1.5)
                .frame(width: handleRadius * 2, height: handleRadius * 2)
                .offset(x: pt.x - handleRadius, y: pt.y - handleRadius)
                .gesture(handleDragGesture(handle: handle, element: element, canvasSize: canvasSize))
        }
    }
}
