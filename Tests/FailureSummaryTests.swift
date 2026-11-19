@testable import MLXBits_Image_Studio
import Testing

@Suite("Failed-job summary line")
struct FailureSummaryTests {
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
