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
}
