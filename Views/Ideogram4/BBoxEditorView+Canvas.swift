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

    // MARK: - Composition guides

    /// Rule-of-thirds lines and a center cross. Mid-gray dashes read on both light
    /// and dark backgrounds and over most imagery without competing with the boxes.
    func drawGuides(ctx: GraphicsContext, size _: CGSize, canvasSize: CGSize) {
        let g = BBoxGeometry.gridLines(in: canvasSize)
        let thirds = Color.gray.opacity(backgroundImage != nil ? 0.45 : 0.35)
        let center = Color.gray.opacity(backgroundImage != nil ? 0.6 : 0.5)
        let dash = StrokeStyle(lineWidth: 1, dash: [3, 4])

        for x in g.verticalThirds {
            ctx.stroke(vLine(x, canvasSize), with: .color(thirds), style: dash)
        }
        for y in g.horizontalThirds {
            ctx.stroke(hLine(y, canvasSize), with: .color(thirds), style: dash)
        }
        ctx.stroke(vLine(g.centerX, canvasSize), with: .color(center), style: dash)
        ctx.stroke(hLine(g.centerY, canvasSize), with: .color(center), style: dash)
    }

    private func vLine(_ x: CGFloat, _ canvas: CGSize) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: x, y: 0))
        p.addLine(to: CGPoint(x: x, y: canvas.height))
        return p
    }

    private func hLine(_ y: CGFloat, _ canvas: CGSize) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: y))
        p.addLine(to: CGPoint(x: canvas.width, y: y))
        return p
    }

    // MARK: - Depth (stacking-order) badges

    /// A small "n" badge at each box's top-right corner. Draw order = array order =
    /// front/back order the model reads on overlap, so a higher number sits in front.
    func depthBadgeOverlay(canvasSize: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(elements.enumerated()), id: \.element.id) { index, element in
                let rect = BBoxGeometry.normRect(element.bbox, in: canvasSize)
                let color = BBoxGeometry.boxColor(at: index, type: element.type)
                Text("\(index + 1)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(color))
                    .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 0.5))
                    .offset(x: rect.maxX - 15, y: rect.minY)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    // MARK: - Horizon line (camera POV)

    /// Draggable horizon line spanning the canvas. The line is non-interactive; the
    /// knob at the right edge takes the drag. Releasing writes `style_description.photo`.
    func horizonOverlay(canvasSize: CGSize) -> some View {
        let y = canvasSize.height * CGFloat(displayHorizonNorm) / 1000
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.orange.opacity(0.85))
                .frame(width: canvasSize.width, height: 1.5)
                .offset(y: y - 0.75)
                .allowsHitTesting(false)

            Text("horizon · \(displayPOV.label.lowercased())")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(.black.opacity(0.5)))
                .offset(x: 4, y: max(2, y - 16))
                .allowsHitTesting(false)

            Circle()
                .fill(Color.orange)
                .stroke(.white, lineWidth: 1.5)
                .frame(width: 12, height: 12)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
                .offset(x: canvasSize.width - 26, y: y - 13)
                .gesture(horizonDragGesture(canvasSize: canvasSize))
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
    }

    // MARK: - Orientation anchor (writes desc)

    /// Two labeled, draggable endpoints (default "head" → "feet") inside the selected
    /// box. The box stays the whole-object rectangle; the arrow only annotates the
    /// orientation of its contents into `desc`.
    func anchorOverlay(for element: IdeogramCaptionElement, canvasSize: CGSize) -> some View {
        let a = effectiveAnchorA(element)
        let b = effectiveAnchorB(element)
        let pa = anchorPoint(a, canvasSize)
        let pb = anchorPoint(b, canvasSize)
        return ZStack(alignment: .topLeading) {
            Path { p in
                p.move(to: pa)
                p.addLine(to: pb)
            }
            .stroke(Color.pink.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
            .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
            .allowsHitTesting(false)

            anchorKnob(label: anchorLabelA, at: pa, isA: true, canvasSize: canvasSize)
            anchorKnob(label: anchorLabelB, at: pb, isA: false, canvasSize: canvasSize)
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
    }

    private func anchorKnob(
        label: String, at pt: CGPoint, isA: Bool, canvasSize: CGSize
    ) -> some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.pink.opacity(0.9)))
            Circle()
                .fill(Color.pink)
                .stroke(.white, lineWidth: 1.5)
                .frame(width: 11, height: 11)
        }
        .frame(width: 44, height: 30)
        .contentShape(Rectangle())
        .offset(x: pt.x - 22, y: pt.y - 20)
        .gesture(anchorDragGesture(isA: isA, canvasSize: canvasSize))
    }

    @ViewBuilder
    func handleOverlay(for element: IdeogramCaptionElement, canvasSize: CGSize) -> some View {
        let rect = BBoxGeometry.normRect(element.bbox, in: canvasSize)
        let index = elements.firstIndex { $0.id == element.id } ?? 0
        let color = BBoxGeometry.boxColor(at: index, type: element.type)

        ForEach(BBoxResizeHandle.allCases, id: \.self) { handle in
            let pt = BBoxGeometry.handlePoint(handle, in: rect)
            // The visible dot stays small, but the draggable region is a larger
            // transparent square centered on the handle. A bare Circle only
            // hit-tests its filled path — a 10pt target whose edges read as
            // "not the whole dot". The padded frame + Rectangle contentShape
            // makes the entire `handleHitSize` square grab the handle.
            Circle()
                .fill(color)
                .stroke(.white, lineWidth: 1.5)
                .frame(width: handleRadius * 2, height: handleRadius * 2)
                .frame(width: handleHitSize, height: handleHitSize)
                .contentShape(Rectangle())
                .offset(x: pt.x - handleHitSize / 2, y: pt.y - handleHitSize / 2)
                .gesture(handleDragGesture(handle: handle, element: element, canvasSize: canvasSize))
        }
    }
}
