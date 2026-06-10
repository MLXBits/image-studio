import AppKit
import SwiftUI
struct GenerationGalleryView: View {
    @Environment(GalleryStore.self) private var gallery
    @Environment(AppSettings.self) private var settings

    @Binding var selectedItem: GalleryItem?
    let onRemix: (GenerationMetadata) -> Void
    let onApplySettings: (GenerationMetadata) -> Void
    let onUseInImg2Img: (String) -> Void
    var onSelectBoard: ((String) -> Void)?
    var onClearPreview: (() -> Void)?
    var isFullSizeShowing: Bool = false

    @State private var deleteTarget: GalleryItem?
    @State private var showingDeleteConfirm: Bool = false
    @State private var renamingBoard: String?
    @State private var renameNameDraft: String = ""
    @State private var showingRenameAlert: Bool = false
    @State private var showingNewGroup: Bool = false
    @State private var newGroupName: String = ""
    // Inverted: we store collapsed boards. New boards are not in the set → auto-expanded.
    @State private var collapsedBoards: Set<String> = []
    // Unified selection: all selected items live here (plain click and Cmd+click alike).
    // anchorItemId is the "preview" item shown in the right pane.
    @State private var selection: Set<UUID> = []
    @State private var anchorItemId: UUID?

    private static let collapsedBoardsKey = "gallery.collapsedBoards"

    private var orderedBoards: [String] {
        let hasDefault = gallery.items.contains { $0.board == "Default" }
        let others = gallery.boards.filter { $0 != "Default" }.sorted()
        return (hasDefault ? ["Default"] : []) + others
    }

    private var gallerySections: [GallerySection] {
        orderedBoards.compactMap { board in
            let items = gallery.items.filter { $0.board == board }
            guard !items.isEmpty else { return nil }
            return GallerySection(board: board, items: items, isExpanded: !collapsedBoards.contains(board))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

            Divider()

            if selection.count > 1 {
                batchActionBar
                Divider()
            }

            if gallery.items.isEmpty {
                emptyState
            } else {
                GalleryCollectionView(
                    sections: gallerySections,
                    selectedItemId: anchorItemId,
                    multiSelectionIds: selection,
                    anchorItemId: anchorItemId,
                    onSelect: { item in
                        selection = [item.id]
                        anchorItemId = item.id
                        selectedItem = item
                    },
                    onMultiToggle: { item in
                        if selection.contains(item.id) {
                            selection.remove(item.id)
                            if anchorItemId == item.id {
                                anchorItemId = selection.first
                                selectedItem = gallery.items.first { $0.id == selection.first }
                            }
                        } else {
                            selection.insert(item.id)
                            anchorItemId = item.id
                            selectedItem = item
                        }
                    },
                    onRangeSelect: { item in rangeSelect(to: item) },
                    onItemAppear: { item in gallery.loadThumbnail(for: item) },
                    onDeleteRequest: { item in
                        deleteTarget = item
                        showingDeleteConfirm = true
                    },
                    onDeleteImmediate: { item in
                        let adjacent = adjacentItem(to: item)
                        selection.remove(item.id)
                        if anchorItemId == item.id {
                            anchorItemId = adjacent?.id
                            selectedItem = adjacent
                        }
                        gallery.delete(item, outputDir: settings.outputDir)
                    },
                    onDeleteMultiRequest: {
                        deleteTarget = nil
                        showingDeleteConfirm = true
                    },
                    onDeleteMultiImmediate: {
                        let anchorItem = gallery.items.first { $0.id == anchorItemId }
                        let adjacent = anchorItem.flatMap { adjacentItem(to: $0) }
                        let toDelete = gallery.items.filter { selection.contains($0.id) }
                        gallery.deleteItems(toDelete, outputDir: settings.outputDir)
                        clearSelection(nextItem: adjacent)
                    },
                    onRemix: onRemix,
                    onApplySettings: { _, meta in onApplySettings(meta) },
                    onUseInImg2Img: onUseInImg2Img,
                    onMoveToBoard: { item, board in
                        if selection.contains(item.id) {
                            batchMove(to: board)
                        } else {
                            gallery.moveItem(item, toBoard: board, outputDir: settings.outputDir)
                        }
                    },
                    onRevealInFinder: { path in
                        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                    },
                    onToggleSection: { board in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if collapsedBoards.contains(board) {
                                collapsedBoards.remove(board)
                            } else {
                                collapsedBoards.insert(board)
                            }
                        }
                    },
                    onRenameBoard: { board in
                        renamingBoard = board
                        renameNameDraft = board
                        showingRenameAlert = true
                    },
                    onEscape: {
                        clearSelection(nextItem: nil)
                        onClearPreview?()
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { loadCollapsedBoards() }
        .onChange(of: selectedItem?.id) { _, newId in
            guard let id = newId, anchorItemId != id else { return }
            selection = [id]
            anchorItemId = id
        }
        .onChange(of: collapsedBoards) { _, newValue in
            UserDefaults.standard.set(Array(newValue), forKey: Self.collapsedBoardsKey)
        }
        .alert("Could not delete", isPresented: Binding(
            get: { gallery.deleteError != nil },
            set: { if !$0 { gallery.deleteError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(gallery.deleteError ?? "")
        }
        .alert("Rename Folder", isPresented: $showingRenameAlert) {
            TextField("Folder name", text: $renameNameDraft)
            Button("Rename") {
                let trimmed = renameNameDraft.trimmingCharacters(in: .whitespaces)
                if let old = renamingBoard, !trimmed.isEmpty, trimmed != old {
                    if collapsedBoards.contains(old) {
                        collapsedBoards.remove(old)
                        collapsedBoards.insert(trimmed)
                    }
                    gallery.renameBoard(old, to: trimmed, outputDir: settings.outputDir)
                }
                renamingBoard = nil
            }
            Button("Cancel", role: .cancel) { renamingBoard = nil }
        } message: {
            Text("Enter a new name for \"\(renamingBoard ?? "")\".")
        }
        .confirmationDialog(
            deleteTarget != nil || selection.count <= 1
                ? "Delete image?"
                : "Delete \(selection.count) images?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let item = deleteTarget {
                    let adjacent = adjacentItem(to: item)
                    selection.remove(item.id)
                    if anchorItemId == item.id {
                        anchorItemId = adjacent?.id
                        selectedItem = adjacent
                        if selection.isEmpty, let adj = adjacent { selection.insert(adj.id) }
                    }
                    gallery.delete(item, outputDir: settings.outputDir)
                    deleteTarget = nil
                } else {
                    let anchorItem = gallery.items.first { $0.id == anchorItemId }
                    let adjacent = anchorItem.flatMap { adjacentItem(to: $0) }
                    let toDelete = gallery.items.filter { selection.contains($0.id) }
                    gallery.deleteItems(toDelete, outputDir: settings.outputDir)
                    clearSelection(nextItem: adjacent)
                }
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            if deleteTarget != nil || selection.count <= 1 {
                Text("This will permanently delete the image and its sidecar file.")
            } else {
                Text("This will permanently delete \(selection.count) images and their sidecar files.")
            }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Text("Gallery")
                .font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
            Spacer()
            Button { showingNewGroup = true } label: {
                Image(systemName: "plus").font(.caption)
            }
            .buttonStyle(.plain)
            .help("New group")
            .popover(isPresented: $showingNewGroup) { newGroupPopover }
        }
    }

    // MARK: - Batch action bar (shown only when 2+ items selected)

    private var batchActionBar: some View {
        HStack(spacing: 8) {
            Text("\(selection.count) selected")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(orderedBoards, id: \.self) { board in
                    Button(board) { batchMove(to: board) }
                }
                Divider()
                Button("New Group…") { showingNewGroup = true }
            } label: {
                Label("Move", systemImage: "folder").font(.caption)
            }
            .menuStyle(.borderlessButton).fixedSize()

            Button(role: .destructive) {
                deleteTarget = nil
                showingDeleteConfirm = true
            } label: {
                Image(systemName: "trash").font(.caption)
            }
            .buttonStyle(.borderless).foregroundStyle(.red)

            Button { clearSelection(nextItem: nil) } label: {
                Image(systemName: "xmark").font(.caption)
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.06))
    }

    private func batchMove(to board: String) {
        let toMove = gallery.items.filter { selection.contains($0.id) }
        gallery.moveItems(toMove, toBoard: board, outputDir: settings.outputDir)
        clearSelection(nextItem: nil)
    }

    private func clearSelection(nextItem: GalleryItem?) {
        selection = nextItem.map { [$0.id] } ?? []
        anchorItemId = nextItem?.id
        selectedItem = nextItem
    }

    // MARK: - Range select (shift+click)

    private func rangeSelect(to item: GalleryItem) {
        let items = gallery.items
        guard let targetIdx = items.firstIndex(where: { $0.id == item.id }) else { return }
        if let anchorId = anchorItemId,
           let anchorIdx = items.firstIndex(where: { $0.id == anchorId }) {
            let lo = min(anchorIdx, targetIdx)
            let hi = max(anchorIdx, targetIdx)
            for i in lo...hi { selection.insert(items[i].id) }
        } else {
            selection = [item.id]
            anchorItemId = item.id
            selectedItem = item
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
                Button("Cancel") { showingNewGroup = false; newGroupName = "" }
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
        if !selection.isEmpty {
            let toMove = gallery.items.filter { selection.contains($0.id) }
            gallery.moveItems(toMove, toBoard: name, outputDir: settings.outputDir)
            clearSelection(nextItem: nil)
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
    }

    // MARK: - Helpers

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
                .font(.system(size: 36)).foregroundStyle(.tertiary)
            Text("No images yet")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
    }
}
