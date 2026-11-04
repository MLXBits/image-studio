import Foundation

// MARK: - File operations
//
// Moving, deleting and stripping gallery images and boards on disk, and the guards
// that refuse to delete an image attached to a drop area or marked as a pick.

extension GalleryStore {
    // MARK: - deletion guards (img2img lock + approved picks)

    /// Standard "this image is attached to a drop area" message for a single file.
    private func lockMessage(_ name: String) -> String {
        "\(name) is in use as an img2img source. Clear it from the drop area first."
    }

    /// Standard message when a batch operation skips some attached sources.
    private func lockMessage(skipped: [GalleryItem]) -> String {
        "Skipped \(skipped.count) image\(skipped.count == 1 ? "" : "s") in use "
            + "as an img2img source: \(skipped.map(\.filename).joined(separator: ", "))"
    }

    /// Filename of an attached img2img source living under `dir`, if any. Used to
    /// block folder-wide operations (delete/rename) that would take the source with them.
    private func lockedName(under dir: URL) -> String? {
        let prefix = dir.path.hasSuffix("/") ? dir.path : dir.path + "/"
        return lockedPaths.first { $0.hasPrefix(prefix) }
            .map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    /// Whether an image is approved (P) and so protected from deletion. The in-memory
    /// flag only refreshes on scan, so the xattr counts too — either one means approved.
    private func isPick(_ item: GalleryItem) -> Bool {
        item.flag == .pick || GalleryCulling.readFlag(path: item.path) == .pick
    }

    /// Standard "this image is approved" message for a single file.
    private func pickMessage(_ name: String) -> String {
        "\(name) is flagged as a pick. Clear the flag (press P again) before deleting it."
    }

    /// Standard message when a batch deletion skips some approved images.
    private func pickMessage(skipped: [GalleryItem]) -> String {
        "Skipped \(skipped.count) image\(skipped.count == 1 ? "" : "s") flagged "
            + "as a pick: \(skipped.map(\.filename).joined(separator: ", "))"
    }

    func moveItem(_ item: GalleryItem, toBoard board: String, outputDir: String) {
        if lockedPaths.contains(item.path) {
            lockError = lockMessage(item.filename)
            return
        }
        let src = URL(fileURLWithPath: item.path)
        let destDir = board == "Default"
            ? URL(fileURLWithPath: outputDir)
            : URL(fileURLWithPath: outputDir).appendingPathComponent(board)
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent(src.lastPathComponent)
        try? FileManager.default.moveItem(at: src, to: dest)
        let srcJson = MetadataSidecar.sidecarURL(for: item.path)
        if FileManager.default.fileExists(atPath: srcJson.path) {
            let destJson = destDir.appendingPathComponent(srcJson.lastPathComponent)
            try? FileManager.default.moveItem(at: srcJson, to: destJson)
        }
        // Cache is keyed by absolute path; the moved file regenerates under the new key.
        ThumbnailCache.purge(path: item.path, in: thumbnailDirectory)
        scan(outputDir: outputDir)
    }

    func delete(_ item: GalleryItem, outputDir: String) {
        if lockedPaths.contains(item.path) {
            lockError = lockMessage(item.filename)
            return
        }
        // A pick is a keep decision: deleting it takes an explicit un-flag first.
        if isPick(item) {
            lockError = pickMessage(item.filename)
            return
        }
        do {
            try FileManager.default.removeItem(atPath: item.path)
        } catch {
            deleteError = "Could not delete \(item.filename): \(error.localizedDescription)"
        }
        try? FileManager.default.removeItem(at: MetadataSidecar.sidecarURL(for: item.path))
        ThumbnailCache.purge(path: item.path, in: thumbnailDirectory)
        scan(outputDir: outputDir)
    }

    /// Deletes a folder (board) and everything inside it — images and sidecars alike.
    /// The "Default" board maps to the output root and is never deleted.
    func deleteBoard(_ board: String, outputDir: String) {
        guard board != "Default" else { return }
        let dir = URL(fileURLWithPath: outputDir).appendingPathComponent(board)
        // Deleting the folder wholesale would take any attached img2img source
        // inside it down too, so block the whole delete if one lives here.
        if let name = lockedName(under: dir) {
            lockError = "\"\(board)\" contains \(name), which is in use as an "
                + "img2img source. Clear it from the drop area first."
            return
        }
        // Same for an approved pick inside it: the folder delete would take it
        // along, so block until the flag is cleared.
        if let pick = items.first(where: { $0.board == board && isPick($0) }) {
            lockError = "\"\(board)\" contains \(pick.filename), which is flagged as a "
                + "pick. Clear the flag (press P again) before deleting the folder."
            return
        }
        // Purge cache entries for every image we know lives under this board
        // before the folder goes away. The post-scan sweep then catches any we
        // didn't know about (e.g., images added externally since the last scan).
        ThumbnailCache.purge(paths: items.filter { $0.board == board }.map(\.path), in: thumbnailDirectory)
        do {
            try FileManager.default.removeItem(at: dir)
        } catch {
            deleteError = "Could not delete folder \(board): \(error.localizedDescription)"
        }
        scan(outputDir: outputDir)
    }

    func renameBoard(_ oldName: String, to newName: String, outputDir: String) {
        guard oldName != "Default", !newName.trimmingCharacters(in: .whitespaces).isEmpty,
              newName != oldName else { return }
        let outputURL = URL(fileURLWithPath: outputDir)
        let oldDir = outputURL.appendingPathComponent(oldName)
        let newDir = outputURL.appendingPathComponent(newName)
        // Renaming moves every file under the board to a new path, which would
        // rug-pull an attached img2img source living here.
        if let name = lockedName(under: oldDir) {
            lockError = "\"\(oldName)\" contains \(name), which is in use as an "
                + "img2img source. Clear it from the drop area first."
            return
        }
        // Every image under the board changes path, so its cache key changes too.
        ThumbnailCache.purge(paths: items.filter { $0.board == oldName }.map(\.path), in: thumbnailDirectory)
        try? FileManager.default.moveItem(at: oldDir, to: newDir)
        scan(outputDir: outputDir)
    }

    func moveItems(_ items: [GalleryItem], toBoard board: String, outputDir: String) {
        // Skip images attached to a drop area — moving them changes their path and
        // would rug-pull a queued or future generation. The rest move normally.
        let locked = items.filter { lockedPaths.contains($0.path) }
        let movable = items.filter { !lockedPaths.contains($0.path) }
        var purgedPaths: [String] = []
        for item in movable {
            guard item.board != board else { continue }
            let src = URL(fileURLWithPath: item.path)
            let destDir = board == "Default"
                ? URL(fileURLWithPath: outputDir)
                : URL(fileURLWithPath: outputDir).appendingPathComponent(board)
            try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            let dest = destDir.appendingPathComponent(src.lastPathComponent)
            try? FileManager.default.moveItem(at: src, to: dest)
            let srcJson = MetadataSidecar.sidecarURL(for: item.path)
            if FileManager.default.fileExists(atPath: srcJson.path) {
                let destJson = destDir.appendingPathComponent(srcJson.lastPathComponent)
                try? FileManager.default.moveItem(at: srcJson, to: destJson)
            }
            purgedPaths.append(item.path)
        }
        ThumbnailCache.purge(paths: purgedPaths, in: thumbnailDirectory)
        if !locked.isEmpty {
            lockError = lockMessage(skipped: locked)
        }
        scan(outputDir: outputDir)
    }

    func deleteItems(_ items: [GalleryItem], outputDir: String) {
        // Skip images attached to an img2img/edit drop area — deleting them would
        // rug-pull a queued or future generation — and images flagged as a pick,
        // which are approved keeps. The rest are deleted normally.
        let locked = items.filter { lockedPaths.contains($0.path) }
        let unlocked = items.filter { !lockedPaths.contains($0.path) }
        let picked = unlocked.filter { isPick($0) }
        let pickedIds = Set(picked.map(\.id))
        let deletable = unlocked.filter { !pickedIds.contains($0.id) }
        var failures: [String] = []
        for item in deletable {
            do {
                try FileManager.default.removeItem(atPath: item.path)
            } catch {
                failures.append(item.filename)
            }
            try? FileManager.default.removeItem(at: MetadataSidecar.sidecarURL(for: item.path))
        }
        ThumbnailCache.purge(paths: deletable.map(\.path), in: thumbnailDirectory)
        if !failures.isEmpty {
            deleteError = "Could not delete: \(failures.joined(separator: ", "))"
        }
        var blocked: [String] = []
        if !locked.isEmpty {
            blocked.append(lockMessage(skipped: locked))
        }
        if !picked.isEmpty {
            blocked.append(pickMessage(skipped: picked))
        }
        if !blocked.isEmpty {
            lockError = blocked.joined(separator: "\n\n")
        }
        scan(outputDir: outputDir)
    }

    /// Removes embedded metadata (EXIF/IPTC/XMP, including mflux's prompt and
    /// generation-parameter comments) from the image files in place. The pixel
    /// data and the app's sidecar `.json` are left untouched, so Remix / Apply
    /// Settings still work — only the shareable file is sanitized. The file's
    /// modification date is preserved so gallery ordering does not shift.
    /// Returns the number of files successfully stripped. Failures populate
    /// ``stripError`` for the caller to surface.
    @discardableResult
    func stripMetadata(from items: [GalleryItem]) -> Int {
        var failures: [String] = []
        var succeeded = 0
        for item in items {
            if stripImageMetadata(atPath: item.path) {
                succeeded += 1
            } else {
                failures.append(item.filename)
            }
        }
        stripError = failures.isEmpty
            ? nil
            : "Could not strip metadata from: \(failures.joined(separator: ", "))"
        return succeeded
    }
}
