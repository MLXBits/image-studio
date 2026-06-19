import SwiftUI

// MARK: - Canvas drawing & resize handles

extension BBoxEditorView {
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

            let line1 = element.type == .text
                ? (element.text.map { "\"\($0)\"" } ?? "T")
                : "•"
            let line2 = element.desc
            let fontSize: CGFloat = max(8, min(12, rect.height * 0.18))
            let inset = rect.insetBy(dx: 4, dy: 3)

            if inset.width > 12 && inset.height > 14 {
                let topPt = CGPoint(x: inset.minX, y: inset.minY)
                drawLabel(
                    ctx,
                    Text(line1)
                        .font(.system(size: fontSize, weight: .semibold))
                        .foregroundStyle(color.opacity(0.9)),
                    at: topPt, overImage: overImage
                )
                if inset.height > 26 {
                    let descPt = CGPoint(x: inset.minX, y: inset.minY + fontSize + 2)
                    drawLabel(
                        ctx,
                        Text(line2)
                            .font(.system(size: max(7, fontSize - 1)))
                            .foregroundStyle(color.opacity(0.7)),
                        at: descPt, overImage: overImage
                    )
                }
            }
        }
    }

    /// Draws Canvas label text, adding a 1px black outline behind it when over an
    /// image so coloured labels stay readable on arbitrary backgrounds.
    func drawLabel(_ ctx: GraphicsContext, _ text: Text, at pt: CGPoint, overImage: Bool) {
        if overImage {
            let outline = text.foregroundStyle(.black.opacity(0.85))
            for offset in [
                CGSize(width: 1, height: 0),
                CGSize(width: -1, height: 0),
                CGSize(width: 0, height: 1),
                CGSize(width: 0, height: -1),
            ] {
                ctx.draw(outline, at: CGPoint(x: pt.x + offset.width, y: pt.y + offset.height), anchor: .topLeading)
            }
        }
        ctx.draw(text, at: pt, anchor: .topLeading)
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
