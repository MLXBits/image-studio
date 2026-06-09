// swiftlint:disable file_length type_body_length function_body_length
import AppKit
import SwiftUI

// MARK: - Closure-based NSMenuItem helper

private final class MenuAction: NSObject {
    private let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func run() { block() }
}

private func menuItem(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
    let wrapper = MenuAction(action)
    let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
    item.target = wrapper
    item.representedObject = wrapper   // keeps wrapper alive while menu lives
    return item
}

// MARK: - Cell SwiftUI content

private struct ThumbnailCellView: View, Equatable {
    let item: GalleryItem
    let isSelected: Bool
    let isInMultiSelection: Bool
    let hasAnySelection: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item.id == rhs.item.id &&
        (lhs.item.thumbnailImage == nil) == (rhs.item.thumbnailImage == nil) &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isInMultiSelection == rhs.isInMultiSelection &&
        lhs.hasAnySelection == rhs.hasAnySelection
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let img = item.thumbnailImage {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).clipped()
                } else {
                    Color.secondary.opacity(0.15)
                        .overlay { Image(systemName: "photo").font(.title2).foregroundStyle(.tertiary) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if item.metadata != nil {
                LinearGradient(colors: [.clear, .black.opacity(0.4)], startPoint: .center, endPoint: .bottom)
                    .frame(height: 36)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            Color.black.opacity((hasAnySelection && !isSelected && !isInMultiSelection) ? 0.45 : 0)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .allowsHitTesting(false)
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor).blur(radius: 8)
                .opacity(isSelected ? 0.7 : 0).padding(-3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected || isInMultiSelection ? Color.accentColor : Color.clear, lineWidth: 3)
        )
        .overlay(alignment: .topLeading) {
            if isInMultiSelection {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .font(.body).padding(4)
            }
        }
    }
}

// MARK: - NSCollectionViewItem (cell)

private final class GalleryCell: NSCollectionViewItem {
    static let reuseID = NSUserInterfaceItemIdentifier("GalleryCell")
    private var hosting: NSHostingView<ThumbnailCellView>?

    override func loadView() { view = NSView() }

    func configure(item: GalleryItem, selected: Bool, multiSelected: Bool, hasAny: Bool) {
        let content = ThumbnailCellView(item: item, isSelected: selected,
                                        isInMultiSelection: multiSelected, hasAnySelection: hasAny)
        if let h = hosting {
            h.rootView = content
        } else {
            let h = NSHostingView(rootView: content)
            h.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(h)
            NSLayoutConstraint.activate([
                h.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                h.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                h.topAnchor.constraint(equalTo: view.topAnchor),
                h.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            hosting = h
        }
    }
}

// MARK: - Section header SwiftUI content

private struct SectionHeaderContent: View {
    let name: String
    let count: Int
    let isExpanded: Bool
    let isDropTarget: Bool
    var onToggle: () -> Void
    var onRename: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isDropTarget ? "folder.fill" : "folder")
                .font(.caption2)
                .foregroundStyle(isDropTarget ? Color.accentColor : .secondary)
            Text(name)
                .font(.caption).fontWeight(.medium)
                .foregroundStyle(isDropTarget ? Color.accentColor : .primary)
            Spacer()
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption2).foregroundStyle(.tertiary)
            Text("\(count)")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.secondary.opacity(0.12), in: Capsule())
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isDropTarget ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .contextMenu {
            if let fn = onRename {
                Button("Rename Folder…") { fn() }
            }
        }
    }
}

// MARK: - Section header NSView

final class GallerySectionHeader: NSView, NSCollectionViewElement {
    static let reuseID = NSUserInterfaceItemIdentifier("GallerySectionHeader")
    private var hosting: NSHostingView<SectionHeaderContent>?
    /// Board name stored so drag hit-testing can identify this header without
    /// relying on supplementaryView(forElementKind:at:), which returns nil for
    /// collapsed (0-item) sections.
    private(set) var boardName: String?

    func configure(name: String, count: Int, isExpanded: Bool, isDropTarget: Bool,
                   onToggle: @escaping () -> Void, onRename: (() -> Void)?) {
        boardName = name
        let content = SectionHeaderContent(name: name, count: count, isExpanded: isExpanded,
                                           isDropTarget: isDropTarget, onToggle: onToggle, onRename: onRename)
        if let h = hosting {
            h.rootView = content
        } else {
            let h = NSHostingView(rootView: content)
            h.translatesAutoresizingMaskIntoConstraints = false
            addSubview(h)
            NSLayoutConstraint.activate([
                h.leadingAnchor.constraint(equalTo: leadingAnchor),
                h.trailingAnchor.constraint(equalTo: trailingAnchor),
                h.topAnchor.constraint(equalTo: topAnchor),
                h.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            hosting = h
        }
    }
}

// MARK: - GalleryNSCollectionView subclass

final class GalleryNSCollectionView: NSCollectionView {
    weak var eventDelegate: GalleryCollectionViewEvents?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 124, 125, 126:   // Arrow keys — NSCollectionView handles 2D navigation
            super.keyDown(with: event)
            // Sync the newly focused item back to SwiftUI
            if let path = selectionIndexPaths.first {
                eventDelegate?.didNavigate(to: path)
            }

        case 51, 117:              // Delete / Forward Delete
            eventDelegate?.deleteKeyPressed(shift: event.modifierFlags.contains(.shift))

        case 53:                   // Escape
            eventDelegate?.escapeKeyPressed()

        default:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard let path = indexPathForItem(at: pt) else {
            super.mouseDown(with: event)
            return
        }
        let flags = event.modifierFlags
        if flags.contains(.command) {
            eventDelegate?.commandClick(at: path)
            super.mouseDown(with: event)
        } else if flags.contains(.shift) {
            eventDelegate?.shiftClick(at: path)
            super.mouseDown(with: event)
        } else {
            super.mouseDown(with: event)          // sets NSCollectionView focus/selection
            eventDelegate?.singleClick(at: path)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if let path = indexPathForItem(at: pt) {
            eventDelegate?.rightClick(at: path, event: event)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    // NSCollectionViewDelegate's validateDrop/acceptDrop are only called when the cursor is
    // over an ITEM area — they miss section headers entirely. Overriding these NSView-level
    // methods guarantees we see every cursor position including collapsed section headers.

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        eventDelegate?.dragUpdated(sender, in: self)
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        eventDelegate?.dragUpdated(sender, in: self)
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        eventDelegate?.dragExited(in: self)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        eventDelegate?.dropPerformed(sender, in: self) ?? false
    }
}

// MARK: - Event protocol

protocol GalleryCollectionViewEvents: AnyObject {
    func singleClick(at path: IndexPath)
    func commandClick(at path: IndexPath)
    func shiftClick(at path: IndexPath)
    func didNavigate(to path: IndexPath)
    func rightClick(at path: IndexPath, event: NSEvent)
    func deleteKeyPressed(shift: Bool)
    func escapeKeyPressed()
    // Drag destination — view-level so they fire over headers, not only over items
    func dragUpdated(_ info: NSDraggingInfo, in cv: GalleryNSCollectionView)
    func dropPerformed(_ info: NSDraggingInfo, in cv: GalleryNSCollectionView) -> Bool
    func dragExited(in cv: GalleryNSCollectionView)
}

// MARK: - NSViewRepresentable

struct GalleryCollectionView: NSViewRepresentable {
    // Data
    var sections: [GallerySection]
    var selectedItemId: UUID?
    var multiSelectionIds: Set<UUID>
    var anchorItemId: UUID?
    // Callbacks
    var onSelect: (GalleryItem) -> Void
    var onMultiToggle: (GalleryItem) -> Void
    var onRangeSelect: (GalleryItem) -> Void
    var onItemAppear: (GalleryItem) -> Void
    var onDeleteRequest: (GalleryItem) -> Void
    var onDeleteImmediate: (GalleryItem) -> Void
    var onDeleteMultiRequest: () -> Void
    var onDeleteMultiImmediate: () -> Void
    var onRemix: (GenerationMetadata) -> Void
    var onApplySettings: (GalleryItem, GenerationMetadata) -> Void
    var onUseInImg2Img: (String) -> Void
    var onMoveToBoard: (GalleryItem, String) -> Void
    var onRevealInFinder: (String) -> Void
    var onToggleSection: (String) -> Void
    var onRenameBoard: (String) -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let cv = GalleryNSCollectionView()
        cv.eventDelegate = context.coordinator

        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 4
        layout.sectionInset = NSEdgeInsets(top: 0, left: 8, bottom: 8, right: 8)
        layout.headerReferenceSize = NSSize(width: 0, height: 30)
        cv.collectionViewLayout = layout

        cv.dataSource = context.coordinator
        cv.delegate = context.coordinator
        cv.isSelectable = true
        cv.allowsMultipleSelection = false
        cv.backgroundColors = [.clear]
        cv.register(GalleryCell.self, forItemWithIdentifier: GalleryCell.reuseID)
        cv.register(GallerySectionHeader.self,
                    forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                    withIdentifier: GallerySectionHeader.reuseID)
        cv.registerForDraggedTypes([.string])
        cv.setDraggingSourceOperationMask(.move, forLocal: true)
        cv.setDraggingSourceOperationMask(.copy, forLocal: false)

        context.coordinator.collectionView = cv
        context.coordinator.parent = self

        let scrollView = NSScrollView()
        scrollView.documentView = cv
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coord = context.coordinator
        guard let cv = scrollView.documentView as? GalleryNSCollectionView else { return }
        coord.parent = self

        let oldSectionIds = coord.sections.map { ($0.board, $0.items.map(\.id), $0.isExpanded) }
        let newSectionIds = sections.map { ($0.board, $0.items.map(\.id), $0.isExpanded) }
        let structureChanged = !zip(oldSectionIds, newSectionIds).allSatisfy {
            $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2
        } || oldSectionIds.count != newSectionIds.count

        coord.sections = sections

        if structureChanged {
            // Snapshot first-responder state BEFORE reloadData, which can clear selection
            // and may resign the collection view as first-responder.
            let cvHadFocus = isGalleryInResponderChain(scrollView: scrollView, window: cv.window)

            cv.reloadData()

            // Restore selection + focus so arrow-key navigation continues without a click.
            if let selId = selectedItemId {
                for (si, sec) in sections.enumerated() {
                    if let ii = sec.visibleItems.firstIndex(where: { $0.id == selId }) {
                        cv.selectItems(at: [IndexPath(item: ii, section: si)], scrollPosition: [])
                        if cvHadFocus { cv.window?.makeFirstResponder(cv) }
                        break
                    }
                }
            }
        } else {
            // Refresh visible cells — thumbnail may have loaded or selection changed
            let hasAny = selectedItemId != nil || !multiSelectionIds.isEmpty
            for path in cv.indexPathsForVisibleItems() {
                guard path.section < sections.count,
                      path.item < sections[path.section].visibleItems.count else { continue }
                let item = sections[path.section].visibleItems[path.item]
                (cv.item(at: path) as? GalleryCell)?.configure(
                    item: item,
                    selected: item.id == selectedItemId,
                    multiSelected: multiSelectionIds.contains(item.id),
                    hasAny: hasAny
                )
            }
        }

        // Refresh visible section headers
        for sectionIdx in 0..<sections.count {
            let path = IndexPath(item: 0, section: sectionIdx)
            if let header = cv.supplementaryView(
                forElementKind: NSCollectionView.elementKindSectionHeader, at: path
            ) as? GallerySectionHeader {
                let sec = sections[sectionIdx]
                header.configure(
                    name: sec.board, count: sec.items.count,
                    isExpanded: sec.isExpanded, isDropTarget: coord.dropTargetBoard == sec.board,
                    onToggle: { coord.parent.onToggleSection(sec.board) },
                    onRename: sec.board == "Default" ? nil : { coord.parent.onRenameBoard(sec.board) }
                )
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout,
                              GalleryCollectionViewEvents {
        var parent: GalleryCollectionView
        var sections: [GallerySection] = []
        var dropTargetBoard: String?
        weak var collectionView: GalleryNSCollectionView?

        init(_ parent: GalleryCollectionView) { self.parent = parent }

        // MARK: Data source

        func numberOfSections(in cv: NSCollectionView) -> Int { sections.count }

        func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            sections[section].visibleItems.count
        }

        func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt path: IndexPath) -> NSCollectionViewItem {
            // swiftlint:disable:next force_cast
            let cell = cv.makeItem(withIdentifier: GalleryCell.reuseID, for: path) as! GalleryCell
            let item = sections[path.section].visibleItems[path.item]
            let hasAny = parent.selectedItemId != nil || !parent.multiSelectionIds.isEmpty
            cell.configure(item: item,
                           selected: item.id == parent.selectedItemId,
                           multiSelected: parent.multiSelectionIds.contains(item.id),
                           hasAny: hasAny)
            parent.onItemAppear(item)
            return cell
        }

        func collectionView(_ cv: NSCollectionView,
                            viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                            at path: IndexPath) -> NSView {
            guard kind == NSCollectionView.elementKindSectionHeader else { return NSView() }
            let anyView = cv.makeSupplementaryView(ofKind: kind,
                                                   withIdentifier: GallerySectionHeader.reuseID,
                                                   for: path)
            // swiftlint:disable:next force_cast
            let header = anyView as! GallerySectionHeader
            let sec = sections[path.section]
            header.configure(
                name: sec.board, count: sec.items.count,
                isExpanded: sec.isExpanded, isDropTarget: dropTargetBoard == sec.board,
                onToggle: { [weak self] in self?.parent.onToggleSection(sec.board) },
                onRename: sec.board == "Default" ? nil : { [weak self] in self?.parent.onRenameBoard(sec.board) }
            )
            return header
        }

        // MARK: Layout delegate

        func collectionView(_ cv: NSCollectionView, layout: NSCollectionViewLayout,
                            sizeForItemAt path: IndexPath) -> NSSize {
            let inset = 8.0, spacing = 4.0, minCell = 80.0
            let available = max(0, cv.bounds.width - inset * 2)
            let numCols = max(1, floor((available + spacing) / (minCell + spacing)))
            let cellW = floor((available - (numCols - 1) * spacing) / numCols)
            return NSSize(width: cellW, height: cellW)
        }

        // MARK: GalleryCollectionViewEvents

        func singleClick(at path: IndexPath) {
            guard path.section < sections.count,
                  path.item < sections[path.section].visibleItems.count else { return }
            parent.onSelect(sections[path.section].visibleItems[path.item])
        }

        func commandClick(at path: IndexPath) {
            guard path.section < sections.count,
                  path.item < sections[path.section].visibleItems.count else { return }
            parent.onMultiToggle(sections[path.section].visibleItems[path.item])
        }

        func shiftClick(at path: IndexPath) {
            guard path.section < sections.count,
                  path.item < sections[path.section].visibleItems.count else { return }
            parent.onRangeSelect(sections[path.section].visibleItems[path.item])
        }

        func didNavigate(to path: IndexPath) {
            guard path.section < sections.count,
                  path.item < sections[path.section].visibleItems.count else { return }
            parent.onSelect(sections[path.section].visibleItems[path.item])
        }

        func deleteKeyPressed(shift: Bool) {
            if !parent.multiSelectionIds.isEmpty {
                if shift { parent.onDeleteMultiImmediate() } else { parent.onDeleteMultiRequest() }
                return
            }
            guard let selId = parent.selectedItemId,
                  let item = sections.flatMap(\.visibleItems).first(where: { $0.id == selId }) else { return }
            if shift { parent.onDeleteImmediate(item) } else { parent.onDeleteRequest(item) }
        }

        func escapeKeyPressed() { parent.onEscape() }

        func rightClick(at path: IndexPath, event: NSEvent) {
            guard path.section < sections.count,
                  path.item < sections[path.section].visibleItems.count else { return }
            let item = sections[path.section].visibleItems[path.item]
            let menu = buildMenu(for: item)
            guard let cv = collectionView else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: cv)
        }

        // MARK: Drag source

        func collectionView(_ cv: NSCollectionView,
                            pasteboardWriterForItemAt path: IndexPath) -> (any NSPasteboardWriting)? {
            guard path.section < sections.count,
                  path.item < sections[path.section].visibleItems.count else { return nil }
            let item = sections[path.section].visibleItems[path.item]
            let payload: String
            if parent.multiSelectionIds.contains(item.id), !parent.multiSelectionIds.isEmpty {
                let all = sections.flatMap(\.visibleItems).filter { parent.multiSelectionIds.contains($0.id) }
                payload = all.map(\.path).joined(separator: "\n")
            } else {
                payload = item.path
            }
            let pb = NSPasteboardItem()
            pb.setString(payload, forType: .string)
            return pb
        }

        // MARK: Drop destination — handled at NSView level (see GalleryNSCollectionView overrides)
        // validateDrop / acceptDrop are NOT used; the view overrides fire for all cursor
        // positions including section headers, which the delegate-based API misses.

        func dragUpdated(_ info: NSDraggingInfo, in cv: GalleryNSCollectionView) {
            let section = sectionAt(draggingInfo: info, cv: cv)
            let newBoard = section.map { sections[$0].board }
            guard newBoard != dropTargetBoard else { return }
            let old = dropTargetBoard
            dropTargetBoard = newBoard
            refreshDragHighlight(oldBoard: old, newBoard: newBoard, in: cv)
        }

        func dropPerformed(_ info: NSDraggingInfo, in cv: GalleryNSCollectionView) -> Bool {
            let old = dropTargetBoard
            dropTargetBoard = nil
            refreshDragHighlight(oldBoard: old, newBoard: nil, in: cv)
            guard let si = sectionAt(draggingInfo: info, cv: cv), si < sections.count,
                  let payload = info.draggingPasteboard.string(forType: .string) else { return false }
            let board = sections[si].board
            var moved = false
            for itemPath in payload.components(separatedBy: "\n") {
                if let item = sections.flatMap(\.visibleItems).first(where: { $0.path == itemPath }),
                   item.board != board {
                    parent.onMoveToBoard(item, board)
                    moved = true
                }
            }
            return moved
        }

        func dragExited(in cv: GalleryNSCollectionView) {
            guard dropTargetBoard != nil else { return }
            let old = dropTargetBoard
            dropTargetBoard = nil
            if let old { refreshDragHighlight(oldBoard: old, newBoard: nil, in: cv) }
        }

        private func sectionAt(draggingInfo: NSDraggingInfo, cv: NSCollectionView) -> Int? {
            // Use layout attributes for detection — this works for both open and collapsed
            // sections because the layout always calculates every header's frame regardless of
            // whether a view has been instantiated.  supplementaryView(forElementKind:at:) only
            // returns on-screen views (nil for collapsed 0-item sections) so we avoid it here.
            let loc = cv.convert(draggingInfo.draggingLocation, from: nil)
            guard let layout = cv.collectionViewLayout as? NSCollectionViewFlowLayout else { return nil }

            for si in 0..<sections.count {
                let path = IndexPath(item: 0, section: si)
                if let hAttrs = layout.layoutAttributesForSupplementaryView(
                    ofKind: NSCollectionView.elementKindSectionHeader, at: path
                ), hAttrs.frame.contains(loc) {
                    return si
                }
            }

            // Fallback: cursor is over an item in an open section.
            let band = CGRect(x: 0, y: loc.y - 15, width: max(cv.bounds.width, 1), height: 30)
            let attrs = layout.layoutAttributesForElements(in: band)
            for attr in attrs where attr.representedElementCategory == .item {
                if let sec = attr.indexPath?.section, sec < sections.count { return sec }
            }
            return nil
        }

        func collectionView(_ cv: NSCollectionView,
                            draggingSession session: NSDraggingSession,
                            endedAt screenPoint: NSPoint,
                            dragOperation: NSDragOperation) {
            guard dropTargetBoard != nil else { return }
            let old = dropTargetBoard
            dropTargetBoard = nil
            refreshDragHighlight(oldBoard: old, newBoard: nil, in: cv)
        }

        private func refreshDragHighlight(oldBoard: String?, newBoard: String?, in cv: NSCollectionView) {
            let toRefresh = Set([oldBoard, newBoard].compactMap { $0 })
            // Try supplementaryView first (works for open, visible sections).
            // For collapsed sections supplementaryView returns nil, so also walk the
            // scroll view's full subview tree which covers views NSCollectionView may place
            // outside cv.subviews (e.g. in the clip view for sticky/floating headers).
            var found = Set<String>()
            for si in 0..<sections.count {
                let sec = sections[si]
                guard toRefresh.contains(sec.board) else { continue }
                let path = IndexPath(item: 0, section: si)
                if let header = cv.supplementaryView(
                    forElementKind: NSCollectionView.elementKindSectionHeader, at: path
                ) as? GallerySectionHeader {
                    header.configure(
                        name: sec.board, count: sec.items.count,
                        isExpanded: sec.isExpanded,
                        isDropTarget: sec.board == newBoard,
                        onToggle: { [weak self] in self?.parent.onToggleSection(sec.board) },
                        onRename: sec.board == "Default" ? nil
                            : { [weak self] in self?.parent.onRenameBoard(sec.board) }
                    )
                    found.insert(sec.board)
                }
            }
            // For any board not yet updated, search the scroll view's subview tree.
            let remaining = toRefresh.subtracting(found)
            guard !remaining.isEmpty,
                  let root = cv.enclosingScrollView else { return }
            for header in viewTreeHeaders(in: root) {
                guard let name = header.boardName, remaining.contains(name),
                      let sec = sections.first(where: { $0.board == name }) else { continue }
                header.configure(
                    name: sec.board, count: sec.items.count,
                    isExpanded: sec.isExpanded,
                    isDropTarget: sec.board == newBoard,
                    onToggle: { [weak self] in self?.parent.onToggleSection(sec.board) },
                    onRename: sec.board == "Default" ? nil
                        : { [weak self] in self?.parent.onRenameBoard(sec.board) }
                )
            }
        }

        private func viewTreeHeaders(in view: NSView) -> [GallerySectionHeader] {
            var result: [GallerySectionHeader] = []
            for sub in view.subviews {
                if let h = sub as? GallerySectionHeader {
                    result.append(h)
                } else {
                    result.append(contentsOf: viewTreeHeaders(in: sub))
                }
            }
            return result
        }

        // MARK: Context menu builder

        private func buildMenu(for item: GalleryItem) -> NSMenu {
            let menu = NSMenu()

            menu.addItem(menuItem("Copy Image") { [weak self] in
                guard let img = NSImage(contentsOfFile: item.path) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([img])
                _ = self // suppress capture warning
            })

            if let meta = item.metadata {
                menu.addItem(.separator())
                menu.addItem(menuItem("Remix (new seed)") { [weak self] in self?.parent.onRemix(meta) })
                menu.addItem(menuItem("Apply Settings") { [weak self] in
                    var corrected = meta
                    corrected.board = item.board == "Default" ? nil : item.board
                    self?.parent.onApplySettings(item, corrected)
                })
                menu.addItem(menuItem("Use as Img2Img Input") { [weak self] in
                    self?.parent.onUseInImg2Img(item.path)
                })
                menu.addItem(.separator())
            }

            let allBoards = sections.map(\.board)
            let boardsMenu = NSMenu(title: "Move to Group")
            boardsMenu.addItem(menuItem("Default") { [weak self] in self?.parent.onMoveToBoard(item, "Default") })
            let others = allBoards.filter { $0 != "Default" && $0 != item.board }
            if !others.isEmpty {
                boardsMenu.addItem(.separator())
                for board in others {
                    boardsMenu.addItem(menuItem(board) { [weak self] in self?.parent.onMoveToBoard(item, board) })
                }
            }
            let boardsItem = NSMenuItem(title: "Move to Group", action: nil, keyEquivalent: "")
            boardsItem.submenu = boardsMenu
            menu.addItem(boardsItem)

            menu.addItem(.separator())
            menu.addItem(menuItem("Reveal in Finder") { [weak self] in
                self?.parent.onRevealInFinder(item.path)
            })
            menu.addItem(menuItem("Delete") { [weak self] in self?.parent.onDeleteRequest(item) })

            return menu
        }
    }
}

// MARK: - Focus helper

/// Returns true if the window's current first responder is within `scrollView`'s view hierarchy.
/// Used to decide whether to restore first-responder after a reload — we restore only when
/// focus was already inside the gallery, so we never steal focus from the params panel.
private func isGalleryInResponderChain(scrollView: NSScrollView, window: NSWindow?) -> Bool {
    guard let fr = window?.firstResponder as? NSView else { return false }
    var view: NSView? = fr
    while let v = view {
        if v === scrollView { return true }
        view = v.superview
    }
    return false
}

// MARK: - GallerySection model

struct GallerySection {
    let board: String
    let items: [GalleryItem]
    let isExpanded: Bool

    /// Items actually shown in the grid (empty when collapsed).
    var visibleItems: [GalleryItem] { isExpanded ? items : [] }
}
