@testable import MLXBits_Image_Studio
import Testing

struct ComfyClientRobustnessTests {
    @Test func `multipart filename drops path and unsafe characters`() {
        #expect(ComfyUIClient.sanitizedMultipartFilename("/tmp/a/b.png") == "b.png")
        #expect(ComfyUIClient.sanitizedMultipartFilename("/tmp/we\"ird\\na\rme\n.png") == "we_ird_na_me_.png")
        #expect(ComfyUIClient.sanitizedMultipartFilename("/tmp/a\r\n.png") == "a__.png")
    }

    @Test func `refresh skips only the same in-flight URL`() {
        #expect(!ComfyModelStore.shouldStartFetch(requested: "http://a:8188", inFlight: "http://a:8188"))
        #expect(ComfyModelStore.shouldStartFetch(requested: "http://b:8188", inFlight: "http://a:8188"))
        #expect(ComfyModelStore.shouldStartFetch(requested: "http://a:8188", inFlight: nil))
    }
}
