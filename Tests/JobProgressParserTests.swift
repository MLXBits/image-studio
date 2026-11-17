@testable import MLXBits_Image_Studio
import Testing

@Suite("JobProgressParser")
struct JobProgressParserTests {
    @Test func rejectsHuggingFaceFetchingBar() {
        let line = "Fetching 12 files:  25%|██▌       | 3/12 [00:01<00:03,  2.50it/s]"
        #expect(JobProgressParser.parseStep(from: line) == nil)
    }

    @Test func rejectsByteSizeDownloadBar() {
        let line = "model.safetensors:   4%|▍         | 45.2M/1.2G [00:04<01:30, 12.3MB/s]"
        #expect(JobProgressParser.parseStep(from: line) == nil)
        #expect(JobProgressParser.parseStep(from: "45.2M/1.2G [00:04<01:30]") == nil)
        #expect(JobProgressParser.parseStep(from: "3/12 [00:04<01:30, 800kB/s]") == nil)
    }

    @Test func acceptsSecondsPerIterationBar() {
        let line = "  75%|███████▌ | 3/4 [00:05<00:01,  1.62s/it]"
        let step = JobProgressParser.parseStep(from: line)
        #expect(step?.current == 3)
        #expect(step?.total == 4)
        #expect(step?.elapsed == "00:05")
        #expect(step?.remaining == "00:01")
    }

    @Test func acceptsIterationsPerSecondBar() {
        let step = JobProgressParser.parseStep(from: " 50%|█████     | 10/20 [00:04<00:04,  2.41it/s]")
        #expect(step?.current == 10)
        #expect(step?.total == 20)
    }

    @Test func acceptsFirstBarBeforeAnyRate() {
        let step = JobProgressParser.parseStep(from: "  0%|          | 0/4 [00:00<?, ?it/s]")
        #expect(step?.current == 0)
        #expect(step?.total == 4)
        let noRate = JobProgressParser.parseStep(from: "  0%|          | 1/4 [00:01<")
        #expect(noRate?.current == 1)
    }

    @Test func lastCarriageReturnUpdateWins() {
        let log = "1/4 [00:01<00:03, 1.00s/it]\r2/4 [00:02<00:02, 1.00s/it]\r3/4 [00:03<00:01, 1.00s/it]"
        #expect(JobProgressParser.parseStep(from: log)?.current == 3)
    }

    @Test func downloadBarDoesNotMaskEarlierStepBar() {
        let log = "2/4 [00:02<00:02, 1.00s/it]\nFetching 3 files: 1/3 [00:01<00:02, 1.00it/s]"
        #expect(JobProgressParser.parseStep(from: log)?.current == 2)
    }

    @Test func rejectsNonBarCountLine() {
        #expect(JobProgressParser.parseStep(from: "LoRA (336/336 keys matched)") == nil)
    }
}
