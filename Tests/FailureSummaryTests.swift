@testable import MLXBits_Image_Studio
import Testing

@Suite("Failed-job summary line")
struct FailureSummaryTests {
    /// The tail of a Krea 2 Q4 load on a 24 GB Mac mini.
    private static let metalOutOfMemoryLog = [
        #"  File "/Applications/MLXBits Image Studio.app/.../mflux/models/krea2/krea2_initializer.py", line 39"#,
        "    mx.eval(model)",
        "RuntimeError: [METAL] Command buffer execution failed: Insufficient Memory "
            + "(00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory).",
        "⚠️  mflux-generate-krea2 exited with status 1.",
    ].joined(separator: "\n")

    @Test func metalOutOfMemorySaysSoInWords() {
        #expect(FailureSummary.isOutOfMemory(message: "exited with code 1", log: Self.metalOutOfMemoryLog))
        #expect(FailureSummary.line(message: "exited with code 1", log: Self.metalOutOfMemoryLog)
            == FailureSummary.outOfMemoryLine)
    }

    @Test func mlxRefusedAllocationIsOutOfMemory() {
        let log = "RuntimeError: [metal::malloc] Attempting to allocate 40000000000 bytes which is greater than "
            + "the maximum allowed buffer size of 22906503168 bytes."
        #expect(FailureSummary.isOutOfMemory(message: "", log: log))
    }

    @Test func aRemoteCUDAOutOfMemoryKeepsItsOwnLine() {
        // A ComfyUI server's GPU, not this Mac: no local-memory advice.
        let log = "torch.OutOfMemoryError: CUDA out of memory"
        #expect(!FailureSummary.isOutOfMemory(message: "x", log: log))
        #expect(FailureSummary.line(message: "x", log: log) == log)
    }

    @Test func picksTheLastExceptionLineOfATraceback() {
        let log = """
        Traceback (most recent call last):
          File "run.py", line 3, in <module>
            main()
        KeyError: 'a'

        During handling of the above exception, another exception occurred:

        torch.OutOfMemoryError: CUDA out of memory
        """
        #expect(FailureSummary.line(message: "exited with code 1", log: log) == "torch.OutOfMemoryError: CUDA out of memory")
    }

    @Test func anUnprefixedExceptionCounts() {
        #expect(FailureSummary
            .line(message: "exited", log: "Exception: model load failed\nWorker exited") == "Exception: model load failed")
    }

    @Test func aBareExceptionNameCounts() {
        #expect(FailureSummary.line(message: "x", log: "step 3\nKeyboardInterrupt\n") == "KeyboardInterrupt")
    }

    @Test func proseMentioningAnErrorIsNotAnExceptionLine() {
        let log = "Loading model\nThis is an Error in the config"
        #expect(FailureSummary.line(message: "Model not found", log: log) == "Model not found")
    }

    @Test func fallsBackToTheMessagesFirstLine() {
        #expect(FailureSummary.line(message: "  Out of memory\nmore detail", log: "") == "Out of memory")
    }

    @Test func fallsBackToTheLastLogLineWithoutAMessage() {
        #expect(FailureSummary.line(message: "", log: "first\nlast line\n\n") == "last line")
    }

    @Test func emptyEverythingStillSaysSomething() {
        #expect(FailureSummary.line(message: "", log: "") == "Unknown error")
    }

    @Test func detectsAGatedRepoInEitherText() {
        #expect(FailureSummary.isGatedRepo(message: "", log: "huggingface_hub.errors.GatedRepoError: 401"))
        #expect(FailureSummary.isGatedRepo(message: "403 Client Error: Forbidden", log: ""))
        #expect(!FailureSummary.isGatedRepo(message: "exited with code 1", log: "ValueError: bad size"))
    }
}
