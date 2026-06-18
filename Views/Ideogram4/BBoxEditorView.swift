import AppKit
import SwiftUI

// MARK: - BBox editor mode

enum BBoxEditorMode { case draw, select }

// MARK: - Active handle

private enum ResizeHandle: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
    case topMid, bottomMid, leftMid, rightMid
}

// MARK: - BBoxEditorView

/// Interactive canvas for placing and resizing Ideogram bounding boxes.
/// Coordinates are in 0–1000 normalized space (matching Ideogram's schema).
struct BBoxEditorView: View {
    @Binding var elements: [IdeogramCaptionElement]
    let outputWidth: Int
    let outputHeight: Int
    var isExpanded: Bool = false

    @State private var mode: BBoxEditorMode = .select
    @State private var selectedID: UUID?
    @State private var showCreatePopover: Bool = false
    @State private var newElementType: IdeogramElementType = .obj
    @State private var newElementText: String = ""
    @State private var newElementDesc: String = ""
    @State private var pendingBBox: [Int]?
    @State private var dragStart: CGPoint = .zero
    @State private var dragCurrent: CGPoint = .zero
    @State private var isDragging: Bool = false
    @State private var activeHandle: ResizeHandle?
    @State private var dragOriginalBBox: [Int] = []
    @State private var moveOffset: CGSize = .zero
    @State private var showExpandedSheet: Bool = false
    @State private var focusRequest: Int = 0
    @FocusState private var isPopoverFocused: Bool

    private let handleRadius: CGFloat = 5
    private let minBoxNorm: Int = 20

    // MARK: - Body (instance_property)

    var body: some View {
        Group {
            if isExpanded {
                HStack(spacing: 0) {
                    editorCanvas
                    Divider()
                    elementSidePanel
                }
            } else {
                editorCanvas
            }
        }
        .sheet(isPresented: $showExpandedSheet) { expandedSheet }
    }

    private var editorCanvas: some View {
        VStack(spacing: 0) {
            modeToolbar
            Divider()
            GeometryReader { geo in
                let canvasSize = fitCanvas(in: geo.size)
                let canvasOrigin = CGPoint(
                    x: (geo.size.width - canvasSize.width) / 2,
                    y: (geo.size.height - canvasSize.height) / 2
                )

                ZStack(alignment: .topLeading) {
                    Color(nsColor: .underPageBackgroundColor)
                        .frame(width: geo.size.width, height: geo.size.height)

                    ZStack(alignment: .topLeading) {
                        Color(nsColor: .windowBackgroundColor)
                            .frame(width: canvasSize.width, height: canvasSize.height)
                            .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)

                        Canvas { ctx, size in
                            drawBoxes(ctx: ctx, size: size, canvasSize: canvasSize)
                        }
                        .frame(width: canvasSize.width, height: canvasSize.height)

                        // Color.clear is BELOW the handle overlay so handle circles
                        // sit on top and receive drag events before the canvas does.
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(canvasGesture(canvasSize: canvasSize))
                            .simultaneousGesture(
                                SpatialTapGesture()
                                    .onEnded { event in
                                        focusRequest += 1
                                        guard mode == .select else { return }
                                        let normPt = toNorm(
                                            clamp(event.location, in: canvasSize), in: canvasSize
                                        )
                                        selectedID = hitTest(normPt)?.id
                                    }
                            )

                        // Zero-size AppKit responder: reliably receives the Delete /
                        // Escape keys once we make it first responder on selection.
                        BBoxKeyCatcher(
                            focusTrigger: focusRequest,
                            onDelete: { deleteSelected() },
                            onEscape: { selectedID = nil }
                        )
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)

                        if isDragging && mode == .draw, let bbox = previewBBox(canvasSize: canvasSize) {
                            Rectangle()
                                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                                .frame(
                                    width: canvasSize.width * CGFloat(bbox[3] - bbox[1]) / 1000,
                                    height: canvasSize.height * CGFloat(bbox[2] - bbox[0]) / 1000
                                )
                                .offset(
                                    x: canvasSize.width * CGFloat(bbox[1]) / 1000,
                                    y: canvasSize.height * CGFloat(bbox[0]) / 1000
                                )
                                .allowsHitTesting(false)
                        }

                        if let sel = selectedElement, mode == .select {
                            handleOverlay(for: sel, canvasSize: canvasSize)
                        }
                    }
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .offset(x: canvasOrigin.x, y: canvasOrigin.y)
                    .popover(isPresented: $showCreatePopover, arrowEdge: .bottom) {
                        createPopover
                    }
                }
            }
        }
    }

    // MARK: - Computed views (instance_property)

    private var modeToolbar: some View {
        HStack(spacing: 4) {
            toolbarButton("cursorarrow", label: "Select", active: mode == .select) {
                mode = .select
            }
            toolbarButton("rectangle.dashed", label: "Draw bbox (drag on canvas)", active: mode == .draw) {
                mode = .draw
                selectedID = nil
            }
            toolbarButton("plus", label: "Add element (centered default)", active: false) {
                pendingBBox = [250, 250, 750, 750]
                newElementType = .obj
                newElementText = ""
                newElementDesc = ""
                showCreatePopover = true
            }
            if !isExpanded {
                Spacer()
                toolbarButton("arrow.up.left.and.arrow.down.right", label: "Expand editor", active: false) {
                    showExpandedSheet = true
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var expandedSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Bounding Boxes")
                    .font(.headline)
                Spacer()
                Button("Done") { showExpandedSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }

            Self(elements: $elements, outputWidth: outputWidth, outputHeight: outputHeight, isExpanded: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 940, height: 600)
    }

    // MARK: - Element side panel (expanded mode only)

    private var elementSidePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Elements").font(.headline)
                Spacer()
                Text("\(elements.count)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            Divider()

            if elements.isEmpty {
                VStack(spacing: 4) {
                    Spacer()
                    Text("No elements yet").font(.callout).foregroundStyle(.tertiary)
                    Text("Draw a box on the canvas").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach($elements) { $el in
                            IdeogramElementCard(
                                element: $el,
                                accentColor: boxColor(
                                    at: elements.firstIndex { $0.id == el.id } ?? 0,
                                    type: el.type
                                ),
                                isSelected: el.id == selectedID,
                                onSelect: {
                                    selectedID = el.id
                                    focusRequest += 1
                                },
                                onRemove: {
                                    if selectedID == el.id { selectedID = nil }
                                    elements.removeAll { $0.id == el.id }
                                }
                            )
                        }
                    }
                    .padding(10)
                }
            }
        }
        .frame(width: 260)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var createPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Element").font(.headline)

            Picker("Type", selection: $newElementType) {
                Text("Object").tag(IdeogramElementType.obj)
                Text("Text").tag(IdeogramElementType.text)
            }
            .pickerStyle(.segmented)

            if newElementType == .text {
                LabeledContent("Text") {
                    TextField("visible text...", text: $newElementText)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 200)
                        .focused($isPopoverFocused)
                }
            }

            LabeledContent("Description") {
                TextField("describe the element...", text: $newElementDesc)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 200)
            }

            HStack {
                Button("Cancel") {
                    showCreatePopover = false
                    pendingBBox = nil
                }
                Spacer()
                Button("Add") { commitCreate() }
                    .disabled(newElementDesc.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.return)
            }
        }
        .padding()
        .frame(width: 280)
        .onAppear { isPopoverFocused = newElementType == .text }
    }

    private var selectedElement: IdeogramCaptionElement? {
        elements.first { $0.id == selectedID }
    }

    // MARK: - Methods (other_method)

    private func toolbarButton(
        _ icon: String, label: String, active: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption)
                .frame(width: 26, height: 22)
                .background(active ? Color.accentColor : Color.secondary.opacity(0.15))
                .foregroundStyle(active ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(label)
    }

    /// A distinct shade within the type's colour family (blue for text, green for
    /// objects). Shades are spread by index using a golden-ratio step so adjacent
    /// boxes are easy to tell apart while staying recognisably blue/green.
    private func boxColor(at index: Int, type: IdeogramElementType) -> Color {
        let baseHue: Double = type == .text ? 0.58 : 0.36
        let frac = (Double(index) * 0.618).truncatingRemainder(dividingBy: 1)
        let hue = baseHue + (frac - 0.5) * 0.10 // ±0.05 jitter — stays in family
        let saturation = 0.55 + frac * 0.40 // 0.55…0.95
        let brightness = 0.95 - frac * 0.30 // 0.95…0.65
        return Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    private func drawBoxes(ctx: GraphicsContext, size _: CGSize, canvasSize: CGSize) {
        for (index, element) in elements.enumerated() {
            let rect = normRect(element.bbox, in: canvasSize)
            let isSelected = element.id == selectedID
            let color = boxColor(at: index, type: element.type)

            ctx.fill(Path(rect.insetBy(dx: 0, dy: 0)), with: .color(color.opacity(0.12)))
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
                ctx.draw(
                    Text(line1)
                        .font(.system(size: fontSize, weight: .semibold))
                        .foregroundStyle(color.opacity(0.9)),
                    at: topPt, anchor: .topLeading
                )
                if inset.height > 26 {
                    let descPt = CGPoint(x: inset.minX, y: inset.minY + fontSize + 2)
                    ctx.draw(
                        Text(line2)
                            .font(.system(size: max(7, fontSize - 1)))
                            .foregroundStyle(color.opacity(0.7)),
                        at: descPt, anchor: .topLeading
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func handleOverlay(for element: IdeogramCaptionElement, canvasSize: CGSize) -> some View {
        let rect = normRect(element.bbox, in: canvasSize)
        let index = elements.firstIndex { $0.id == element.id } ?? 0
        let color = boxColor(at: index, type: element.type)

        ForEach(ResizeHandle.allCases, id: \.self) { handle in
            let pt = handlePoint(handle, in: rect)
            Circle()
                .fill(color)
                .stroke(.white, lineWidth: 1.5)
                .frame(width: handleRadius * 2, height: handleRadius * 2)
                .offset(x: pt.x - handleRadius, y: pt.y - handleRadius)
                .gesture(handleDragGesture(handle: handle, element: element, canvasSize: canvasSize))
        }
    }

    private func canvasGesture(canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    focusRequest += 1
                    dragStart = clamp(value.startLocation, in: canvasSize)
                    if mode == .draw {
                        dragCurrent = clamp(value.location, in: canvasSize)
                    } else {
                        let normStart = toNorm(dragStart, in: canvasSize)
                        if let sel = selectedID, let el = element(withID: sel),
                           normPointInBox(normStart, el.bbox) {
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

                dragCurrent = clamp(value.location, in: canvasSize)

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
                    let normBox = normalizeBox(from: dragStart, to: dragCurrent, in: canvasSize)
                    if normBox[2] - normBox[0] >= minBoxNorm && normBox[3] - normBox[1] >= minBoxNorm {
                        pendingBBox = normBox
                        showCreatePopover = true
                        newElementType = .obj
                        newElementText = ""
                        newElementDesc = ""
                    }
                } else {
                    if value.translation == .zero {
                        let normPt = toNorm(clamp(value.location, in: canvasSize), in: canvasSize)
                        selectedID = hitTest(normPt)?.id
                    }
                }
            }
    }

    private func handleDragGesture(
        handle: ResizeHandle, element: IdeogramCaptionElement, canvasSize: CGSize
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

    private func commitCreate() {
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

    private func element(withID id: UUID) -> IdeogramCaptionElement? {
        elements.first { $0.id == id }
    }

    private func hitTest(_ normPt: CGPoint) -> IdeogramCaptionElement? {
        elements.last { normPointInBox(normPt, $0.bbox) }
    }

    private func normPointInBox(_ pt: CGPoint, _ bbox: [Int]) -> Bool {
        guard bbox.count == 4 else { return false }
        return pt.x >= CGFloat(bbox[1]) && pt.x <= CGFloat(bbox[3])
            && pt.y >= CGFloat(bbox[0]) && pt.y <= CGFloat(bbox[2])
    }

    private func normRect(_ bbox: [Int], in canvas: CGSize) -> CGRect {
        guard bbox.count == 4 else { return .zero }
        let x = canvas.width * CGFloat(bbox[1]) / 1000
        let y = canvas.height * CGFloat(bbox[0]) / 1000
        let w = canvas.width * CGFloat(bbox[3] - bbox[1]) / 1000
        let h = canvas.height * CGFloat(bbox[2] - bbox[0]) / 1000
        return CGRect(x: x, y: y, width: max(1, w), height: max(1, h))
    }

    private func toNorm(_ pt: CGPoint, in canvas: CGSize) -> CGPoint {
        CGPoint(x: pt.x / canvas.width * 1000, y: pt.y / canvas.height * 1000)
    }

    private func clamp(_ pt: CGPoint, in canvas: CGSize) -> CGPoint {
        CGPoint(
            x: max(0, min(canvas.width, pt.x)),
            y: max(0, min(canvas.height, pt.y))
        )
    }

    private func normalizeBox(from start: CGPoint, to end: CGPoint, in canvas: CGSize) -> [Int] {
        let n1 = toNorm(start, in: canvas)
        let n2 = toNorm(end, in: canvas)
        let y1 = Int(min(n1.y, n2.y).rounded())
        let x1 = Int(min(n1.x, n2.x).rounded())
        let y2 = Int(max(n1.y, n2.y).rounded())
        let x2 = Int(max(n1.x, n2.x).rounded())
        return [
            max(0, min(y1, 1000)), max(0, min(x1, 1000)),
            max(0, min(y2, 1000)), max(0, min(x2, 1000)),
        ]
    }

    private func previewBBox(canvasSize: CGSize) -> [Int]? {
        guard isDragging else { return nil }
        let box = normalizeBox(from: dragStart, to: dragCurrent, in: canvasSize)
        return box[2] - box[0] >= 2 && box[3] - box[1] >= 2 ? box : nil
    }

    private func handlePoint(_ handle: ResizeHandle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .topMid: CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .leftMid: CGPoint(x: rect.minX, y: rect.midY)
        case .rightMid: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomMid: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    private func updateElementPosition(id: UUID, original: [Int], delta: CGSize) {
        guard let idx = elements.firstIndex(where: { $0.id == id }),
              original.count == 4 else { return }
        let dx = Int(delta.width.rounded())
        let dy = Int(delta.height.rounded())
        let w = original[3] - original[1]
        let h = original[2] - original[0]
        let x1 = max(0, min(1000 - w, original[1] + dx))
        let y1 = max(0, min(1000 - h, original[0] + dy))
        elements[idx].bbox = [y1, x1, y1 + h, x1 + w]
    }

    private func updateHandle(handle: ResizeHandle, id: UUID, original: [Int], delta: CGSize) {
        guard let idx = elements.firstIndex(where: { $0.id == id }),
              original.count == 4 else { return }
        let dx = Int(delta.width.rounded())
        let dy = Int(delta.height.rounded())
        var y1 = original[0], x1 = original[1], y2 = original[2], x2 = original[3]

        switch handle {
        case .topLeft: y1 += dy; x1 += dx
        case .topMid: y1 += dy
        case .topRight: y1 += dy; x2 += dx
        case .leftMid: x1 += dx
        case .rightMid: x2 += dx
        case .bottomLeft: y2 += dy; x1 += dx
        case .bottomMid: y2 += dy
        case .bottomRight: y2 += dy; x2 += dx
        }

        y1 = max(0, min(y1, 1000)); x1 = max(0, min(x1, 1000))
        y2 = max(0, min(y2, 1000)); x2 = max(0, min(x2, 1000))
        let topHandles: Set<ResizeHandle> = [.topLeft, .topMid, .topRight]
        let leftHandles: Set<ResizeHandle> = [.topLeft, .leftMid, .bottomLeft]
        if y2 - y1 < minBoxNorm {
            if topHandles.contains(handle) { y1 = y2 - minBoxNorm } else { y2 = y1 + minBoxNorm }
        }
        if x2 - x1 < minBoxNorm {
            if leftHandles.contains(handle) { x1 = x2 - minBoxNorm } else { x2 = x1 + minBoxNorm }
        }

        elements[idx].bbox = [y1, x1, y2, x2]
    }

    private func deleteSelected() {
        guard let id = selectedID else { return }
        elements.removeAll { $0.id == id }
        selectedID = nil
    }

    private func fitCanvas(in available: CGSize) -> CGSize {
        let ratio = Double(outputWidth) / Double(max(outputHeight, 1))
        let maxH = available.height
        let maxW = available.width
        if maxW / ratio <= maxH {
            return CGSize(width: maxW, height: maxW / ratio)
        }
        return CGSize(width: maxH * ratio, height: maxH)
    }
}

// MARK: - BBoxKeyCatcher

/// Zero-size AppKit responder bridged into SwiftUI. SwiftUI's `.onKeyPress` +
/// `@FocusState` does not reliably take first-responder for a gesture-driven
/// canvas embedded in a scrolling form on macOS, so deletion is driven through
/// an `NSView` that we explicitly make first responder whenever the selection
/// changes (`focusTrigger` is bumped on every tap / drag).
private struct BBoxKeyCatcher: NSViewRepresentable {
    var focusTrigger: Int
    var onDelete: () -> Void
    var onEscape: () -> Void

    func makeNSView(context _: Context) -> KeyView {
        let view = KeyView()
        view.onDelete = onDelete
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: KeyView, context _: Context) {
        nsView.onDelete = onDelete
        nsView.onEscape = onEscape
        guard nsView.lastTrigger != focusTrigger else { return }
        nsView.lastTrigger = focusTrigger
        DispatchQueue.main.async { [weak nsView] in
            nsView?.window?.makeFirstResponder(nsView)
        }
    }
}

// MARK: - BBoxKeyCatcher.KeyView

/// Accepts first responder and routes Delete / Escape key codes to closures.
private final class KeyView: NSView {
    var onDelete: (() -> Void)?
    var onEscape: (() -> Void)?
    /// Starts at 0 to match `focusRequest`'s initial value, so the catcher
    /// does not steal focus on first appearance — only after a real selection.
    var lastTrigger: Int = 0

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: onDelete?() // 51 = delete/backspace, 117 = forward delete
        case 53: onEscape?() // 53 = escape
        default: super.keyDown(with: event)
        }
    }
}
