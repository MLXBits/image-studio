import AppKit
import Foundation
import UniformTypeIdentifiers

struct GalleryItem: Identifiable, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    let id: UUID
    let path: String
    let board: String
    let modifiedAt: Date
    var thumbnailData: Data?
    var thumbnailImage: NSImage? // decoded from thumbnailData; not persisted
    var metadata: GenerationMetadata?
    var ideogram4Metadata: Ideogram4Metadata?
    var krea2Metadata: Krea2Metadata?
    var zimageMetadata: ZImageMetadata?
    var qwen21Metadata: Qwen21Metadata?
    var seedVR2Metadata: SeedVR2Metadata?
    /// Lightroom-style cull verdict, persisted as an xattr on the file (see ``GalleryCulling``).
    var flag: PickFlag?
    /// 0–5 star rating, persisted as an xattr on the file.
    var rating: Int = 0
    /// The lowercased search haystack, built once when the item is constructed
    /// (the scan funnel) so an active search does zero per-item string building.
    let searchHaystack: String

    var url: URL {
        URL(fileURLWithPath: path)
    }

    /// Deliberately not `url.lastPathComponent`: `url` is computed, so that built a
    /// fresh `URL` per access. `modelFamily` calls this for every gallery item on
    /// every layout pass, which made URL parsing the hottest frame in a window resize.
    nonisolated var filename: String {
        (path as NSString).lastPathComponent
    }

    /// Which model family produced this image, used to filter the gallery to the
    /// currently selected model. Ideogram outputs are named with an "ideogram"
    /// prefix (e.g. `ideogram4_…`); everything else is treated as Flux. A SeedVR2
    /// upscale (`seedvr2_…`) isn't a picker family, so it inherits its *source*
    /// image's family (from the sidecar) — the upscale then sits in the same
    /// filtered view and board as the image it was made from.
    nonisolated var modelFamily: ModelFamily {
        let name = filename.lowercased()
        if name.hasPrefix("ideogram") {
            return .ideogram4
        }
        if name.hasPrefix("krea2") {
            return .krea2
        }
        if name.hasPrefix("zimage") {
            return .zimage
        }
        if name.hasPrefix("qwen21") {
            return .qwen21
        }
        if name.hasPrefix("seedvr2") {
            // Prefer the embedded source metadata (definitive, and correct even for a
            // chained upscale whose source filename is itself "seedvr2_…").
            if seedVR2Metadata?.sourceIdeogram4 != nil {
                return .ideogram4
            }
            if seedVR2Metadata?.sourceKrea2 != nil {
                return .krea2
            }
            if seedVR2Metadata?.sourceZImage != nil {
                return .zimage
            }
            if seedVR2Metadata?.sourceFlux != nil {
                return .flux
            }
            // Pre-inheritance sidecar: fall back to the source filename prefix.
            let src = ((seedVR2Metadata?.sourcePath ?? "") as NSString).lastPathComponent.lowercased()
            if src.hasPrefix("ideogram") {
                return .ideogram4
            }
            if src.hasPrefix("krea2") {
                return .krea2
            }
            if src.hasPrefix("zimage") {
                return .zimage
            }
            // Upscales don't carry Qwen source metadata yet; the filename keeps them in the right view.
            if src.hasPrefix("qwen21") {
                return .qwen21
            }
            return .flux
        }
        return .flux
    }
}

/// Manages the image gallery by scanning the output directory for image files.
///
/// The gallery is filesystem-driven: ``scan(outputDir:)`` enumerates the output directory and
/// updates ``items`` accordingly. Thumbnails are generated lazily on demand via
/// ``loadThumbnail(for:)``. Sidecar `.json` files are read alongside each image to populate
/// metadata shown in the gallery detail view.
@Observable
@MainActor
final class GalleryStore {
    private static let imageExtensions = Set(["png", "jpg", "jpeg", "webp"])

    var items: [GalleryItem] = []
    var boards: [String] = []
    var selectedBoard: String = "All"
    private(set) var isScanning: Bool = false
    private var scanGeneration = 0
    /// Set when a deletion fails; cleared by the next successful delete operation.
    /// Observed by ``GenerationGalleryView`` to display an alert.
    var deleteError: String?
    /// Set when a metadata strip fails. Observed by ``GenerationGalleryView``.
    var stripError: String?
    /// Set when moving an image to another board fails, or is refused because the
    /// board already holds a file with the same name. Observed by ``GenerationGalleryView``.
    var moveError: String?
    /// Absolute paths currently attached to an img2img / edit drop area. Any
    /// operation that would move, rename away, or delete one of these would
    /// rug-pull a queued or future generation, so they are protected — such
    /// operations are refused and surface ``lockError``. Kept in sync by
    /// ``ContentView`` from the live params-panel state.
    var lockedPaths: Set<String> = []
    /// Set when an operation is refused because it targets a protected image —
    /// one attached to an img2img / edit drop area (see ``lockedPaths``), or one
    /// flagged as a pick (deletion only). Distinct from ``deleteError``: this is an
    /// intentional block, not a failure. Observed by ``GenerationGalleryView``.
    var lockError: String?
    /// The active profile's thumbnail cache folder. Copied into each background
    /// task when it starts, so work for a previous profile stays in its folder.
    private(set) var thumbnailDirectory: URL = ThumbnailCache.rootDirectory

    var displayedItems: [GalleryItem] {
        if selectedBoard == "All" {
            return items
        }
        return items.filter { $0.board == selectedBoard }
    }

    /// Points the gallery at a profile's thumbnail folder and drops everything
    /// from the previous library. Bumping ``scanGeneration`` discards a scan of
    /// the old library that is still in flight. `preservingLocks` is for a folder
    /// change within the same profile: the form state — and so what's attached —
    /// is unchanged, and ContentView only re-syncs the locks when it appears.
    func activate(thumbnailDirectory: URL, preservingLocks: Bool = false) {
        self.thumbnailDirectory = thumbnailDirectory
        scanGeneration += 1
        items = []
        boards = []
        selectedBoard = "All"
        if !preservingLocks {
            lockedPaths = []
        }
        isScanning = false
        deleteError = nil
        stripError = nil
        lockError = nil
    }

    func scan(outputDir: String) {
        guard !outputDir.isEmpty else { return }
        isScanning = true
        scanGeneration += 1
        let myGeneration = scanGeneration
        let exts = Self.imageExtensions
        let thumbs = thumbnailDirectory
        // Snapshot existing items so the detached task can preserve UUIDs and cached thumbnails.
        let existing = Dictionary(uniqueKeysWithValues: items.map { ($0.path, $0) })
        Task.detached(priority: .userInitiated) {
            let found = scanDirectory(outputDir, imageExtensions: exts, existing: existing)
            // Folders are first-class boards even when empty, so list subdirectories
            // directly rather than deriving boards solely from the images found.
            let folders = scanBoardFolders(outputDir)
            // Safety net for files deleted outside the app (Finder, scripts).
            // A missing root (unplugged drive) scans as empty — sweeping then
            // would wipe every thumbnail, so leave the cache alone.
            if FileManager.default.fileExists(atPath: outputDir) {
                ThumbnailCache.sweep(validPaths: Set(found.map(\.path)), in: thumbs)
            }
            await MainActor.run { [weak self] in
                guard let self, self.scanGeneration == myGeneration else { return }
                self.items = found
                self.boards = Array(Set(found.map(\.board) + folders)).sorted()
                self.isScanning = false
                // Proactively load thumbnails for items new to this scan.
                for item in found where existing[item.path] == nil {
                    self.loadThumbnail(for: item)
                }
            }
        }
    }

    func loadThumbnail(for item: GalleryItem) {
        guard item.thumbnailImage == nil else { return }
        let path = item.path
        let existingData = item.thumbnailData
        let thumbs = thumbnailDirectory
        Task.detached(priority: .background) {
            let thumbnailData: Data?
            if let data = existingData {
                thumbnailData = data
            } else if let cached = ThumbnailCache.read(for: path, in: thumbs) {
                thumbnailData = cached
            } else {
                guard let generated = ThumbnailCache.makeThumbnailData(forSourcePath: path) else { return }
                ThumbnailCache.store(data: generated, for: path, in: thumbs)
                thumbnailData = generated
            }
            let nsImage = thumbnailData.flatMap { NSImage(data: $0) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let idx = self.items.firstIndex(where: { $0.path == path }) {
                    self.items[idx].thumbnailData = thumbnailData
                    self.items[idx].thumbnailImage = nsImage
                }
            }
        }
    }

    // MARK: - Culling (pick/reject flags + star ratings)

    /// Sets (or clears, with `nil`) the pick/reject flag for an item. The xattr write
    /// is the source of truth; the in-memory item is updated optimistically so the grid
    /// and preview reflect the change without waiting for a rescan.
    func setFlag(_ flag: PickFlag?, for item: GalleryItem) {
        GalleryCulling.writeFlag(flag, path: item.path)
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].flag = flag
        }
    }

    /// Sets the 0–5 star rating for an item (0 clears it), persisting to xattr and
    /// updating the in-memory item optimistically.
    func setRating(_ rating: Int, for item: GalleryItem) {
        let clamped = min(5, max(0, rating))
        GalleryCulling.writeRating(clamped, path: item.path)
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].rating = clamped
        }
    }

    /// Every reject-flagged image in the given model family, across all boards —
    /// the target set for "delete all rejects in one pass".
    func rejectedItems(modelFamily: ModelFamily) -> [GalleryItem] {
        // Flag first: it's a stored enum, while `modelFamily` parses the filename.
        items.filter { $0.flag == .reject && $0.modelFamily == modelFamily }
    }

    /// Count only, for the affordances that just need "how many" — the views read this
    /// several times per `body`, and building the array each time showed up in resize
    /// profiles.
    func rejectedCount(modelFamily: ModelFamily) -> Int {
        items.reduce(into: 0) { total, item in
            if item.flag == .reject, item.modelFamily == modelFamily {
                total += 1
            }
        }
    }
}

// MARK: - Free function (nonisolated, safe to call from Task.detached)

nonisolated private func scanDirectory(
    _ outputDir: String,
    imageExtensions: Set<String>,
    existing: [String: GalleryItem] = [:]
) -> [GalleryItem] {
    let root = URL(fileURLWithPath: outputDir)
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }

    var result: [GalleryItem] = []
    for case let url as URL in enumerator {
        let ext = url.pathExtension.lowercased()
        guard imageExtensions.contains(ext),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
        let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast

        let relativePath = String(url.path.dropFirst(root.path.count + 1))
        let components = relativePath.split(separator: "/")
        let board = components.count > 1 ? String(components[0]) : "Default"

        let prior = existing[url.path]
        let fluxMeta: GenerationMetadata?
        let ideogramMeta: Ideogram4Metadata?
        let krea2Meta: Krea2Metadata?
        let zimageMeta: ZImageMetadata?
        let qwen21Meta: Qwen21Metadata?
        let seedVR2Meta: SeedVR2Metadata?
        let priorHasMetadata = prior?.metadata != nil
            || prior?.ideogram4Metadata != nil
            || prior?.krea2Metadata != nil
            || prior?.zimageMetadata != nil
            || prior?.qwen21Metadata != nil
            || prior?.seedVR2Metadata != nil
        if let prior, prior.modifiedAt == modDate, priorHasMetadata {
            // Unchanged file already carrying sidecar metadata: skip the JSON re-read.
            // Rescans fire after every completed image, so this is the hot path.
            fluxMeta = prior.metadata
            ideogramMeta = prior.ideogram4Metadata
            krea2Meta = prior.krea2Metadata
            zimageMeta = prior.zimageMetadata
            qwen21Meta = prior.qwen21Metadata
            seedVR2Meta = prior.seedVR2Metadata
        } else {
            // New or changed file — or one whose sidecar hadn't landed yet when last
            // scanned (batch sidecars are written just after the PNG), so retry the read.
            // Z-Image is probed by filename prefix first — its sidecar shares the FLUX
            // shape closely enough that a blind FLUX decode could mis-claim it.
            // Qwen-Image 2.1 is read only by its prefix too, and then nothing else is tried.
            let lowered = url.lastPathComponent.lowercased()
            qwen21Meta = lowered.hasPrefix("qwen21") ? MetadataSidecar.readQwen21(for: url.path) : nil
            let isZImageFile = lowered.hasPrefix("zimage")
            zimageMeta = isZImageFile ? MetadataSidecar.readZImage(for: url.path) : nil
            let claimed = zimageMeta != nil || qwen21Meta != nil
            fluxMeta = !claimed ? MetadataSidecar.read(for: url.path) : nil
            ideogramMeta = fluxMeta == nil && !claimed ? MetadataSidecar.readIdeogram4(for: url.path) : nil
            krea2Meta = fluxMeta == nil && ideogramMeta == nil && !claimed
                ? MetadataSidecar.readKrea2(for: url.path) : nil
            seedVR2Meta = fluxMeta == nil && ideogramMeta == nil && krea2Meta == nil && !claimed
                ? MetadataSidecar.readSeedVR2(for: url.path) : nil
        }
        // Flags/ratings live in xattrs and never change the file's mtime, so the
        // mtime-based skip above can't be used for them — read them fresh each scan.
        // These are lightweight syscalls (no file open), so the cost is negligible.
        result.append(GalleryItem(
            id: prior?.id ?? UUID(), path: url.path, board: board,
            modifiedAt: modDate, thumbnailData: prior?.thumbnailData,
            thumbnailImage: prior?.thumbnailImage,
            metadata: fluxMeta,
            ideogram4Metadata: ideogramMeta,
            krea2Metadata: krea2Meta,
            zimageMetadata: zimageMeta,
            qwen21Metadata: qwen21Meta,
            seedVR2Metadata: seedVR2Meta,
            flag: GalleryCulling.readFlag(path: url.path),
            rating: GalleryCulling.readRating(path: url.path),
            searchHaystack: GallerySearch.haystack(
                filename: (url.path as NSString).lastPathComponent,
                flux: fluxMeta,
                ideogram4: ideogramMeta,
                krea2: krea2Meta,
                zimage: zimageMeta,
                qwen21: qwen21Meta
            )
        ))
    }
    return result.sorted { $0.modifiedAt > $1.modifiedAt }
}

/// Lists the top-level subdirectories of the output directory. Each becomes a board,
/// so empty folders remain visible in the gallery instead of silently disappearing.
nonisolated private func scanBoardFolders(_ outputDir: String) -> [String] {
    let root = URL(fileURLWithPath: outputDir)
    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }
    return contents.compactMap { url in
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
        return url.lastPathComponent
    }
}
