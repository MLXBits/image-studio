import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// `formatErrorMessage` is the boundary between a raw `/history/{id}` failure record and the job-facing diagnostic.
/// The regression this defends: ComfyUI reports execution failures (e.g. CUDA OOM) as an "execution_error" entry whose
/// payload is a *dict* embedding every live input tensor of the failing node (~5 MB for one 1920×1088 latent). A decoder
/// that JSON-serializes the whole payload balloons job.log; a poller that never sees `completed == false` hangs until
/// timeout. These tests pin the dict-shape extraction, string passthrough, and unknown-shape fallback down.
@Suite("ComfyUIClient.formatErrorMessage") struct ComfyHistoryFailureDecodeTests {
    /// The observed OOM shape from a live ComfyUI 0.33 box: an "execution_error" kind with a payload dict carrying
    /// exception_type / node_id / node_type / exception_message (plus traceback and input tensors we must NOT serialize).
    @Test func extractsStructuredOOMDiagnostic() {
        let payload: [String: Any] = [
            "prompt_id": "d54c8eff-8281-4322-83da-fc2410517d27",
            "node_id": "KSAMPLER",
            "node_type": "KSampler",
            "executed": ["CLIP_NEG", "EMPTY", "UNET"],
            "exception_message": "CUDA out of memory. Tried to allocate 196.00 MiB. GPU 0 has a total capacity of 31.39 GiB.",
            "exception_type": "torch.OutOfMemoryError",
        ]

        let msg = ComfyUIClient.formatErrorMessage(kind: "execution_error", payload: payload)

        #expect(msg.hasPrefix("torch.OutOfMemoryError"))
        #expect(msg.contains("[node KSAMPLER KSampler]"))
        #expect(msg.contains("CUDA out of memory"))
        // The diagnostic must stay bounded regardless of how large the raw payload's embedded tensors are.
        #expect(msg.count <= 1600)
    }

    /// A plain string payload (older/other server builds that write a bare error string) passes through with its kind prefix,
    /// truncated at the cap so nothing unbounded can reach job.log.
    @Test func stringPayloadPassesThroughBounded() {
        let long = String(repeating: "x", count: 4000)
        let msg = ComfyUIClient.formatErrorMessage(kind: "execution_error", payload: long)
        #expect(msg.hasPrefix("execution_error: "))
        #expect(msg.count <= 1600)
    }

    /// A dict without any recognized fields (future server shape drift) must fall back to a bounded raw slice rather than the full JSON.
    @Test func unrecognizedDictPayloadFallsBackToBoundedSlice() {
        let payload: [String: Any] = ["some_future_field": String(repeating: "y", count: 3000)]
        let msg = ComfyUIClient.formatErrorMessage(kind: "execution_error", payload: payload)
        #expect(msg.hasPrefix("execution_error"))
        #expect(msg.count <= 1600)
    }

    /// An exception_type present but no node_id must not fabricate a "[node …]" segment.
    @Test func missingNodeFieldsOmitNodeSegment() {
        let payload: [String: Any] = ["exception_message": "boom", "exception_type": "ValueError"]
        let msg = ComfyUIClient.formatErrorMessage(kind: "execution_error", payload: payload)
        #expect(msg == "ValueError boom")
    }
}
