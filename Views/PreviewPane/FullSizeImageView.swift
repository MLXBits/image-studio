import SwiftUI

// MARK: - Full-size image overlay (shown in-place, no sheet window)

struct FullSizeImageView: View {
    private static let imagePadding: CGFloat = 20
    /// Fullscreen media chrome, deliberately larger than `IconButtonMetrics.size`: the
    /// arrows float over the image with nothing adjacent to crowd them, and this is the
    /// one control in the app that was already above the standard. The standard is a
    /// floor, not a cap — do not copy this value into panel or row buttons.
    private static let navButtonSize: CGFloat = 44

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

    @State private var monitors = EventMonitors()
    @State private var hostWindow = WindowRef()
    @State private var chromeVisible: Bool = true
    @State private var hideTask: Task<Void, Never>?
    @State private var zoom = ImageZoomState()
    @State private var containerFrame: CGRect = .zero

    var body: some View {
        ZStack {
            Color.black

            GeometryReader { geo in
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(Self.imagePadding)
                    .scaleEffect(zoom.scale, anchor: .center)
                    .offset(zoom.offset)
                    .gesture(zoom.isZoomed ? panGesture : nil)
                    .onTapGesture(count: 2) {
                        if zoom.isZoomed {
                            zoom.reset()
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
                    .buttonStyle(.iconButton)
                    .accessibilityLabel("Close")
                    // Insets the button from the corner — the hit area is the style's
                    // 28pt frame, not this padding.
                    .padding(8)
                }
                Spacer()
            }
            .opacity(chromeVisible ? 1 : 0)
            .animation(.easeOut(duration: 0.5), value: chromeVisible)

            // Navigation arrows — vertically centered, fade with chrome
            if hasPrev || hasNext {
                HStack(spacing: 0) {
                    if hasPrev {
                        navButton("chevron.left", label: "Previous image", prev: true)
                            .padding(.leading, 20)
                    }
                    Spacer()
                    if hasNext {
                        navButton("chevron.right", label: "Next image", prev: false)
                            .padding(.trailing, 20)
                    }
                }
                .frame(maxWidth: .infinity)
                .opacity(chromeVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.5), value: chromeVisible)
            }

            // Culling status pill + key hint — bottom-center, fades with chrome.
            if onFlag != nil || onRating != nil {
                VStack(spacing: 6) {
                    Spacer()
                    cullPill
                    Text("P pick · X reject · U unflag · 0–5 rate · ←/→ navigate")
                        .font(.caption2).foregroundStyle(.white.opacity(0.55))
                }
                .opacity(chromeVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.5), value: chromeVisible)
                .padding(.bottom, 20)
            }
        }
        // The viewer owns the whole screen, including the strip the toolbar and
        // top control bar sit in — without this the overlay stops at the safe
        // area and leaves that chrome showing above the image.
        .ignoresSafeArea()
        .onContinuousHover { phase in
            if case .active = phase {
                showChrome()
            }
        }
        .background { WindowAccessor { hostWindow.window = $0 } }
        .onAppear {
            installMonitors()
            scheduleHide()
        }
        .onDisappear {
            monitors.removeAll()
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

    private var fit: ImageZoomState.Fit {
        ImageZoomState.Fit(images: [image.size], frame: containerFrame, padding: Self.imagePadding)
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                zoom.pan(by: value.translation, in: fit)
                showChrome()
            }
            .onEnded { _ in zoom.endPan(in: fit) }
    }

    /// A prev/next arrow. Fullscreen media chrome at `navButtonSize`, not the 28pt standard.
    private func navButton(_ systemImage: String, label: String, prev: Bool) -> some View {
        Button { navigate(prev: prev) } label: {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: Self.navButtonSize, height: Self.navButtonSize)
                .background(.white.opacity(0.18), in: Circle())
        }
        .buttonStyle(IconButtonStyle(side: Self.navButtonSize))
        .accessibilityLabel(label)
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

    private func installMonitors() {
        guard !monitors.isInstalled else { return }
        monitors.addKeys(host: hostWindow) { handleKey($0) }
        monitors.addZoom(host: hostWindow, over: { containerFrame }, onZoom: { factor, pointer in
            showChrome()
            zoom.zoom(by: factor, toward: pointer, in: fit)
        })
    }

    /// Handles keys while the overlay is up. Arrow keys drive *linear* prev/next
    /// through the gallery (not the grid's row-aware 2D navigation), so the right
    /// arrow advances past a row's edge to the next image. Culling keys mirror the
    /// grid: p/x/u flag, 0–5 rate, with pick/reject auto-advancing to the next image.
    /// Listed in `KeyboardShortcutCatalog.fullSizeView`, at the end of this file.
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
        guard onFlag != nil || onRating != nil, let key = CullKey(event) else { return event }
        showChrome()
        switch key {
        case let .flag(flag):
            onFlag?(flag)
            if flag != nil {
                advanceIfPossible()
            }
        case let .rating(stars):
            onRating?(stars)
        }
        return nil
    }

    private func navigate(prev: Bool) {
        // Don't gate on hasPrev/hasNext here: this runs inside the key monitor's closure,
        // which captured the view as it was when fullscreen opened, so those booleans are
        // frozen at their open-time values and go stale as the selection moves. The
        // parent's navigateGallery clamps at both ends (a no-op at the edge), so an
        // unconditional call is safe. (The on-screen arrow buttons still use live values.)
        showChrome()
        zoom.reset()
        if prev {
            onNavigatePrev?()
        } else {
            onNavigateNext?()
        }
    }

    /// Auto-advance after a pick/reject, matching Lightroom's cull rhythm.
    private func advanceIfPossible() {
        // See navigate(prev:) — rely on the bounds-safe parent instead of the stale hasNext.
        zoom.reset()
        onNavigateNext?()
    }
}

extension KeyboardShortcutCatalog {
    static let fullSizeView = Section("Full-Size View", [
        Entry("Previous image", ["←"]),
        Entry("Next image", ["→"]),
        Entry("Flag as pick, then show the next image", ["P"]),
        Entry("Reject, then show the next image", ["X"]),
        Entry("Remove the flag", ["U"]),
        Entry("Set the star rating", ["0–5"]),
        Entry("Close", ["⎋"]),
    ])
}
