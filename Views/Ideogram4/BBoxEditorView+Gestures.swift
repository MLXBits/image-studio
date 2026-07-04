import SwiftUI

// MARK: - Gestures & element mutation

extension BBoxEditorView {
    func canvasGesture(canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    focusRequest += 1
                    dragStart = BBoxGeometry.clamp(value.startLocation, in: canvasSize)
                    if mode == .draw {
                        dragCurrent = BBoxGeometry.clamp(value.location, in: canvasSize)
                    } else {
                        let normStart = BBoxGeometry.toNorm(dragStart, in: canvasSize)
                        if let sel = selectedID, let el = element(withID: sel),
                           BBoxGeometry.contains(normStart, bbox: el.bbox) {
                            dragOriginalBBox = el.bbox
                            moveOffset = .zero
                        } else {
                            let hit = hitTest(normStart)
                            selectedID = hit?.id
                            if let hit {
                                dragOriginalBBox = hit.bbox
                                moveOffset = .zero
                            }
                        }
                    }
                }

                dragCurrent = BBoxGeometry.clamp(value.location, in: canvasSize)

                if mode == .select, let selID = selectedID, activeHandle == nil {
                    let delta = CGSize(
                        width: value.translation.width / canvasSize.width * 1000,
                        height: value.translation.height / canvasSize.height * 1000
                    )
                    updateElementPosition(id: selID, original: dragOriginalBBox, delta: delta)
                }
            }
            .onEnded { value in
                isDragging = false
                if mode == .draw {
                    let normBox = BBoxGeometry.normalizeBox(from: dragStart, to: dragCurrent, in: canvasSize)
                    if normBox[2] - normBox[0] >= minBoxNorm && normBox[3] - normBox[1] >= minBoxNorm {
                        pendingBBox = normBox
                        showCreatePopover = true
                        newElementType = .obj
                        newElementText = ""
                        newElementDesc = ""
                    }
                } else {
                    if value.translation == .zero {
                        let normPt = BBoxGeometry.toNorm(
                            BBoxGeometry.clamp(value.location, in: canvasSize), in: canvasSize
                        )
                        selectedID = hitTest(normPt)?.id
                    }
                }
            }
    }

    func handleDragGesture(
        handle: BBoxResizeHandle, element: IdeogramCaptionElement, canvasSize: CGSize
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if activeHandle == nil {
                    activeHandle = handle
                    dragOriginalBBox = element.bbox
                }
                let delta = CGSize(
                    width: value.translation.width / canvasSize.width * 1000,
                    height: value.translation.height / canvasSize.height * 1000
                )
                updateHandle(handle: handle, id: element.id, original: dragOriginalBBox, delta: delta)
            }
            .onEnded { _ in activeHandle = nil }
    }

    func commitCreate() {
        guard let bbox = pendingBBox,
              !newElementDesc.trimmingCharacters(in: .whitespaces).isEmpty else {
            showCreatePopover = false
            return
        }
        var el = IdeogramCaptionElement(type: newElementType, bbox: bbox, desc: newElementDesc)
        if newElementType == .text && !newElementText.isEmpty {
            el.text = newElementText
        }
        elements.append(el)
        selectedID = el.id
        mode = .select
        pendingBBox = nil
        showCreatePopover = false
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        elements.removeAll { $0.id == id }
        selectedID = nil
    }

    /// Preview bbox while drawing a new box, or nil when it's too small to matter.
    func previewBBox(canvasSize: CGSize) -> [Int]? {
        guard isDragging else { return nil }
        let box = BBoxGeometry.normalizeBox(from: dragStart, to: dragCurrent, in: canvasSize)
        return box[2] - box[0] >= 2 && box[3] - box[1] >= 2 ? box : nil
    }

    func element(withID id: UUID) -> IdeogramCaptionElement? {
        elements.first { $0.id == id }
    }

    /// Topmost element containing the normalized point (last drawn = on top).
    func hitTest(_ normPt: CGPoint) -> IdeogramCaptionElement? {
        elements.last { BBoxGeometry.contains(normPt, bbox: $0.bbox) }
    }

    func updateElementPosition(id: UUID, original: [Int], delta: CGSize) {
        guard let idx = elements.firstIndex(where: { $0.id == id }),
              let moved = BBoxGeometry.moved(original, delta: delta) else { return }
        elements[idx].bbox = moved
    }

    func updateHandle(handle: BBoxResizeHandle, id: UUID, original: [Int], delta: CGSize) {
        guard let idx = elements.firstIndex(where: { $0.id == id }),
              let resized = BBoxGeometry.resized(
                  original, handle: handle, delta: delta, minBox: minBoxNorm
              ) else { return }
        elements[idx].bbox = resized
    }

    // MARK: - Z-order (stacking) — array order is the front/back order

    func moveForward(id: UUID) {
        guard let idx = elements.firstIndex(where: { $0.id == id }), idx < elements.count - 1 else { return }
        elements.swapAt(idx, idx + 1)
    }

    func moveBackward(id: UUID) {
        guard let idx = elements.firstIndex(where: { $0.id == id }), idx > 0 else { return }
        elements.swapAt(idx, idx - 1)
    }

    // MARK: - Composition templates

    func chooseTemplate(_ template: BBoxTemplate) {
        if elements.isEmpty {
            applyTemplate(template, replace: true)
        } else {
            pendingTemplate = template
            showTemplateConfirm = true
        }
    }

    func applyTemplate(_ template: BBoxTemplate, replace: Bool) {
        // Fresh ids: the static library holds fixed UUIDs, so appending the same
        // template twice would collide without regenerating them.
        let fresh = template.elements.map { el -> IdeogramCaptionElement in
            var copy = el
            copy.id = UUID()
            return copy
        }
        if replace { elements = fresh } else { elements += fresh }
        selectedID = nil
        mode = .select
        pendingTemplate = nil
    }

    // MARK: - Camera angle → style_description.photo (horizon line)

    private func writeCameraPOV(_ pov: CameraPOV) {
        guard let cameraStyle else { return }
        var style = cameraStyle.wrappedValue ?? IdeogramCaptionStyle()
        style.photo = pov.write(to: style.photo)
        cameraStyle.wrappedValue = style
    }

    func horizonDragGesture(canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(BBoxEditorView.canvasSpace))
            .onChanged { value in
                draggingHorizon = true
                let ny = Int((value.location.y / max(canvasSize.height, 1) * 1000).rounded())
                horizonNorm = max(0, min(1000, ny))
            }
            .onEnded { _ in
                draggingHorizon = false
                writeCameraPOV(CameraPOV.forHorizon(horizonNorm))
            }
    }

    // MARK: - Orientation anchor → element desc

    /// Head endpoint default: top-center of the box.
    func defaultAnchorA(_ el: IdeogramCaptionElement) -> CGPoint {
        let cx = CGFloat(el.bbox[1] + el.bbox[3]) / 2
        let margin = max(30, CGFloat(el.bbox[2] - el.bbox[0]) / 6)
        return CGPoint(x: cx, y: CGFloat(el.bbox[0]) + margin)
    }

    /// Feet endpoint default: bottom-center of the box.
    func defaultAnchorB(_ el: IdeogramCaptionElement) -> CGPoint {
        let cx = CGFloat(el.bbox[1] + el.bbox[3]) / 2
        let margin = max(30, CGFloat(el.bbox[2] - el.bbox[0]) / 6)
        return CGPoint(x: cx, y: CGFloat(el.bbox[2]) - margin)
    }

    func effectiveAnchorA(_ el: IdeogramCaptionElement) -> CGPoint {
        anchorA ?? defaultAnchorA(el)
    }

    func effectiveAnchorB(_ el: IdeogramCaptionElement) -> CGPoint {
        anchorB ?? defaultAnchorB(el)
    }

    /// 0–1000 norm point → canvas pixels.
    func anchorPoint(_ norm: CGPoint, _ canvas: CGSize) -> CGPoint {
        CGPoint(x: canvas.width * norm.x / 1000, y: canvas.height * norm.y / 1000)
    }

    /// Canvas pixels → 0–1000 norm point, clamped.
    func anchorNorm(_ pt: CGPoint, _ canvas: CGSize) -> CGPoint {
        CGPoint(
            x: max(0, min(1000, pt.x / max(canvas.width, 1) * 1000)),
            y: max(0, min(1000, pt.y / max(canvas.height, 1) * 1000))
        )
    }

    /// Clears anchors when the selection or orientation mode changes so the next
    /// box gets sensible defaults.
    func resetAnchors() {
        anchorForID = selectedID
        anchorA = nil
        anchorB = nil
    }

    func anchorDragGesture(isA: Bool, canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(BBoxEditorView.canvasSpace))
            .onChanged { value in
                let norm = anchorNorm(value.location, canvasSize)
                if isA { anchorA = norm } else { anchorB = norm }
            }
            .onEnded { _ in writeOrientation() }
    }

    /// Writes the orientation clause to the selected element's `desc`, replacing any
    /// previously-written clause rather than duplicating it.
    func writeOrientation() {
        guard let id = selectedID,
              let idx = elements.firstIndex(where: { $0.id == id }) else { return }
        let el = elements[idx]
        let zoneA = BBoxGeometry.frameZone(forNorm: effectiveAnchorA(el))
        let zoneB = BBoxGeometry.frameZone(forNorm: effectiveAnchorB(el))
        let labelA = anchorLabelA.trimmingCharacters(in: .whitespaces)
        let labelB = anchorLabelB.trimmingCharacters(in: .whitespaces)
        elements[idx].desc = OrientationClause.apply(
            partA: labelA.isEmpty ? "head" : labelA, zoneA: zoneA,
            partB: labelB.isEmpty ? "feet" : labelB, zoneB: zoneB,
            to: el.desc
        )
    }
}
