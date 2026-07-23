// swiftlint:disable file_length
import AppKit
import SwiftUI

struct GenerationGalleryView: View {
    private static let collapsedBoardsKey = "gallery.collapsedBoards"

    @Environment(GalleryStore.self) private var gallery
    @Environment(AppSettings.self) private var settings

    @Binding var selectedItem: GalleryItem?
    /// Only images produced by this model family are shown.
    var modelFilter: ModelFamily = .flux
    let onRemix: (GenerationMetadata) -> Void
    let onApplySettings: (GenerationMetadata) -> Void
    let onRemixIdeogram: (Ideogram4Metadata) -> Void
    let onApplyIdeogramSettings: (Ideogram4Metadata) -> Void
    let onUseInImg2Img: (String) -> Void
    var onUpscale: (([String]) -> Void)?
    var onSelectBoard: ((String) -> Void)?
    var onClearPreview: (() -> Void)?
    var onCompare: ((GalleryItem, GalleryItem) -> Void)?
    var isFullSizeShowing: Bool = false

    @State private var deleteTarget: GalleryItem?
    @State private var showingDeleteConfirm: Bool = false
    @State private var renamingBoard: String?
    @State private var renameNameDraft: String = ""
    @State private var showingRenameAlert: Bool = false
    @State private var deletingBoard: String?
    @State private var showingBoardDeleteConfirm: Bool = false
    @State private var showingNewGroup: Bool = false
    @State private var newGroupName: String = ""
    // Inverted: we store collapsed boards. New boards are not in the set → auto-expanded.
    @State private var collapsedBoards: Set<String> = []
    // Unified selection: all selected items live here (plain click and Cmd+click alike).
    // anchorItemId is the "preview" item shown in the right pane.
    @State private var selection: Set<UUID> = []
    @State private var anchorItemId: UUID?
    // Transient confirmation toast (e.g. after stripping metadata).
    @State private var statusMessage: String?
    @State private var statusDismissTask: Task<Void, Never>?
    // Culling filter bar state.
    @State private var searchText: String = ""
    @State private var flagFilter: FlagFilter = .all
    @State private var minRating: Int = 0
    @State private var showingDeleteRejectsConfirm: Bool = false

    /// Store items limited to the selected model family — the source of truth for
    /// everything the gallery displays and navigates (sections, board counts,
    /// adjacency, range selection). Mutating operations still address the full
    /// store by id, so they are unaffected by this filter.
    private var modelItems: [GalleryItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return gallery.items.filter { item in
            guard item.modelFamily == modelFilter else { return false }
            switch flagFilter {
            case .all: break
            case .picks: if item.flag != .pick { return false }
            case .rejects: if item.flag != .reject { return false }
            case .unflagged: if item.flag != nil { return false }
            }
            if item.rating < minRating { return false }
            if !query.isEmpty, !searchHaystack(for: item).contains(query) { return false }
            return true
        }
    }

    /// Whether any culling filter is narrowing the gallery (drives the "clear" affordance).
    private var isFiltering: Bool {
        flagFilter != .all || minRating > 0 || !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// All reject-flagged images in the current model family, across every board —
    /// the target set for "delete all rejects in one pass".
    private var allRejects: [GalleryItem] {
        gallery.rejectedItems(modelFamily: modelFilter)
    }

    private var orderedBoards: [String] {
        let hasDefault = modelItems.contains { $0.board == "Default" }
        let others = gallery.boards.filter { $0 != "Default" }.sorted()
        return (hasDefault ? ["Default"] : []) + others
    }

    private var gallerySections: [GallerySection] {
        // Named folders are shown even when empty (their header acts as the drop
        // target and delete affordance); the implicit "Default" board only appears
        // when it actually holds loose images at the output root.
        orderedBoards.map { board in
            let items = modelItems.filter { $0.board == board }
            return GallerySection(board: board, items: items, isExpanded: !collapsedBoards.contains(board))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

            filterBar
                .padding(.horizontal, 8)
                .padding(.bottom, 6)

            Divider()

            if selection.count > 1 {
                batchActionBar
                Divider()
            }

            if gallerySections.isEmpty {
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
                    onCullFlag: { flag in cullCurrent(flag: flag) },
                    onCullRating: { rating in cullCurrent(rating: rating) },
                    onCompareKey: { startCompare() },
                    onCompareItem: { item in compareItem(item) },
                    onSetFlagItem: { item, flag in setMenuFlag(flag, on: item) },
                    onSetRatingItem: { item, rating in setMenuRating(rating, on: item) },
                    onRemix: onRemix,
                    onApplySettings: { _, meta in onApplySettings(meta) },
                    onRemixIdeogram: onRemixIdeogram,
                    onApplyIdeogramSettings: { _, meta in onApplyIdeogramSettings(meta) },
                    onUseInImg2Img: onUseInImg2Img,
                    onUpscale: { path in
                        // Upscale the whole selection when the right-clicked item is
                        // part of it; otherwise just the clicked image. Mirrors the
                        // strip/move/delete context actions.
                        let item = gallery.items.first { $0.path == path }
                        let targets: [String] = if let item, selection.contains(item.id) {
                            gallery.items
                                .filter { selection.contains($0.id) }
                                .map(\.path)
                        } else {
                            [path]
                        }
                        onUpscale?(targets)
                    },
                    onMoveToBoard: { item, board in
                        if selection.contains(item.id) {
                            batchMove(to: board)
                        } else {
                            gallery.moveItem(item, toBoard: board, outputDir: settings.outputDir)
                        }
                    },
                    onNewGroup: { item in
                        // Ensure the right-clicked item is the move target, then reuse
                        // the shared new-group popover (confirmNewGroup moves the selection).
                        if !selection.contains(item.id) {
                            selection = [item.id]
                            anchorItemId = item.id
                            selectedItem = item
                        }
                        showingNewGroup = true
                    },
                    onStripMetadata: { item in
                        let targets = selection.contains(item.id)
                            ? gallery.items.filter { selection.contains($0.id) }
                            : [item]
                        stripMetadata(of: targets)
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
                    onDeleteBoard: { board in
                        deletingBoard = board
                        showingBoardDeleteConfirm = true
                    },
                    onEscape: {
                        clearSelection(nextItem: nil)
                        onClearPreview?()
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .bottom) { statusToast }
        .background(deleteRejectsShortcut)
        .onAppear { loadCollapsedBoards() }
        .onChange(of: selectedItem?.id) { _, newId in
            guard let id = newId else {
                // Preview was cleared externally (the pane's ✕, Escape, or a restore to the
                // active job). Drop our own selection too so the highlighted cell doesn't
                // linger out of sync with the now-empty preview pane.
                selection = []
                anchorItemId = nil
                return
            }
            guard anchorItemId != id else { return }
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
        .alert("Image in use", isPresented: Binding(
            get: { gallery.lockError != nil },
            set: { if !$0 { gallery.lockError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(gallery.lockError ?? "")
        }
        .alert("Could not strip metadata", isPresented: Binding(
            get: { gallery.stripError != nil },
            set: { if !$0 { gallery.stripError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(gallery.stripError ?? "")
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
                Text("This will permanently delete the image and its metadata file.")
            } else {
                Text("This will permanently delete \(selection.count) images and their metadata files.")
            }
        }
        .confirmationDialog(
            "Delete folder \"\(deletingBoard ?? "")\"?",
            isPresented: $showingBoardDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let board = deletingBoard {
                    if collapsedBoards.contains(board) { collapsedBoards.remove(board) }
                    gallery.deleteBoard(board, outputDir: settings.outputDir)
                }
                deletingBoard = nil
            }
            Button("Cancel", role: .cancel) { deletingBoard = nil }
        } message: {
            let count = boardImageCount(deletingBoard)
            if count == 0 {
                Text("This empty folder will be permanently deleted.")
            } else {
                Text("This will permanently delete the folder and its \(count) "
                    + "image\(count == 1 ? "" : "s") (plus their metadata files).")
            }
        }
        .confirmationDialog(
            "Delete \(allRejects.count) rejected image\(allRejects.count == 1 ? "" : "s")?",
            isPresented: $showingDeleteRejectsConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteAllRejects() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes every reject-flagged image in this model's "
                + "gallery (and their metadata files), across all groups.")
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

    // MARK: - Filter / culling bar

    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption2).foregroundStyle(.secondary)
            TextField("Prompt, LoRA, seed…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.caption)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .frame(width: 20, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.tertiary)
            }

            Divider().frame(height: 14)

            flagFilterMenu
            ratingFilterMenu
            if isFiltering {
                Button { clearFilters() } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .font(.caption)
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Clear filters")
            }
            if !allRejects.isEmpty {
                Button(role: .destructive) { showingDeleteRejectsConfirm = true } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "trash")
                        Text("\(allRejects.count)")
                    }
                    .font(.caption)
                    .frame(height: 22)
                    .padding(.horizontal, 7)
                    .contentShape(Rectangle())
                    .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain).foregroundStyle(.red)
                .help("Delete all \(allRejects.count) rejected image\(allRejects.count == 1 ? "" : "s") (⌘⌫)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isFiltering ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.08))
        )
    }

    private var flagFilterMenu: some View {
        Menu {
            Picker("Flag", selection: $flagFilter) {
                ForEach(FlagFilter.allCases) { option in
                    Label(option.label, systemImage: option.systemImage).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: flagFilter.systemImage)
                .font(.caption)
                .foregroundStyle(flagFilter == .all ? Color.secondary : Color.accentColor)
                .frame(height: 22)
                .padding(.horizontal, 3)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Filter by pick/reject flag")
    }

    private var ratingFilterMenu: some View {
        Menu {
            Picker("Minimum rating", selection: $minRating) {
                Text("Any rating").tag(0)
                ForEach(1 ... 5, id: \.self) { stars in
                    Text(String(repeating: "★", count: stars) + " & up").tag(stars)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 1) {
                Image(systemName: minRating > 0 ? "star.fill" : "star")
                    .font(.caption)
                if minRating > 0 {
                    Text("\(minRating)+").font(.caption2)
                }
            }
            .foregroundStyle(minRating > 0 ? Color.accentColor : Color.secondary)
            .frame(height: 22)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Filter by minimum star rating")
    }

    // MARK: - Batch action bar (shown only when 2+ items selected)

    private var batchActionBar: some View {
        // Prefer the labelled layout; fall back to icon-only when the pane is too
        // narrow to fit the labels without wrapping.
        ViewThatFits(in: .horizontal) {
            batchActionBarContent(showLabels: true)
            batchActionBarContent(showLabels: false)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.06))
    }

    // MARK: - Status toast

    @ViewBuilder
    private var statusToast: some View {
        if let statusMessage {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(statusMessage)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2)))
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
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

    /// ⌘⌫ deletes all rejects from anywhere in the window — parity with ⌘↵ Generate,
    /// which isn't gated on gallery focus. A hidden keyboard-shortcut button owns the
    /// key equivalent (processed before the first responder's keyDown), so it fires even
    /// when the params pane holds focus, not only when the gallery collection view does.
    /// Disabled when there's nothing to delete so ⌘⌫ still reaches text fields as
    /// delete-to-start-of-line whenever no rejects exist.
    private var deleteRejectsShortcut: some View {
        Button("") { deleteAllRejects() }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(allRejects.isEmpty)
            .hidden()
            .accessibilityHidden(true)
    }

    // MARK: - Helpers

    private func batchActionBarContent(showLabels: Bool) -> some View {
        let labelStyle = AdaptiveLabelStyle(showTitle: showLabels)

        return HStack(spacing: 8) {
            Text("\(selection.count) selected")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize()
                .layoutPriority(showLabels ? 0 : 1)
            Spacer(minLength: 8)
            Button { startCompare() } label: {
                Label("Compare", systemImage: "rectangle.split.2x1")
                    .font(.caption).labelStyle(labelStyle)
            }
            .buttonStyle(.borderless).help("Compare two images side by side (c)")

            Button {
                let paths = gallery.items
                    .filter { selection.contains($0.id) }
                    .map(\.path)
                onUpscale?(paths)
            } label: {
                Label("Upscale", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.caption).labelStyle(labelStyle)
            }
            .buttonStyle(.borderless).help("Upscale all selected images with SeedVR2")

            Menu {
                ForEach(orderedBoards, id: \.self) { board in
                    Button(board) { batchMove(to: board) }
                }
                Divider()
                Button("New Group…") { showingNewGroup = true }
            } label: {
                Label("Move", systemImage: "folder")
                    .font(.caption).labelStyle(labelStyle)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Move the selected images to a group")

            Button {
                stripMetadata(of: gallery.items.filter { selection.contains($0.id) })
            } label: {
                Image(systemName: "tag.slash").font(.caption)
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .help("Strip embedded metadata (prompt, parameters) from the selected images")

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
        .lineLimit(1)
    }

    private func boardImageCount(_ board: String?) -> Int {
        guard let board else { return 0 }
        return gallery.items.filter { $0.board == board }.count
    }

    private func batchMove(to board: String) {
        let toMove = gallery.items.filter { selection.contains($0.id) }
        gallery.moveItems(toMove, toBoard: board, outputDir: settings.outputDir)
        clearSelection(nextItem: nil)
    }

    private func stripMetadata(of targets: [GalleryItem]) {
        guard !targets.isEmpty else { return }
        let stripped = gallery.stripMetadata(from: targets)
        // Errors surface via the stripError alert; confirm success with a toast.
        if stripped > 0 {
            showStatus("Stripped metadata from \(stripped) image\(stripped == 1 ? "" : "s")")
        }
    }

    private func showStatus(_ message: String) {
        statusDismissTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { statusMessage = message }
        statusDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { statusMessage = nil }
        }
    }

    private func clearSelection(nextItem: GalleryItem?) {
        selection = nextItem.map { [$0.id] } ?? []
        anchorItemId = nextItem?.id
        selectedItem = nextItem
    }

    private func deleteAllRejects() {
        let rejects = allRejects
        guard !rejects.isEmpty else { return }
        let ids = Set(rejects.map(\.id))
        if let anchorId = anchorItemId, ids.contains(anchorId) {
            clearSelection(nextItem: nil)
        }
        gallery.deleteItems(rejects, outputDir: settings.outputDir)
    }

    // MARK: - Range select (shift+click)

    private func rangeSelect(to item: GalleryItem) {
        let items = modelItems
        guard let targetIdx = items.firstIndex(where: { $0.id == item.id }) else { return }
        if let anchorId = anchorItemId,
           let anchorIdx = items.firstIndex(where: { $0.id == anchorId }) {
            let lo = min(anchorIdx, targetIdx)
            let hi = max(anchorIdx, targetIdx)
            for i in lo ... hi {
                selection.insert(items[i].id)
            }
        } else {
            selection = [item.id]
            anchorItemId = item.id
            selectedItem = item
        }
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

    private func adjacentItem(to item: GalleryItem) -> GalleryItem? {
        let boardItems = modelItems.filter { $0.board == item.board }
        guard let idx = boardItems.firstIndex(where: { $0.id == item.id }) else { return nil }
        let nextIdx = idx + 1 < boardItems.count ? idx + 1 : idx - 1
        return nextIdx >= 0 ? boardItems[nextIdx] : nil
    }

    private func clearFilters() {
        searchText = ""
        flagFilter = .all
        minRating = 0
    }

    /// Lower-cased blob of the sidecar fields the search box matches against:
    /// prompt text, seed, model, and LoRA names.
    private func searchHaystack(for item: GalleryItem) -> String {
        var parts: [String] = [item.filename]
        if let meta = item.metadata {
            parts.append(meta.prompt)
            parts.append(meta.negativePrompt)
            parts.append(String(meta.seed))
            parts.append("\(meta.model)")
            parts.append(contentsOf: meta.loras.map(\.displayName))
        }
        if let meta = item.ideogram4Metadata {
            parts.append(meta.plainPrompt)
            parts.append(String(meta.seed))
            parts.append(contentsOf: (meta.loras ?? []).map(\.displayName))
        }
        if let meta = item.krea2Metadata {
            parts.append(meta.prompt)
            parts.append(String(meta.seed))
            parts.append(contentsOf: (meta.loras ?? []).map(\.displayName))
        }
        if let meta = item.zimageMetadata {
            parts.append(meta.prompt)
            parts.append(String(meta.seed))
            parts.append(contentsOf: (meta.loras ?? []).map(\.displayName))
        }
        return parts.joined(separator: " ").lowercased()
    }

    // MARK: - Culling (keyboard-driven pick/reject + ratings)

    /// The images a cull key acts on: the whole selection when several are selected
    /// (group triage), otherwise just the anchor item.
    private func cullTargets() -> [GalleryItem] {
        if selection.count > 1 {
            return gallery.items.filter { selection.contains($0.id) }
        }
        guard let id = anchorItemId, let item = gallery.items.first(where: { $0.id == id }) else { return [] }
        return [item]
    }

    /// Applies a pick/reject flag. With one image selected it toggles the anchor and
    /// auto-advances so the board can be culled from the keyboard. With several selected
    /// it flags the whole group at once (clearing only when every one already has that
    /// flag) and keeps the selection — no auto-advance. The `u` key passes `nil` to unflag.
    private func cullCurrent(flag: PickFlag?) {
        let targets = cullTargets()
        guard !targets.isEmpty else { return }
        if targets.count > 1 {
            let allHaveIt = flag != nil && targets.allSatisfy { $0.flag == flag }
            let newFlag = allHaveIt ? nil : flag
            for item in targets {
                gallery.setFlag(newFlag, for: item)
            }
        } else {
            let item = targets[0]
            let newFlag = item.flag == flag ? nil : flag
            // Snapshot the filtered board ordering *before* mutating: setting the flag
            // can drop the culled item out of a flag-filtered view (e.g. "unflagged"),
            // and the post-mutation list would no longer contain it to advance from.
            let boardItems = modelItems.filter { $0.board == item.board }
            let idx = boardItems.firstIndex { $0.id == item.id }
            gallery.setFlag(newFlag, for: item)
            advanceAnchorAfterCull(item: item, boardItems: boardItems, idx: idx)
        }
    }

    /// Sets the star rating on the selected image(s). Applies to the whole selection for
    /// group triage. Unlike flags, ratings never auto-advance — you often adjust a rating
    /// in place before moving on.
    private func cullCurrent(rating: Int) {
        for item in cullTargets() {
            gallery.setRating(rating, for: item)
        }
    }

    /// Sets a flag from the context menu — no auto-advance. Applies to the whole
    /// selection when the right-clicked item is part of a multi-selection, otherwise
    /// just that item (mirrors the strip/delete context actions).
    private func setMenuFlag(_ flag: PickFlag?, on item: GalleryItem) {
        for target in menuTargets(for: item) {
            gallery.setFlag(flag, for: target)
        }
    }

    private func setMenuRating(_ rating: Int, on item: GalleryItem) {
        for target in menuTargets(for: item) {
            gallery.setRating(rating, for: target)
        }
    }

    private func menuTargets(for item: GalleryItem) -> [GalleryItem] {
        if selection.count > 1, selection.contains(item.id) {
            return gallery.items.filter { selection.contains($0.id) }
        }
        return [item]
    }

    // MARK: - Compare

    /// Opens Compare from the anchor: pins it as the select, and picks the candidate —
    /// the other selected image if two-plus are selected, otherwise the next sibling.
    private func startCompare() {
        guard let id = anchorItemId, let anchor = gallery.items.first(where: { $0.id == id }) else { return }
        let boardItems = modelItems.filter { $0.board == anchor.board }
        let candidate: GalleryItem? = if selection.count >= 2 {
            boardItems.first { selection.contains($0.id) && $0.id != anchor.id }
        } else if let idx = boardItems.firstIndex(where: { $0.id == anchor.id }) {
            idx + 1 < boardItems.count ? boardItems[idx + 1] : (idx > 0 ? boardItems[idx - 1] : nil)
        } else {
            nil
        }
        guard let candidate else { return }
        onCompare?(anchor, candidate)
    }

    /// Opens Compare from the context menu: the clicked item is the select, its next
    /// sibling the candidate.
    private func compareItem(_ item: GalleryItem) {
        let boardItems = modelItems.filter { $0.board == item.board }
        guard let idx = boardItems.firstIndex(where: { $0.id == item.id }) else { return }
        let candidate = idx + 1 < boardItems.count ? boardItems[idx + 1] : (idx > 0 ? boardItems[idx - 1] : nil)
        guard let candidate else { return }
        onCompare?(item, candidate)
    }

    /// Moves the anchor (and the previewed item) to the next image after a cull, using the
    /// pre-mutation board ordering (`boardItems`/`idx`) so it works even when setting the
    /// flag just removed the culled item from a flag-filtered view. Prefers the following
    /// sibling; if the culled item left the active filter and was last, falls back to the
    /// previous sibling (or clears when the board is now empty); if it is still visible and
    /// last, stays put.
    private func advanceAnchorAfterCull(item: GalleryItem, boardItems: [GalleryItem], idx: Int?) {
        guard let idx else { return }
        let stillVisible = modelItems.contains { $0.id == item.id }
        if idx + 1 < boardItems.count {
            clearSelection(nextItem: boardItems[idx + 1])
        } else if !stillVisible {
            clearSelection(nextItem: idx - 1 >= 0 ? boardItems[idx - 1] : nil)
        }
        // else: still visible and at the end — keep it selected.
    }
}

/// Shows a label's icon always and its title only when there is room, so the
/// batch action bar can drop to icon-only in a narrow gallery pane.
private struct AdaptiveLabelStyle: LabelStyle {
    let showTitle: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            if showTitle {
                configuration.title
            }
        }
    }
}
