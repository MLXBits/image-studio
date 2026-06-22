import Foundation
@testable import MLXBits_Image_Studio
import Testing

struct RunnerSupportTests {
    // MARK: - appendLog (carriage-return handling)

    @Test func appendLogPlainText() {
        #expect(RunnerSupport.appendLog("abc", to: "") == "abc")
        #expect(RunnerSupport.appendLog("def", to: "abc") == "abcdef")
    }

    @Test func appendLogCarriageReturnRewindsCurrentLine() {
        // No newline yet: \r clears the whole buffer (tqdm overwriting a single line).
        #expect(RunnerSupport.appendLog("12345\rXY", to: "") == "XY")
    }

    @Test func appendLogCarriageReturnKeepsPriorLines() {
        // \r rewinds only to the start of the last line, preserving completed lines.
        #expect(RunnerSupport.appendLog("line1\nold\rnew", to: "") == "line1\nnew")
    }

    // MARK: - insertBeforeLastLine

    @Test func insertBeforeLastLinePlacesTextAheadOfTrailingLine() {
        #expect(RunnerSupport.insertBeforeLastLine("a\nb", text: "X") == "a\nXb")
    }

    @Test func insertBeforeLastLineWithoutNewlinePrepends() {
        #expect(RunnerSupport.insertBeforeLastLine("abc", text: "X") == "Xabc")
    }

    // MARK: - formatDuration

    @Test func formatDurationSubMinute() {
        #expect(RunnerSupport.formatDuration(5) == "5.0s")
        #expect(RunnerSupport.formatDuration(0.5) == "0.5s")
    }

    @Test func formatDurationOverMinute() {
        #expect(RunnerSupport.formatDuration(65) == "1m 5s")
        #expect(RunnerSupport.formatDuration(125) == "2m 5s")
    }

    // MARK: - expandedPaths

    @Test func expandedPathsAppendsSeedSuffix() {
        let paths = RunnerSupport.expandedPaths(from: "/tmp/img_1.png", seeds: [1, 2])
        #expect(paths.count == 2)
        #expect(paths[0].seed == 1)
        #expect(paths[0].path == "/tmp/img_1_seed_1.png")
        #expect(paths[1].path == "/tmp/img_1_seed_2.png")
    }

    // MARK: - isPNGComplete

    @Test func isPNGCompleteDetectsIENDCRC() throws {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("complete-\(UUID().uuidString).png")
        // Twelve+ bytes ending in the IEND chunk CRC (AE 42 60 82).
        var bytes: [UInt8] = Array(repeating: 0, count: 12)
        bytes[8] = 0xAE; bytes[9] = 0x42; bytes[10] = 0x60; bytes[11] = 0x82
        try Data(bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(RunnerSupport.isPNGComplete(at: url.path))
    }

    @Test func isPNGCompleteRejectsTruncatedFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("short-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E]).write(to: url) // < 12 bytes
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!RunnerSupport.isPNGComplete(at: url.path))
    }

    @Test func isPNGCompleteRejectsWrongTrailer() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bad-\(UUID().uuidString).png")
        try Data(Array(repeating: UInt8(0), count: 16)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!RunnerSupport.isPNGComplete(at: url.path))
    }

    @Test func isPNGCompleteMissingFileIsFalse() {
        #expect(!RunnerSupport.isPNGComplete(at: "/nonexistent/\(UUID().uuidString).png"))
    }
}
