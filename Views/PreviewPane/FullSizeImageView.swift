import SwiftUI

// MARK: - Full-size image overlay (shown in-place, no sheet window)

struct FullSizeImageView: View {
    private static let minScale: CGFloat = 1
    private static let maxScale: CGFloat = 12
    private static let imagePadding: CGFloat = 20

    let image: NSImage
    let onDismiss: () -> Void
    var hasPrev: Bool = false
    var hasNext: Bool = false
    var onNavigatePrev: (() -> Void)?
    var onNavigateNext: (() -> Void)?
    // Culling: current verdict for the shown image, plus callbacks to change it.
    // When these are nil the overlay is a plain viewer (e.g. showing an active job).
    var flag: PickFlag?
    var rating: Int = 0
    var onFlag: ((PickFlag?) -> Void)?
    var onRating: ((Int) -> Void)?

    @State private var keyMonitor: Any?
    @State private var scrollMonitor: Any?
    @State private var chromeVisible: Bool = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var panBase: CGSize?
    @State private var containerFrame: CGRect = .zero

    var body: some View {
        ZStack {
            Color.black

            GeometryReader { geo in
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(Self.imagePadding)
                    .scaleEffect(scale, anchor: .center)
                    .offset(offset)
                    .gesture(scale > Self.minScale ? panGesture : nil)
                    .onTapGesture(count: 2) {
                        if scale > Self.minScale {
                            resetZoom()
                        } else {
                            onDismiss()
                        }
                    }
                    .onAppear { containerFrame = geo.frame(in: .global) }
                    .onChange(of: geo.frame(in: .global)) { _, new in containerFrame = new }
            }

            // Close button — top-right, fades with chrome
            VStack {
                HStack {
                    Spacer()
                    Button { onDismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                }
                Spacer()
            }
            .opacity(chromeVisible ? 1 : 0)
            .animation(.easeOut(duration: 0.5), value: chromeVisible)

            // Navigation arrows — vertically centered, fade with chrome
            if hasPrev || hasNext {
                HStack(spacing: 0) {
                    if hasPrev {
                        Button {
                            showChrome()
                            resetZoom()
                            onNavigatePrev?()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(.white.opacity(0.18), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 20)
                    }
                    Spacer()
                    if hasNext {
                        Button {
                            showChrome()
                            resetZoom()
                            onNavigateNext?()
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(.white.opacity(0.18), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 20)
                    }
                }
                .frame(maxWidth: .infinity)
                .opacity(chromeVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.5), value: chromeVisible)
            }

            // Culling status pill — bottom-center, fades with chrome.
            if onFlag != nil || onRating != nil {
                VStack {
                    Spacer()
                    cullPill
                        .opacity(chromeVisible ? 1 : 0)
                        .animation(.easeOut(duration: 0.5), value: chromeVisible)
                        .padding(.bottom, 20)
                }
            }
        }
        .onContinuousHover { phase in
            if case .active = phase { showChrome() }
        }
        .onAppear {
            installKeyMonitor()
            installScrollMonitor()
            scheduleHide()
        }
        .onDisappear {
            removeKeyMonitor()
            removeScrollMonitor()
            hideTask?.cancel()
        }
    }

    // MARK: - Culling status pill

    private var cullPill: some View {
        HStack(spacing: 10) {
            switch flag {
            case .pick:
                Label("Pick", systemImage: "flag.fill").foregroundStyle(.green)
            case .reject:
                Label("Reject", systemImage: "xmark").foregroundStyle(.red)
            case nil:
                Label("Unflagged", systemImage: "flag").foregroundStyle(.white.opacity(0.7))
            }
            Divider().frame(height: 12).overlay(.white.opacity(0.3))
            HStack(spacing: 2) {
                ForEach(1 ... 5, id: \.self) { star in
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .foregroundStyle(star <= rating ? .yellow : .white.opacity(0.35))
                }
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.black.opacity(0.55), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
    }

    // MARK: - Zoom & pan

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if panBase == nil { panBase = offset }
                let base = panBase ?? .zero
                offset = clampedOffset(CGSize(
                    width: base.width + value.translation.width,
                    height: base.height + value.translation.height
                ))
                showChrome()
            }
            .onEnded { _ in
                panBase = nil
                offset = clampedOffset(offset)
            }
    }

    /// Zoom toward a cursor location (in `.global` SwiftUI coordinates) so the
    /// point under the pointer stays fixed.
    private func zoom(by factor: CGFloat, at cursor: CGPoint) {
        guard containerFrame.width > 0, containerFrame.height > 0 else { return }
        let newScale = min(max(scale * factor, Self.minScale), Self.maxScale)
        guard newScale != scale else { return }
        let applied = newScale / scale

        // Cursor relative to the container centre (the scaleEffect anchor).
        let center = CGPoint(x: containerFrame.midX, y: containerFrame.midY)
        let vx = cursor.x - center.x
        let vy = cursor.y - center.y

        scale = newScale
        if newScale <= Self.minScale {
            offset = .zero
        } else {
            offset = clampedOffset(CGSize(
                width: vx - applied * (vx - offset.width),
                height: vy - applied * (vy - offset.height)
            ))
        }
    }

    private func resetZoom() {
        scale = Self.minScale
        offset = .zero
        panBase = nil
    }

    /// Clamp the pan offset so the scaled image can't be dragged past the
    /// container edges (no black gutters once zoomed past fit).
    private func clampedOffset(_ proposed: CGSize) -> CGSize {
        let availW = max(0, containerFrame.width - 2 * Self.imagePadding)
        let availH = max(0, containerFrame.height - 2 * Self.imagePadding)
        let imgW = image.size.width
        let imgH = image.size.height
        guard imgW > 0, imgH > 0, availW > 0, availH > 0 else { return .zero }

        let fit = min(availW / imgW, availH / imgH)
        let dispW = imgW * fit * scale
        let dispH = imgH * fit * scale

        let maxX = max(0, (dispW - containerFrame.width) / 2)
        let maxY = max(0, (dispH - containerFrame.height) / 2)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }

    // MARK: - Chrome

    private func showChrome() {
        chromeVisible = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(2.5))
                chromeVisible = false
            } catch {
                // Cancelled — leave chrome visible
            }
        }
    }

    // MARK: - Event monitors

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKey(event)
        }
    }

    /// Handles keys while the overlay is up. Arrow keys drive *linear* prev/next
    /// through the gallery (not the grid's row-aware 2D navigation), so the right
    /// arrow advances past a row's edge to the next image. Culling keys mirror the
    /// grid: p/x/u flag, 0–5 rate, with pick/reject auto-advancing to the next image.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == 53 { // Escape
            onDismiss()
            return nil // consume — prevents system from exiting tiled/zoomed window state
        }
        switch event.keyCode {
        case 123: // Left
            navigate(prev: true); return nil
        case 124: // Right
            navigate(prev: false); return nil
        default:
            break
        }
        // Culling keys — only when this overlay owns a gallery item (callbacks set).
        guard onFlag != nil || onRating != nil,
              !event.modifierFlags.contains(.command),
              let chars = event.charactersIgnoringModifiers, chars.count == 1 else { return event }
        switch chars {
        case "p", "P":
            onFlag?(.pick); showChrome(); advanceIfPossible(); return nil
        case "x", "X":
            onFlag?(.reject); showChrome(); advanceIfPossible(); return nil
        case "u", "U":
            onFlag?(nil); showChrome(); return nil
        case "0", "1", "2", "3", "4", "5":
            onRating?(Int(chars) ?? 0); showChrome(); return nil
        default:
            return event
        }
    }

    private func navigate(prev: Bool) {
        guard prev ? hasPrev : hasNext else { return }
        showChrome()
        resetZoom()
        if prev { onNavigatePrev?() } else { onNavigateNext?() }
    }

    /// Auto-advance after a pick/reject, matching Lightroom's cull rhythm.
    private func advanceIfPossible() {
        guard hasNext else { return }
        resetZoom()
        onNavigateNext?()
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
            guard let cursor = cursorInGlobalSpace(for: event) else { return event }
            let factor: CGFloat
            if event.type == .magnify {
                factor = 1 + event.magnification
            } else {
                // Trackpad two-finger / mouse-wheel scroll → exponential zoom.
                let delta = event.hasPreciseScrollingDeltas
                    ? event.scrollingDeltaY
                    : event.scrollingDeltaY * 3
                guard delta != 0 else { return event }
                factor = exp(delta * 0.005)
            }
            showChrome()
            zoom(by: factor, at: cursor)
            return nil // consume so underlying scroll views don't also react
        }
    }

    private func removeScrollMonitor() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }

    /// Convert an event's window-space location (AppKit, bottom-left origin) to
    /// SwiftUI `.global` space (top-left origin) so it lines up with
    /// `containerFrame`. Returns nil when the pointer is outside the image area.
    private func cursorInGlobalSpace(for event: NSEvent) -> CGPoint? {
        guard let contentView = (event.window ?? NSApp.keyWindow)?.contentView else { return nil }
        let loc = event.locationInWindow
        let point = CGPoint(x: loc.x, y: contentView.bounds.height - loc.y)
        guard containerFrame.contains(point) else { return nil }
        return point
    }
}
