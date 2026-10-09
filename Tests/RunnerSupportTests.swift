import Foundation
@testable import MLXBits_Image_Studio
import Testing

struct RunnerSupportTests {
    private static let stepDir = "/Caches/stepwise/job"

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

    // MARK: - appendLog (stepwise save lines, issue #23)

    @Test func appendLogDropsStepwiseSaveLinesSoTheBarRewinds() {
        let chunk = "\r  0%|          | 0/4 [00:00<?, ?it/s]"
            + "INFO: Image saved successfully at: \(Self.stepDir)/seed_1_step1of4.png\n"
            + "INFO: Metadata embedded successfully at: \(Self.stepDir)/seed_1_step1of4.png\n"
            + "\r 25%|██▌       | 1/4 [00:04<00:13,  4.42s/it]"
        let log = RunnerSupport.appendLog(chunk, to: "▸ Loading model...\n", stepwiseDir: Self.stepDir)
        #expect(log == "▸ Loading model...\n 25%|██▌       | 1/4 [00:04<00:13,  4.42s/it]")
    }

    @Test func appendLogDropsStepwiseSaveLineSplitAcrossChunks() {
        let bar = " 50%|█████     | 2/4 [00:08<00:08,  4.40s/it]"
        var log = RunnerSupport.appendLog(bar + "INFO: Image saved succ", to: "", stepwiseDir: Self.stepDir)
        log = RunnerSupport.appendLog("essfully at: \(Self.stepDir)/seed_1_composite.png", to: log, stepwiseDir: Self.stepDir)
        log = RunnerSupport.appendLog("\n", to: log, stepwiseDir: Self.stepDir)
        #expect(log == bar)
    }

    @Test func appendLogKeepsAWarningThatQuotesAStepwiseSaveLine() {
        let chunk = "WARNING: unexpected INFO: Image saved successfully at: \(Self.stepDir)/x.png\n"
        #expect(RunnerSupport.appendLog(chunk, to: "", stepwiseDir: Self.stepDir) == chunk)
    }

    @Test func appendLogKeepsFinalImageAndOtherLines() {
        let chunk = "INFO: Image saved successfully at: /Pictures/out.png\n"
            + "INFO: Metadata embedded successfully at: /Pictures/out.png\n"
            + "WARNING: something in \(Self.stepDir)/x.png\n"
            + "INFO: Image saved successfully at: \(Self.stepDir)-other/x.png\n"
        #expect(RunnerSupport.appendLog(chunk, to: "", stepwiseDir: Self.stepDir) == chunk)
    }

    @Test func appendLogWithoutStepwiseDirKeepsSaveLines() {
        let chunk = "INFO: Image saved successfully at: \(Self.stepDir)/seed_1_step1of4.png\n"
        #expect(RunnerSupport.appendLog(chunk, to: "") == chunk)
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

    // MARK: - imagesLanded (support nudge count)

    /// A single image sets only `outputPath`; a batch sets `outputPaths` to
    /// what actually landed.
    @Test func imagesLandedCountsWhatTheJobSaved() {
        #expect(RunnerSupport.imagesLanded(outputPath: "/Lib/a.png", outputPaths: []) == 1)
        #expect(RunnerSupport.imagesLanded(outputPath: "/Lib/a.png", outputPaths: ["/Lib/a.png", "/Lib/b.png"]) == 2)
        #expect(RunnerSupport.imagesLanded(outputPath: nil, outputPaths: []) == 0)
    }

    // MARK: - noImageReason (exit 0 without an image)

    /// mflux logs a failed save and exits 0; the job fails with that error.
    @Test func noImageReasonUsesTheLastErrorLine() {
        let log = """
        ERROR: first problem
        100%|██████████| 4/4
        ERROR: Error saving image: [Errno 1] Operation not permitted: '/Lib/a.png'
        ▸ Decoding image...
        """
        #expect(RunnerSupport.noImageReason(log: log, destination: "/Lib/a.png")
            == "Error saving image: [Errno 1] Operation not permitted: '/Lib/a.png'")
    }

    @Test func noImageReasonFindsAPrefixedErrorLine() {
        let log = "12:00:01 ERROR: Error saving image: [Errno 28] No space left on device\n"
        #expect(RunnerSupport.noImageReason(log: log, destination: "/Lib/a.png")
            == "Error saving image: [Errno 28] No space left on device")
    }

    @Test func noImageReasonNamesThePathWhenNothingWasLogged() {
        #expect(RunnerSupport.noImageReason(log: "▸ Decoding image...\n", destination: "/Lib/a.png")
            == "mflux reported success but wrote no image to /Lib/a.png")
    }
}
