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
    private static let minScale: CGFloat = 1
    private static let maxScale: CGFloat = 12
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
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var panBase: CGSize?
    @State private var selectFrame: CGRect = .zero
    @State private var keyMonitor: Any?
    @State private var scrollMonitor: Any?

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
        .onAppear {
            loadSelect()
            loadCandidate()
            installKeyMonitor()
            installScrollMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
            removeScrollMonitor()
        }
        .onChange(of: selectItem.id) { _, _ in loadSelect(); resetZoom() }
        .onChange(of: candidateItem.id) { _, _ in loadCandidate(); resetZoom() }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { onDismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3).symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)

            Text("Compare").font(.headline).foregroundStyle(.white)

            Spacer()

            Button { onSwap() } label: {
                Label("Make Select", systemImage: "arrow.left.arrow.right")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.white.opacity(0.14), in: Capsule())
            .help("Promote the candidate to the select (⏎)")

            if canCycle {
                HStack(spacing: 8) {
                    Button { cycle(-1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.plain).foregroundStyle(.white)
                    Text("\(candidatePosition) / \(candidateCount)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                    Button { cycle(1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.plain).foregroundStyle(.white)
                }
            }

            if scale > Self.minScale {
                Button { resetZoom() } label: {
                    Label("Fit", systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.callout)
                }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    private var hintBar: some View {
        Text("←/→ cycle candidate · ⏎ make select · P pick · X reject · 0–5 rate candidate · scroll to zoom · Esc close")
            .font(.caption2).foregroundStyle(.white.opacity(0.5))
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if panBase == nil { panBase = offset }
                let base = panBase ?? .zero
                offset = clampedOffset(CGSize(
                    width: base.width + value.translation.width,
                    height: base.height + value.translation.height
                ))
            }
            .onEnded { _ in
                panBase = nil
                offset = clampedOffset(offset)
            }
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
                            .resizable().aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(Self.imagePadding)
                            .scaleEffect(scale, anchor: .center)
                            .offset(offset)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .onAppear { if !isCandidate { selectFrame = geo.frame(in: .global) } }
                .onChange(of: geo.frame(in: .global)) { _, new in
                    if !isCandidate { selectFrame = new }
                }
            }
            .gesture(scale > Self.minScale ? panGesture : nil)
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
        resetZoom()
        onCycleCandidate(delta)
    }

    private func toggleZoom() {
        if scale > Self.minScale { resetZoom() } else { scale = 2 }
    }

    private func resetZoom() {
        scale = Self.minScale
        offset = .zero
        panBase = nil
    }

    // MARK: - Zoom & pan (linked across both panes)

    private func zoom(by factor: CGFloat) {
        let newScale = min(max(scale * factor, Self.minScale), Self.maxScale)
        guard newScale != scale else { return }
        scale = newScale
        offset = newScale <= Self.minScale ? .zero : clampedOffset(offset)
    }

    /// Clamp the pan so the scaled image can't be dragged past the pane edges. Uses the
    /// Select pane's geometry as the reference; both panes share the offset, so identical
    /// aspect ratios (the common A/B case) stay perfectly aligned.
    private func clampedOffset(_ proposed: CGSize) -> CGSize {
        guard let image = selectImage,
              selectFrame.width > 0, selectFrame.height > 0 else { return .zero }
        let availW = max(0, selectFrame.width - 2 * Self.imagePadding)
        let availH = max(0, selectFrame.height - 2 * Self.imagePadding)
        let imgW = image.size.width, imgH = image.size.height
        guard imgW > 0, imgH > 0, availW > 0, availH > 0 else { return .zero }

        let fit = min(availW / imgW, availH / imgH)
        let dispW = imgW * fit * scale
        let dispH = imgH * fit * scale
        let maxX = max(0, (dispW - selectFrame.width) / 2)
        let maxY = max(0, (dispH - selectFrame.height) / 2)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
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

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKey(event)
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        switch event.keyCode {
        case 53: onDismiss(); return nil // Escape
        case 123: if canCycle { cycle(-1) }; return nil // Left
        case 124: if canCycle { cycle(1) }; return nil // Right
        case 36, 76, 126: onSwap(); return nil // Return / Enter / Up → make select
        default: break
        }
        guard !event.modifierFlags.contains(.command),
              let chars = event.charactersIgnoringModifiers, chars.count == 1 else { return event }
        switch chars {
        case "p", "P": onFlagCandidate(.pick); return nil
        case "x", "X": onFlagCandidate(.reject); return nil
        case "u", "U": onFlagCandidate(nil); return nil
        case "0", "1", "2", "3", "4", "5": onRateCandidate(Int(chars) ?? 0); return nil
        default: return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { event in
            let factor: CGFloat
            if event.type == .magnify {
                factor = 1 + event.magnification
            } else {
                let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 3
                guard delta != 0 else { return event }
                factor = exp(delta * 0.005)
            }
            zoom(by: factor)
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }
}
