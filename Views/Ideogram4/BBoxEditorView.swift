import AppKit
import SwiftUI

// This view is deliberately split across BBoxEditorView+Canvas/+Gestures/+Subviews.
// Cross-file extensions can't reach `private` members, so the @State below is
// internal — which trips `private_swiftui_state`. Disable it for this file only.
// swiftlint:disable private_swiftui_state

// MARK: - BBox editor mode

enum BBoxEditorMode { case draw, select }

// MARK: - BBoxEditorView

/// Interactive canvas for placing and resizing Ideogram bounding boxes.
/// Coordinates are in 0–1000 normalized space (matching Ideogram's schema).
///
/// The implementation is split across files: drawing in `BBoxEditorView+Canvas`,
/// gestures and element mutation in `BBoxEditorView+Gestures`, the toolbar /
/// side-panel / create-popover chrome in `BBoxEditorView+Subviews`, the stateless
/// coordinate math in `BBoxGeometry`, and the key handler in `BBoxKeyCatcher`.
/// The `@State` is internal (not private) so those extensions can reach it.
struct BBoxEditorView: View {
    /// Named coordinate space for the canvas-sized container, so small draggable
    /// overlays (horizon knob, orientation anchors) get canvas-relative locations.
    static let canvasSpace = "bboxCanvas"

    @Binding var elements: [IdeogramCaptionElement]
    let outputWidth: Int
    let outputHeight: Int
    var isExpanded: Bool = false
    /// When set, drawn behind the boxes (filling the coordinate-space canvas) so
    /// boxes can be adjusted against the image that generated them.
    var backgroundImage: NSImage?
    /// Optional binding to the caption's style, so the camera-POV control can write
    /// `style_description.photo` (camera lives in its own JSON field, never in a
    /// bbox). When nil, the POV control and horizon line are hidden.
    var cameraStyle: Binding<IdeogramCaptionStyle?>?

    @State var mode: BBoxEditorMode = .select
    @State var selectedID: UUID?
    @State var showCreatePopover: Bool = false
    @State var newElementType: IdeogramElementType = .obj
    @State var newElementText: String = ""
    @State var newElementDesc: String = ""
    @State var pendingBBox: [Int]?
    @State var dragStart: CGPoint = .zero
    @State var dragCurrent: CGPoint = .zero
    @State var isDragging: Bool = false
    @State var activeHandle: BBoxResizeHandle?
    @State var dragOriginalBBox: [Int] = []
    @State var moveOffset: CGSize = .zero
    @State var showExpandedSheet: Bool = false
    @State var focusRequest: Int = 0
    @FocusState var isPopoverFocused: Bool

    /// Composition guides (rule-of-thirds + center + horizon).
    @State var showGuides: Bool = true
    /// Live horizon position (0–1000 y) *while dragging only*. When not dragging,
    /// the rendered line is derived from the shared POV so every editor instance
    /// shows the same line for the same caption — see `displayHorizonNorm`.
    @State var horizonNorm: Int = 500
    @State var draggingHorizon: Bool = false

    // Orientation anchor (writes the selected element's `desc`).
    @State var orientationMode: Bool = false
    @State var anchorForID: UUID?
    @State var anchorA: CGPoint? // 0–1000 norm (x,y); "head" endpoint
    @State var anchorB: CGPoint? // 0–1000 norm (x,y); "feet" endpoint
    @State var anchorLabelA: String = "head"
    @State var anchorLabelB: String = "feet"

    // Composition templates.
    @State var pendingTemplate: BBoxTemplate?
    @State var showTemplateConfirm: Bool = false

    let handleRadius: CGFloat = 5
    /// Side of the transparent square hit area around each resize handle. Larger
    /// than the visible dot (`handleRadius * 2`) so the whole circle is grabbable.
    let handleHitSize: CGFloat = 20
    let minBoxNorm: Int = 20
    // swiftlint:enable private_swiftui_state

    // MARK: - Body

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
        .onAppear {
            if let pov = CameraPOV.current(in: cameraStyle?.wrappedValue?.photo) {
                horizonNorm = pov.defaultHorizon
            }
        }
        .onChange(of: selectedID) { _, _ in resetAnchors() }
        .onChange(of: orientationMode) { _, _ in resetAnchors() }
        .confirmationDialog(
            "Apply “\(pendingTemplate?.name ?? "")” layout?",
            isPresented: $showTemplateConfirm,
            titleVisibility: .visible
        ) {
            Button("Replace existing boxes", role: .destructive) {
                if let t = pendingTemplate { applyTemplate(t, replace: true) }
            }
            Button("Add to existing") {
                if let t = pendingTemplate { applyTemplate(t, replace: false) }
            }
            Button("Cancel", role: .cancel) { pendingTemplate = nil }
        } message: {
            Text("You already have boxes on the canvas.")
        }
    }

    // MARK: - Camera POV helpers

    /// Whether the camera-POV control applies: a style binding exists and the
    /// caption isn't in explicit art-style mode (`photo` is photo-mode only).
    var cameraAvailable: Bool {
        guard cameraStyle != nil else { return false }
        return (cameraStyle?.wrappedValue?.artStyle ?? "").isEmpty
    }

    /// POV currently reflected in `photo`, falling back to the horizon position.
    var currentPOV: CameraPOV {
        CameraPOV.current(in: cameraStyle?.wrappedValue?.photo)
            ?? CameraPOV.forHorizon(horizonNorm)
    }

    /// POV to show right now: tracks the finger while dragging, otherwise the
    /// shared `photo` value. Drives both the line position and its label so they
    /// never diverge (and stay in sync across editor instances).
    var displayPOV: CameraPOV {
        draggingHorizon ? CameraPOV.forHorizon(horizonNorm) : currentPOV
    }

    /// Rendered horizon-line position (0–1000 y): the live drag value while
    /// dragging, otherwise the shared POV's canonical position.
    var displayHorizonNorm: Int {
        draggingHorizon ? horizonNorm : displayPOV.defaultHorizon
    }

    var editorCanvas: some View {
        VStack(spacing: 0) {
            modeToolbar
            Divider()
            GeometryReader { geo in
                // Pixel-align the canvas so the text Canvas isn't composited over
                // the background image at a sub-point offset, which bilinearly
                // resamples (and blurs) the rendered labels. Rounding size and
                // origin to whole points keeps glyphs crisp on 1x and 2x displays.
                let fitted = BBoxGeometry.fitCanvas(
                    width: outputWidth, height: outputHeight, in: geo.size
                )
                let canvasSize = CGSize(
                    width: fitted.width.rounded(), height: fitted.height.rounded()
                )
                let canvasOrigin = CGPoint(
                    x: ((geo.size.width - canvasSize.width) / 2).rounded(),
                    y: ((geo.size.height - canvasSize.height) / 2).rounded()
                )

                ZStack(alignment: .topLeading) {
                    Color(nsColor: .underPageBackgroundColor)
                        .frame(width: geo.size.width, height: geo.size.height)

                    ZStack(alignment: .topLeading) {
                        if let backgroundImage {
                            Image(nsImage: backgroundImage)
                                .resizable()
                                .frame(width: canvasSize.width, height: canvasSize.height)
                        } else {
                            Color(nsColor: .windowBackgroundColor)
                                .frame(width: canvasSize.width, height: canvasSize.height)
                                .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                        }

                        // Composition guides sit above the background but below the
                        // boxes, so they never obscure the boxes.
                        if showGuides {
                            Canvas { ctx, size in
                                drawGuides(ctx: ctx, size: size, canvasSize: canvasSize)
                            }
                            .frame(width: canvasSize.width, height: canvasSize.height)
                            .allowsHitTesting(false)
                        }

                        Canvas { ctx, size in
                            drawBoxes(ctx: ctx, size: size, canvasSize: canvasSize)
                        }
                        .frame(width: canvasSize.width, height: canvasSize.height)

                        // Native-text labels above the box Canvas (crisp glyphs).
                        labelOverlay(canvasSize: canvasSize)

                        // Stacking-order badges so overlap reads as front/back.
                        if elements.count > 1 {
                            depthBadgeOverlay(canvasSize: canvasSize)
                        }

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
                                        let normPt = BBoxGeometry.toNorm(
                                            BBoxGeometry.clamp(event.location, in: canvasSize),
                                            in: canvasSize
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

                        // Draggable horizon line (camera POV). Above the boxes so its
                        // knob wins drags; the line itself is non-interactive.
                        if showGuides && cameraAvailable {
                            horizonOverlay(canvasSize: canvasSize)
                        }

                        // Orientation anchor for the selected box (writes `desc`).
                        if orientationMode, let sel = selectedElement, mode == .select {
                            anchorOverlay(for: sel, canvasSize: canvasSize)
                        }
                    }
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .coordinateSpace(name: Self.canvasSpace)
                    .offset(x: canvasOrigin.x, y: canvasOrigin.y)
                    .popover(isPresented: $showCreatePopover, arrowEdge: .bottom) {
                        createPopover
                    }
                }
            }
        }
    }
}
