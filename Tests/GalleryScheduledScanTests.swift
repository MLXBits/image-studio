import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// Landings rescan the gallery through ``GalleryStore/scheduleScan(outputDir:delay:)``,
/// so images that land together cost one scan, not one each.
@Suite("Gallery scheduled scan")
struct GalleryScheduledScanTests {
    private func tempDir(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("GalleryScheduledScanTests-\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    /// An output folder holding one image file named `file`.
    private func library(with file: String) throws -> URL {
        let dir = tempDir("library")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0]).write(to: dir.appendingPathComponent(file))
        return dir
    }

    private func gallery() -> GalleryStore {
        let gallery = GalleryStore()
        gallery.activate(thumbnailDirectory: tempDir("thumbs"))
        return gallery
    }

    /// File names, not paths: the scan reports the temp folder under `/private`.
    private func fileNames(_ gallery: GalleryStore) -> [String] {
        gallery.items.map { URL(fileURLWithPath: $0.path).lastPathComponent }
    }

    private func waitForScan(until done: () -> Bool) async throws {
        for _ in 0 ..< 200 where !done() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The default delay is 250 ms. A sleep never ends early, so the scan's result
    /// can't appear sooner, however slow the machine; a shorter delay would.
    @Test func aScheduledScanWaitsForTheDefaultDelay() async throws {
        let dir = try library(with: "a.png")
        let gallery = gallery()
        let start = ContinuousClock.now

        gallery.scheduleScan(outputDir: dir.path)
        try await waitForScan { !gallery.items.isEmpty }

        #expect(ContinuousClock.now - start >= .milliseconds(250))
        #expect(fileNames(gallery) == ["a.png"])
    }

    /// A profile switch (or a folder change) inside the delay must not load the
    /// previous library into the new one.
    @Test func activatingCancelsAScheduledScan() async throws {
        let dir = try library(with: "a.png")
        let gallery = gallery()

        gallery.scheduleScan(outputDir: dir.path, delay: .milliseconds(20))
        gallery.activate(thumbnailDirectory: tempDir("thumbs"))
        try await Task.sleep(for: .milliseconds(200))

        #expect(gallery.items.isEmpty)
    }

    /// If the first schedule still ran, it would scan the first folder after the
    /// second scan finished and replace its items.
    @Test func reschedulingReplacesThePendingScan() async throws {
        let first = try library(with: "first.png")
        let second = try library(with: "second.png")
        let gallery = gallery()

        gallery.scheduleScan(outputDir: first.path, delay: .milliseconds(100))
        gallery.scheduleScan(outputDir: second.path, delay: .milliseconds(10))
        try await waitForScan { !gallery.items.isEmpty }
        try await Task.sleep(for: .milliseconds(250))

        #expect(fileNames(gallery) == ["second.png"])
    }
}
