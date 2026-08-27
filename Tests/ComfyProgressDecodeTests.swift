import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// `ProgressTracker.decode` is the boundary between raw websocket frames and the UI's node/step readout.
/// The regression this defends: ComfyUI sends its frames as text (`.string`), not binary, so a decoder that
/// only handled `.data` silently dropped every `executing`/`progress` message and live progress never reached
/// the status line. These tests pin both shapes down and verify node-order accumulation across frames.
@Suite("ProgressTracker.decode") struct ComfyProgressDecodeTests {
    private typealias Tracker = ComfyUIClient.ProgressTracker

    /// A string websocket frame (the shape your server actually sends) carrying an `executing` message yields a snapshot with the
    /// running node id — this is the case that was silently discarded before the fix.
    @Test func decodesStringExecutingFrame() {
        let json = #"{"type":"executing","data":{"node":"6"}}"#
        var lastNode: String?
        var executed: [String] = []

        let snap = Tracker.decode(Tracker.payloadData(from: .string(json)), lastNodeID: &lastNode, executedNodes: &executed)

        #expect(snap?.nodeID == "6")
        #expect(executed == ["6"])
        #expect(lastNode == "6")
    }

    /// A binary (`.data`) frame must decode identically, so servers that do send raw bytes keep working.
    @Test func decodesDataExecutingFrame() {
        let json = #"{"type":"executing","data":{"node":"6"}}"#
        var lastNode: String?
        var executed: [String] = []

        let snap = Tracker.decode(Tracker.payloadData(from: .data(Data(json.utf8))), lastNodeID: &lastNode, executedNodes: &executed)

        #expect(snap?.nodeID == "6")
        #expect(executed == ["6"])
    }

    /// `progress` frames carry real KSampler step counts and must populate step/totalSteps for the elapsed-clock path.
    @Test func decodesProgressFrameWithStepCounts() {
        let json = #"{"type":"progress","data":{"value":3,"max":28,"node":"6"}}"#
        var lastNode: String?
        var executed: [String] = []

        let snap = Tracker.decode(Tracker.payloadData(from: .string(json)), lastNodeID: &lastNode, executedNodes: &executed)

        #expect(snap?.step == 3)
        #expect(snap?.totalSteps == 28)
        #expect(snap?.nodeID == "6")
    }

    /// Repeated frames for the same node must not duplicate it in `executedNodes`, and new nodes append in first-seen order, so a consumer
    /// can
    /// derive "node X of N" by index.
    @Test func executedNodesAccumulateDistinctInOrder() {
        let frames = [
            #"{"type":"executing","data":{"node":"5"}}"#,
            #"{"type":"progress","data":{"value":1,"max":4,"node":"6"}}"#,
            #"{"type":"executing","data":{"node":"8"}}"#,
            #"{"type":"executing","data":{"node":"9"}}"#,
        ]
        var lastNode: String?
        var executed: [String] = []
        for frame in frames {
            let data = Tracker.payloadData(from: .string(frame))
            _ = Tracker.decode(data, lastNodeID: &lastNode, executedNodes: &executed)
        }

        // 5 -> (progress appends 6) -> 8 -> 9; node "6" seen once via progress, not duplicated.
        #expect(executed == ["5", "6", "8", "9"])
    }

    /// Frames that carry no progress data (status heartbeats, custom-node monitor noise) must yield nil rather than a bogus snapshot.
    @Test func ignoresNonProgressFrames() {
        let frames = [
            #"{"type":"status","data":{"status":{}}}"#,
            #"{"type":"crystools.monitor","data":{"cpu_utilization":2.1}}"#,
        ]
        var lastNode: String?
        var executed: [String] = []
        for frame in frames {
            let data = Tracker.payloadData(from: .string(frame))
            let snap = Tracker.decode(data, lastNodeID: &lastNode, executedNodes: &executed)
            #expect(snap == nil)
        }
    }

    /// A malformed or empty payload must not crash and yields nil.
    @Test func nilAndMalformedPayloadsAreNil() {
        var lastNode: String?
        var executed: [String] = []

        #expect(Tracker.decode(nil, lastNodeID: &lastNode, executedNodes: &executed) == nil)

        let junkData = Tracker.payloadData(from: .string(#"not json"#))
        #expect(Tracker.decode(junkData, lastNodeID: &lastNode, executedNodes: &executed) == nil)
    }
}
