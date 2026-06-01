import SwiftUI
import AppKit

struct GenerationGalleryView: View {
    @Environment(GalleryStore.self) private var gallery
    @Environment(AppSettings.self) private var settings

    @Binding var selectedItem: GalleryItem?
    let onRemix: (GenerationMetadata) -> Void
    let onApplySettings: (GenerationMetadata) -> Void
    let onUseInImg2Img: (String) -> Void
    var onSelectBoard: ((String) -> Void)? = nil
    var onClearPreview: (() -> Void)? = nil

    @State private var deleteTarget: GalleryItem? = nil   // nil = batch, non-nil = single item
    @State private var showingDeleteConfirm: Bool = false
    @State private var keyMonitor: Any? = nil
    @State private var showingNewGroup: Bool = false
    @State private var newGroupName: String = ""
    // Inverted logic: we store collapsed boards. New boards are not in the set → auto-expanded.
    @State private var collapsedBoards: Set<String> = []
    @State private var dropTargetBoard: String? = nil
    @State private var multiSelection: Set<UUID> = []
    @State private var anchorItemId: UUID? = nil  // last plain-click anchor for shift+click range

    private static let collapsedBoardsKey = "gallery.collapsedBoards"
    private let columns = [GridItem(.adaptive(minimum: 80, maximum: 120), spacing: 4)]

    // Default first, then all others alphabetically — filtered to non-empty boards only.
    private var orderedBoards: [String] {
        let hasDefault = gallery.items.contains { $0.board == "Default" }
        let others = gallery.boards.filter { $0 != "Default" }.sorted()
        return (hasDefault ? ["Default"] : []) + others
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

            Divider()

            if !multiSelection.isEmpty {
                batchActionBar
                Divider()
            }

            if gallery.items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(orderedBoards, id: \.self) { board in
                            boardSection(board)
                        }
                    }
                }
            }
        }
        .onAppear {
            loadCollapsedBoards()
            installKeyMonitor()
        }
        .onDisappear { removeKeyMonitor() }
        .onChange(of: collapsedBoards) { _, newValue in
            UserDefaults.standard.set(Array(newValue), forKey: Self.collapsedBoardsKey)
        }
        .confirmationDialog(
            deleteTarget != nil
                ? "Delete image?"
                : "Delete \(multiSelection.count) image\(multiSelection.count == 1 ? "" : "s")?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let item = deleteTarget {
                    selectedItem = adjacentItem(to: item)
                    gallery.delete(item, outputDir: settings.outputDir)
                    deleteTarget = nil
                } else {
                    let toDelete = gallery.items.filter { multiSelection.contains($0.id) }
                    if let sel = selectedItem, multiSelection.contains(sel.id) { selectedItem = nil }
                    gallery.deleteItems(toDelete, outputDir: settings.outputDir)
                    multiSelection.removeAll()
                }
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            if deleteTarget != nil {
                Text("This will permanently delete the image and its sidecar file.")
            } else {
                Text("This will permanently delete \(multiSelection.count) image\(multiSelection.count == 1 ? "" : "s") and their sidecar files.")
            }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Text("Gallery")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            Spacer()
            Button { showingNewGroup = true } label: {
                Image(systemName: "folder.badge.plus")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("New group")
            .popover(isPresented: $showingNewGroup) { newGroupPopover }
        }
    }

    // MARK: - Batch action bar

    private var batchActionBar: some View {
        HStack(spacing: 8) {
            Text("\(multiSelection.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(orderedBoards, id: \.self) { board in
                    Button(board) { batchMove(to: board) }
                }
                Divider()
                Button("New Group…") { showingNewGroup = true }
            } label: {
                Label("Move", systemImage: "folder")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button(role: .destructive) {
                deleteTarget = nil   // nil = batch mode
                showingDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)

            Button {
                multiSelection.removeAll()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.06))
    }

    private func batchMove(to board: String) {
        let toMove = gallery.items.filter { multiSelection.contains($0.id) }
        gallery.moveItems(toMove, toBoard: board, outputDir: settings.outputDir)
        multiSelection.removeAll()
    }

    // MARK: - Board section

    @ViewBuilder
    private func boardSection(_ board: String) -> some View {
        let items = gallery.items.filter { $0.board == board }
        if !items.isEmpty {
            VStack(spacing: 0) {
                DisclosureGroup(isExpanded: isExpanded(for: board)) {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(items) { item in
                            GalleryItemView(
                                item: item,
                                isSelected: selectedItem?.id == item.id,
                                isInMultiSelection: multiSelection.contains(item.id),
                                onSelect: {
                                    NSApp.keyWindow?.makeFirstResponder(nil)
                                    multiSelection.removeAll()
                                    selectedItem = item
                                    anchorItemId = item.id
                                },
                                onMultiToggle: {
                                    if multiSelection.contains(item.id) {
                                        multiSelection.remove(item.id)
                                    } else {
                                        multiSelection.insert(item.id)
                                    }
                                },
                                onRangeSelect: { rangeSelect(to: item) },
                                onRemix: onRemix,
                                onApplySettings: onApplySettings,
                                onUseInImg2Img: onUseInImg2Img,
                                onMoveToBoard: { newBoard in
                                    gallery.moveItem(item, toBoard: newBoard, outputDir: settings.outputDir)
                                },
                                onDelete: {
                                    deleteTarget = item
                                    showingDeleteConfirm = true
                                }
                            )
                            .draggable(item.path)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                } label: {
                    sectionLabel(board: board, count: items.count)
                }
                .padding(.horizontal, 4)

                Divider()
            }
            // Entire section (header + grid) is a drop target.
            .dropDestination(for: String.self) { paths, _ in
                for path in paths {
                    if let item = gallery.items.first(where: { $0.path == path }),
                       item.board != board {
                        gallery.moveItem(item, toBoard: board, outputDir: settings.outputDir)
                    }
                }
                return true
            } isTargeted: { targeted in
                dropTargetBoard = targeted ? board : nil
            }
        }
    }

    // Section header — shows drop highlight when dropTargetBoard matches.
    private func sectionLabel(board: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: dropTargetBoard == board ? "folder.fill" : "folder")
                .font(.caption2)
                .foregroundStyle(dropTargetBoard == board ? Color.accentColor : .secondary)
            Text(board)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(dropTargetBoard == board ? Color.accentColor : .primary)
            Spacer()
            Text("\(count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.secondary.opacity(0.12), in: Capsule())
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(dropTargetBoard == board ? Color.accentColor.opacity(0.12) : Color.clear)
        )
    }

    private func isExpanded(for board: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedBoards.contains(board) },
            set: { expanded in
                if expanded { collapsedBoards.remove(board) }
                else { collapsedBoards.insert(board) }
            }
        )
    }

    // MARK: - Range select (shift+click)

    private func rangeSelect(to item: GalleryItem) {
        let items = gallery.items
        guard let targetIdx = items.firstIndex(where: { $0.id == item.id }) else { return }
        if let anchorId = anchorItemId,
           let anchorIdx = items.firstIndex(where: { $0.id == anchorId }) {
            let lo = min(anchorIdx, targetIdx)
            let hi = max(anchorIdx, targetIdx)
            for i in lo...hi { multiSelection.insert(items[i].id) }
        } else {
            // No anchor yet — treat like a normal select and set anchor
            multiSelection.removeAll()
            selectedItem = item
            anchorItemId = item.id
        }
    }

    // MARK: - New group popover

    private var newGroupPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Group").font(.headline)
            TextField("Group name", text: $newGroupName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit { confirmNewGroup() }
            HStack {
                Button("Cancel") {
                    showingNewGroup = false
                    newGroupName = ""
                }
                Spacer()
                Button("Create") { confirmNewGroup() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newGroupName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
    }

    private func confirmNewGroup() {
        let name = newGroupName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if !multiSelection.isEmpty {
            let toMove = gallery.items.filter { multiSelection.contains($0.id) }
            gallery.moveItems(toMove, toBoard: name, outputDir: settings.outputDir)
            multiSelection.removeAll()
        } else if let item = selectedItem {
            gallery.moveItem(item, toBoard: name, outputDir: settings.outputDir)
            selectedItem = nil
        }
        onSelectBoard?(name)
        showingNewGroup = false
        newGroupName = ""
    }

    // MARK: - Persist collapsed state

    private func loadCollapsedBoards() {
        if let saved = UserDefaults.standard.array(forKey: Self.collapsedBoardsKey) as? [String] {
            collapsedBoards = Set(saved)
        }
        // No saved entry → collapsedBoards stays empty → all boards expanded (correct first-launch default).
        // New boards created later are also not in the set → auto-expanded.
    }

    // MARK: - Keyboard navigation

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape in a non-main window: let SwiftUI-managed sheets handle themselves
            // (they have sheetParent set and their own keyboard shortcuts); close everything else.
            if event.keyCode == 53,
               NSApp.mainWindow != nil,
               let keyWin = NSApp.keyWindow,
               !keyWin.isMainWindow {
                if keyWin.sheetParent != nil {
                    return event   // let sheet's own .keyboardShortcut(.cancelAction/.escape) fire
                }
                keyWin.performClose(nil)
                return nil
            }
            guard !Self.isEditingText() else { return event }
            switch event.keyCode {
            case 123, 126:  // ← ↑
                guard selectedItem != nil else { return event }
                navigate(-1); return nil
            case 124, 125:  // → ↓
                guard selectedItem != nil else { return event }
                navigate(+1); return nil
            case 51, 117:   // Delete / Forward Delete
                let shift = event.modifierFlags.contains(.shift)
                if !multiSelection.isEmpty {
                    if shift {
                        let toDelete = gallery.items.filter { multiSelection.contains($0.id) }
                        if let sel = selectedItem, multiSelection.contains(sel.id) { selectedItem = nil }
                        gallery.deleteItems(toDelete, outputDir: settings.outputDir)
                        multiSelection.removeAll()
                    } else {
                        deleteTarget = nil
                        showingDeleteConfirm = true
                    }
                    return nil
                } else if let item = selectedItem {
                    if shift {
                        selectedItem = adjacentItem(to: item)
                        gallery.delete(item, outputDir: settings.outputDir)
                    } else {
                        deleteTarget = selectedItem
                        showingDeleteConfirm = true
                    }
                    return nil
                }
                return event
            case 53:        // Escape — clear multi-selection, close preview
                if !multiSelection.isEmpty {
                    multiSelection.removeAll()
                    return nil
                }
                if selectedItem != nil {
                    onClearPreview?()
                    return nil
                }
                return event
            default: return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private static func isEditingText() -> Bool {
        guard let fr = NSApp.keyWindow?.firstResponder else { return false }
        if let tv = fr as? NSTextView { return tv.isEditable }
        return fr is NSTextField
    }

    @discardableResult
    private func navigate(_ delta: Int) -> KeyPress.Result {
        let items = gallery.items
        guard !items.isEmpty else { return .ignored }
        if let current = selectedItem, let idx = items.firstIndex(where: { $0.id == current.id }) {
            let next = max(0, min(items.count - 1, idx + delta))
            if next != idx { selectedItem = items[next] }
        } else {
            selectedItem = items.first
        }
        return .handled
    }

    // Returns the item before or after `item` within the same board group.
    private func adjacentItem(to item: GalleryItem) -> GalleryItem? {
        let boardItems = gallery.items.filter { $0.board == item.board }
        guard let idx = boardItems.firstIndex(where: { $0.id == item.id }) else { return nil }
        let nextIdx = idx + 1 < boardItems.count ? idx + 1 : idx - 1
        return nextIdx >= 0 ? boardItems[nextIdx] : nil
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "photo.stack")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No images yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}
