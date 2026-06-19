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
    @Binding var elements: [IdeogramCaptionElement]
    let outputWidth: Int
    let outputHeight: Int
    var isExpanded: Bool = false
    /// When set, drawn behind the boxes (filling the coordinate-space canvas) so
    /// boxes can be adjusted against the image that generated them.
    var backgroundImage: NSImage?

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

    let handleRadius: CGFloat = 5
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
    }

    var editorCanvas: some View {
        VStack(spacing: 0) {
            modeToolbar
            Divider()
            GeometryReader { geo in
                let canvasSize = BBoxGeometry.fitCanvas(
                    width: outputWidth, height: outputHeight, in: geo.size
                )
                let canvasOrigin = CGPoint(
                    x: (geo.size.width - canvasSize.width) / 2,
                    y: (geo.size.height - canvasSize.height) / 2
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
}
