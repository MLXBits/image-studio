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
    @State private var multiSelection: Set<UUID> = []
    @State private var anchorItemId: UUID?

    private static let collapsedBoardsKey = "gallery.collapsedBoards"

    // Default first, then all others alphabetically — non-empty boards only.
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

    private var hasAnySelection: Bool { selectedItem != nil || !multiSelection.isEmpty }

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
                GalleryCollectionView(
                    sections: gallerySections,
                    selectedItemId: selectedItem?.id,
                    multiSelectionIds: multiSelection,
                    anchorItemId: anchorItemId,
                    onSelect: { item in
                        multiSelection.removeAll()
                        selectedItem = item
                        anchorItemId = item.id
                    },
                    onMultiToggle: { item in
                        if multiSelection.contains(item.id) {
                            multiSelection.remove(item.id)
                        } else {
                            multiSelection.insert(item.id)
                        }
                    },
                    onRangeSelect: { item in rangeSelect(to: item) },
                    onItemAppear: { item in gallery.loadThumbnail(for: item) },
                    onDeleteRequest: { item in
                        deleteTarget = item
                        showingDeleteConfirm = true
                    },
                    onDeleteImmediate: { item in
                        selectedItem = adjacentItem(to: item)
                        gallery.delete(item, outputDir: settings.outputDir)
                    },
                    onDeleteMultiRequest: {
                        deleteTarget = nil
                        showingDeleteConfirm = true
                    },
                    onDeleteMultiImmediate: {
                        let toDelete = gallery.items.filter { multiSelection.contains($0.id) }
                        if let sel = selectedItem, multiSelection.contains(sel.id) { selectedItem = nil }
                        gallery.deleteItems(toDelete, outputDir: settings.outputDir)
                        multiSelection.removeAll()
                    },
                    onRemix: onRemix,
                    onApplySettings: { _, meta in onApplySettings(meta) },
                    onUseInImg2Img: onUseInImg2Img,
                    onMoveToBoard: { item, board in
                        if multiSelection.contains(item.id) {
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
                        if !multiSelection.isEmpty {
                            multiSelection.removeAll()
                        } else if selectedItem != nil {
                            onClearPreview?()
                        }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { loadCollapsedBoards() }
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
                let plural = multiSelection.count == 1 ? "" : "s"
                Text("This will permanently delete \(multiSelection.count) image\(plural) and their sidecar files.")
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

    // MARK: - Batch action bar

    private var batchActionBar: some View {
        HStack(spacing: 8) {
            Text("\(multiSelection.count) selected")
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

            Button { multiSelection.removeAll() } label: {
                Image(systemName: "xmark").font(.caption)
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
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
        if !multiSelection.isEmpty {
            let toMove = gallery.items.filter { multiSelection.contains($0.id) }
            gallery.moveItems(toMove, toBoard: name, outputDir: settings.outputDir)
            multiSelection.removeAll()
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
