import AppKit
import SwiftUI

/// Identifies the two images in the Compare overlay by gallery id.
struct ComparePair: Equatable {
    var selectId: UUID
    var candidateId: UUID
}

/// Lightroom-style two-up Compare overlay: a pinned **Select** (your current champion)
/// on the left and a **Candidate** challenger on the right. Zoom and pan are *linked*
/// across both panes so you inspect the same region at the same magnification. Arrow
/// keys cycle the candidate through its siblings while the select holds still; ↑/⏎
/// promotes the candidate to select (swap). Culling keys (p/x/u, 0–5) act on the
/// candidate — the image under evaluation.
struct CompareView: View {
    private static let imagePadding: CGFloat = 16

    let selectItem: GalleryItem
    let candidateItem: GalleryItem
    /// 1-based position of the candidate among its siblings, and the sibling count,
    /// for the "3 / 12" readout. `count <= 1` hides the cycle affordance.
    var candidatePosition: Int = 1
    var candidateCount: Int = 1
    let onDismiss: () -> Void
    let onCycleCandidate: (Int) -> Void
    let onSwap: () -> Void
    let onFlagCandidate: (PickFlag?) -> Void
    let onRateCandidate: (Int) -> Void

    @State private var selectImage: NSImage?
    @State private var candidateImage: NSImage?
    @State private var zoom = ImageZoomState()
    @State private var selectFrame: CGRect = .zero
    @State private var viewFrame: CGRect = .zero
    @State private var monitors = EventMonitors()
    @State private var hostWindow = WindowRef()

    private var canCycle: Bool {
        candidateCount > 1
    }

    var body: some View {
        ZStack {
            Color.black

            VStack(spacing: 8) {
                topBar
                HStack(spacing: 2) {
                    pane(
                        title: "Select",
                        item: selectItem,
                        image: selectImage,
                        tint: .accentColor,
                        isCandidate: false
                    )
                    pane(
                        title: "Candidate",
                        item: candidateItem,
                        image: candidateImage,
                        tint: .orange,
                        isCandidate: true
                    )
                }
                hintBar
            }
            .padding(12)
        }
        .background { WindowAccessor { hostWindow.window = $0 } }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { viewFrame = geo.frame(in: .global) }
                    .onChange(of: geo.frame(in: .global)) { _, new in viewFrame = new }
            }
        }
        .onAppear {
            loadSelect()
            loadCandidate()
            installMonitors()
        }
        .onDisappear { monitors.removeAll() }
        .onChange(of: selectItem.id) { _, _ in loadSelect(); zoom.reset() }
        .onChange(of: candidateItem.id) { _, _ in loadCandidate(); zoom.reset() }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { onDismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3).symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.iconButton)
            .accessibilityLabel("Close compare")

            Text("Compare").font(.headline).foregroundStyle(.white)

            Spacer()

            Button { onSwap() } label: {
                // Pill chrome belongs inside the label: applied after .buttonStyle it
                // would draw a large capsule whose only clickable part is the text.
                Label("Make Select", systemImage: "arrow.left.arrow.right")
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .frame(minHeight: IconButtonMetrics.size)
                    .background(.white.opacity(0.14), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .help("Promote the candidate to the select (⏎)")

            if canCycle {
                HStack(spacing: 8) {
                    Button { cycle(-1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.iconButton).foregroundStyle(.white)
                        .accessibilityLabel("Previous candidate")
                    Text("\(candidatePosition) / \(candidateCount)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                    Button { cycle(1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.iconButton).foregroundStyle(.white)
                        .accessibilityLabel("Next candidate")
                }
            }

            if zoom.isZoomed {
                Button { zoom.reset() } label: {
                    Label("Fit", systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.callout)
                        .frame(minHeight: IconButtonMetrics.size)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    private var hintBar: some View {
        Text("←/→ cycle candidate · ⏎ make select · P pick · X reject · 0–5 rate candidate · scroll to zoom · Esc close")
            .font(.caption2).foregroundStyle(.white.opacity(0.5))
    }

    /// Both panes share one offset and have the same size, so the Select pane's
    /// frame stands for both, and each image can pan to its own edges.
    private var fit: ImageZoomState.Fit {
        ImageZoomState.Fit(
            images: [selectImage, candidateImage].compactMap { $0?.size },
            frame: selectFrame,
            padding: Self.imagePadding
        )
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { zoom.pan(by: $0.translation, in: fit) }
            .onEnded { _ in zoom.endPan(in: fit) }
    }

    // MARK: - Pane

    private func pane(
        title: String,
        item: GalleryItem,
        image: NSImage?,
        tint: Color,
        isCandidate: Bool
    ) -> some View {
        ZStack {
            Color.white.opacity(0.03)
            GeometryReader { geo in
                Group {
                    if let image {
                        Image(nsImage: image)
                            .resizable().scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(Self.imagePadding)
                            .scaleEffect(zoom.scale, anchor: .center)
                            .offset(zoom.offset)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .onAppear {
                    if !isCandidate {
                        selectFrame = geo.frame(in: .global)
                    }
                }
                .onChange(of: geo.frame(in: .global)) { _, new in
                    if !isCandidate {
                        selectFrame = new
                    }
                }
            }
            .gesture(zoom.isZoomed ? panGesture : nil)
            .onTapGesture(count: 2) { toggleZoom() }
        }
        .clipped()
        .overlay(alignment: .topLeading) { paneBadge(title: title, item: item, tint: tint) }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(tint.opacity(isCandidate ? 0.9 : 0.5), lineWidth: isCandidate ? 2 : 1)
        )
    }

    private func paneBadge(title: String, item: GalleryItem, tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption.weight(.semibold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(tint.opacity(0.85), in: Capsule())
            flagStarReadout(item: item)
        }
        .foregroundStyle(.white)
        .padding(8)
    }

    private func flagStarReadout(item: GalleryItem) -> some View {
        HStack(spacing: 6) {
            switch item.flag {
            case .pick: Image(systemName: "flag.fill").foregroundStyle(.green)
            case .reject: Image(systemName: "xmark").foregroundStyle(.red)
            case nil: EmptyView()
            }
            if item.rating > 0 {
                HStack(spacing: 1) {
                    ForEach(0 ..< item.rating, id: \.self) { _ in
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                    }
                }
            }
        }
        .font(.caption2)
    }

    // MARK: - Actions

    private func cycle(_ delta: Int) {
        zoom.reset()
        onCycleCandidate(delta)
    }

    private func toggleZoom() {
        if zoom.isZoomed {
            zoom.reset()
        } else {
            zoom.zoom(by: 2, toward: nil, in: fit)
        }
    }

    // MARK: - Image loading

    private func loadSelect() {
        selectImage = nil
        let url = selectItem.url
        Task.detached(priority: .userInitiated) {
            let img = NSImage(contentsOf: url)
            await MainActor.run { selectImage = img }
        }
    }

    private func loadCandidate() {
        candidateImage = nil
        let url = candidateItem.url
        Task.detached(priority: .userInitiated) {
            let img = NSImage(contentsOf: url)
            await MainActor.run { candidateImage = img }
        }
    }

    // MARK: - Event monitors

    /// Zoom is linked across both panes and centred, so the pointer only has to be
    /// somewhere over the view.
    private func installMonitors() {
        guard !monitors.isInstalled else { return }
        monitors.addKeys(host: hostWindow) { handleKey($0) }
        monitors.addZoom(host: hostWindow, over: { viewFrame }, onZoom: { factor, _ in
            zoom.zoom(by: factor, toward: nil, in: fit)
        })
    }

    /// Listed in `KeyboardShortcutCatalog.compareView`, at the end of this file.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        switch event.keyCode {
        case 53: onDismiss(); return nil // Escape
        case 123: if canCycle {
                cycle(-1)
            }; return nil // Left
        case 124: if canCycle {
                cycle(1)
            }; return nil // Right
        case 36, 76, 126: onSwap(); return nil // Return / Enter / Up → make select
        default: break
        }
        switch CullKey(event) {
        case let .flag(flag): onFlagCandidate(flag)
        case let .rating(stars): onRateCandidate(stars)
        case nil: return event
        }
        return nil
    }
}

extension KeyboardShortcutCatalog {
    static let compareView = Section("Compare View", [
        Entry("Show the previous or next candidate", ["←"], ["→"]),
        Entry("Make the candidate the select", ["↵"], ["⌤"], ["↑"]),
        Entry("Flag the candidate as pick", ["P"]),
        Entry("Reject the candidate", ["X"]),
        Entry("Remove the candidate's flag", ["U"]),
        Entry("Set the candidate's star rating", ["0–5"]),
        Entry("Close", ["⎋"]),
    ])
}
