import AppKit
import Foundation

/// Stateless helpers shared by ``FluxJobRunner`` and ``Ideogram4JobRunner``.
///
/// Both runners drive an `mflux` subprocess the same way — streaming combined
/// stdout+stderr, normalizing carriage returns, detecting completed PNGs, and
/// building thumbnails — so that plumbing lives here once rather than being
/// copied per runner.
enum RunnerSupport {
    /// Wires `process` to a single pipe for combined stdout+stderr and returns an
    /// `AsyncStream` yielding decoded output chunks. The caller is responsible for
    /// tracking the process (e.g. for cancellation).
    static func outputStream(for process: Process) -> AsyncStream<String> {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        return AsyncStream<String> { continuation in
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    continuation.finish()
                } else if let text = String(data: data, encoding: .utf8) {
                    continuation.yield(text)
                }
            }
            process.terminationHandler = { _ in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.finish()
                }
            }
        }
    }

    /// True once a PNG is fully written — detected by the IEND chunk's trailing CRC,
    /// which is only present in a complete file.
    static func isPNGComplete(at path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { handle.closeFile() }
        let size = handle.seekToEndOfFile()
        guard size >= 12 else { return false }
        handle.seek(toFileOffset: size - 4)
        let tail = handle.readDataToEndOfFile()
        return tail.count == 4 && tail[0] == 0xAE && tail[1] == 0x42 && tail[2] == 0x60 && tail[3] == 0x82
    }

    /// Center-crops the image at `path` to a square JPEG thumbnail. Decodes via
    /// ImageIO's downscaling path (no full-resolution decode) and is nonisolated so
    /// batches can be generated off the main actor.
    nonisolated static func loadThumbnail(at path: String) -> Data? {
        guard let cg = ThumbnailCache.makeThumbnailCGImage(forSourcePath: path) else { return nil }
        let side = min(cg.width, cg.height)
        let crop = CGRect(
            x: (cg.width - side) / 2, y: (cg.height - side) / 2,
            width: side, height: side
        )
        guard let squared = cg.cropping(to: crop) else { return nil }
        let rep = NSBitmapImageRep(cgImage: squared)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }

    /// Generates thumbnails for a completed batch off the main actor, in output order.
    static func makeThumbnails(for paths: [String]) async -> [Data] {
        await Task.detached(priority: .userInitiated) {
            paths.map { loadThumbnail(at: $0) ?? Data() }
        }.value
    }

    /// Re-verifies a finished batch against the filesystem: returns the `(seed, path)`
    /// pairs whose PNGs actually landed, invoking `writeSidecar` for any that are
    /// missing a metadata sidecar (the batch poller is asynchronous and may be
    /// cancelled before it sees the last image, so the disk is the source of truth).
    static func reconcileBatch(
        _ batchPaths: [(seed: Int, path: String)],
        writeSidecar: (Int, String) -> Void
    ) -> [(seed: Int, path: String)] {
        batchPaths.filter { item in
            guard FileManager.default.fileExists(atPath: item.path),
                  isPNGComplete(at: item.path) else { return false }
            if !FileManager.default.fileExists(atPath: MetadataSidecar.sidecarURL(for: item.path).path) {
                writeSidecar(item.seed, item.path)
            }
            return true
        }
    }

    /// Stepwise frame PNGs in `dir` (excluding composites and dotfiles), newest first by
    /// creation date. mflux names frames `seed_{seed}_step{N}of{M}.png`, so creation order
    /// tracks step order.
    private static func stepFrames(in dir: URL) -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey]
        ) else { return [] }
        return files
            .filter {
                $0.pathExtension.lowercased() == "png"
                    && !$0.lastPathComponent.contains("composite")
                    && !$0.lastPathComponent.hasPrefix(".")
            }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return a > b
            }
    }

    /// Newest *finished* PNG in `dir`, ignoring composites and dotfiles. Used to surface
    /// the latest stepwise preview.
    static func latestCompletePNG(in dir: URL) -> String? {
        stepFrames(in: dir).first { isPNGComplete(at: $0.path) }?.path
    }

    /// Newest PNG in `dir` regardless of whether it has finished writing. Used to attach a
    /// completion watcher to the frame mflux is currently writing.
    static func newestPNG(in dir: URL) -> String? {
        stepFrames(in: dir).first?.path
    }

    /// Expands a multi-seed output template into per-seed paths. mflux appends
    /// `_seed_{seed}` to the stem for each seed.
    static func expandedPaths(from template: String, seeds: [Int]) -> [(seed: Int, path: String)] {
        let url = URL(fileURLWithPath: template)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dir = url.deletingLastPathComponent().path
        return seeds.map { seed in (seed: seed, path: "\(dir)/\(stem)_seed_\(seed).\(ext)") }
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        return "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
    }

    /// `M:SS` clock format, matching tqdm's elapsed/remaining rendering. Used for the
    /// warm-driver step ETA, which is computed app-side rather than parsed from tqdm.
    static func formatClock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Inserts `text` immediately before the last (possibly incomplete) line. Used to
    /// place stage markers ahead of tqdm output that has no trailing newline.
    static func insertBeforeLastLine(_ log: String, text: String) -> String {
        if let lastNewline = log.lastIndex(of: "\n") {
            let split = log.index(after: lastNewline)
            let head = String(log[...lastNewline]) // includes the \n
            let tail = String(log[split...]) // "" when \n was the last char
            return head + text + tail
        }
        return text + log
    }

    /// Appends `chunk` to `log`, honoring carriage returns by rewinding to the start of
    /// the current line — matching how a terminal renders tqdm progress bars.
    static func appendLog(_ chunk: String, to log: String) -> String {
        var result = log
        for char in chunk {
            if char == "\r" {
                // Trim the current line in place rather than re-slicing the whole
                // string — tqdm emits \r many times per second on a growing log.
                if let nl = result.lastIndex(of: "\n") {
                    result.removeSubrange(result.index(after: nl)...)
                } else {
                    result.removeAll(keepingCapacity: true)
                }
            } else {
                result.append(char)
            }
        }
        return result
    }

    /// The last `maxLines` lines of `log`. Per-chunk parsing (progress bars, status
    /// lines) only ever needs the tail; scanning the whole log per chunk is O(n²)
    /// over a run.
    nonisolated static func logTail(_ log: String, maxLines: Int = 5) -> String {
        var newlines = 0
        var idx = log.endIndex
        while idx > log.startIndex {
            let prev = log.index(before: idx)
            if log[prev] == "\n" {
                newlines += 1
                if newlines >= maxLines { return String(log[idx...]) }
            }
            idx = prev
        }
        return log
    }
}

/// Watches a stepwise-output directory and reports the newest complete PNG as soon as each
/// frame finishes writing. Owns the underlying `DispatchSource`s so a runner just keeps one
/// instance and calls ``start(dir:onLatest:)`` / ``stop()``.
///
/// Two events drive it, both edge-triggered (no polling):
///   - A **directory** vnode source fires when mflux creates the next frame's file. At that
///     point the new file is still partial, so the freshly-created frame is skipped by the
///     completeness check — but a directory event still means the *previous* frame is now done.
///   - A **per-file** vnode source watches the frame currently being written and fires on each
///     content write, so the moment its final bytes (the PNG `IEND` chunk) land we emit it.
///     Without this the directory vnode alone would never re-fire for in-place content writes,
///     leaving the preview ~1 step behind and the final frame only flashing at completion.
@MainActor
final class StepwiseWatcher {
    private var dirSource: (any DispatchSourceProtocol)?
    private var fileSource: (any DispatchSourceProtocol)?
    private var watchedFile: String?
    private var dir: URL?
    private var onLatest: ((String?) -> Void)?

    /// Starts watching `dir`. `onLatest` is invoked with the newest complete PNG path (or nil)
    /// immediately and whenever a frame finishes writing.
    func start(dir: URL, onLatest: @escaping (String?) -> Void) {
        stop()
        self.dir = dir
        self.onLatest = onLatest
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main
        )
        src.setEventHandler { [weak self] in self?.handleDirChange() }
        src.setCancelHandler { close(fd) }
        src.resume()
        dirSource = src
        handleDirChange() // pick up any pre-existing frames immediately
    }

    func stop() {
        dirSource?.cancel()
        dirSource = nil
        stopFileWatch()
        dir = nil
        onLatest = nil
    }

    /// A directory entry was added or removed (mflux created the next frame). Emit the newest
    /// finished frame, then attach a watcher to the frame still being written so we can emit it
    /// the instant it completes.
    private func handleDirChange() {
        guard let dir else { return }
        onLatest?(RunnerSupport.latestCompletePNG(in: dir))
        watchFrameInProgress(in: dir)
    }

    private func watchFrameInProgress(in dir: URL) {
        guard let newest = RunnerSupport.newestPNG(in: dir), newest != watchedFile else { return }
        if RunnerSupport.isPNGComplete(at: newest) { return } // already finished; nothing to wait on
        stopFileWatch()
        let fd = open(newest, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend], queue: .main
        )
        src.setEventHandler { [weak self] in self?.handleFrameWrite(path: newest) }
        src.setCancelHandler { close(fd) }
        src.resume()
        fileSource = src
        watchedFile = newest
        // Close the small window between the completeness check above and source registration:
        // the frame may have finished writing in between, with no further write event coming.
        handleFrameWrite(path: newest)
    }

    private func handleFrameWrite(path: String) {
        guard let dir, RunnerSupport.isPNGComplete(at: path) else { return }
        onLatest?(RunnerSupport.latestCompletePNG(in: dir))
        stopFileWatch() // frame done; the next directory event will re-arm for the following frame
    }

    private func stopFileWatch() {
        fileSource?.cancel()
        fileSource = nil
        watchedFile = nil
    }
}
