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

    /// Center-crops the image at `path` to a 200×200 JPEG thumbnail.
    static func loadThumbnail(at path: String) -> Data? {
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        let imgSize = img.size
        guard imgSize.width > 0, imgSize.height > 0 else { return nil }
        let side = min(imgSize.width, imgSize.height)
        let srcRect = NSRect(
            x: (imgSize.width - side) / 2,
            y: (imgSize.height - side) / 2,
            width: side, height: side
        )
        let size = CGSize(width: 200, height: 200)
        let thumb = NSImage(size: size)
        thumb.lockFocus()
        img.draw(in: NSRect(origin: .zero, size: size), from: srcRect, operation: .copy, fraction: 1.0)
        thumb.unlockFocus()
        guard let tiff = thumb.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }

    /// Newest complete PNG in `dir`, ignoring composites and dotfiles. Used to surface
    /// the latest stepwise preview.
    static func latestCompletePNG(in dir: URL) -> String? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey]
        ) else { return nil }
        return files
            .filter {
                $0.pathExtension.lowercased() == "png"
                    && !$0.lastPathComponent.contains("composite")
                    && !$0.lastPathComponent.hasPrefix(".")
                    && isPNGComplete(at: $0.path)
            }
            .max {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return a < b
            }?
            .path
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
                if let nl = result.lastIndex(of: "\n") {
                    result = String(result[...nl])
                } else {
                    result = ""
                }
            } else {
                result.append(char)
            }
        }
        return result
    }
}

/// Watches a stepwise-output directory and reports the newest complete PNG whenever
/// the directory changes. Owns the underlying `DispatchSource` so a runner just keeps
/// one instance and calls ``start(dir:onLatest:)`` / ``stop()``.
@MainActor
final class StepwiseWatcher {
    private var source: (any DispatchSourceProtocol)?

    /// Starts watching `dir`. `onLatest` is invoked with the newest complete PNG path
    /// (or nil) immediately and on every subsequent directory write.
    func start(dir: URL, onLatest: @escaping (String?) -> Void) {
        stop()
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main
        )
        src.setEventHandler { onLatest(RunnerSupport.latestCompletePNG(in: dir)) }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        onLatest(RunnerSupport.latestCompletePNG(in: dir)) // check immediately for pre-existing files
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}
