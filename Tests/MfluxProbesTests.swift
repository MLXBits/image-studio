import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// The probes ask the interpreter they're given (the bundled one or the Custom
/// Python) and treat "no interpreter" as "unsupported".
struct MfluxProbesTests {
    private func interpreter(printing output: String) throws -> String {
        let url = FakeRuntime.tempDirectory("probe").appendingPathComponent("python")
        try FakeRuntime.writeExecutable("#!/bin/sh\nprintf '\(output)'\n", to: url)
        return url.path
    }

    @Test func capabilityProbesAskTheGivenInterpreter() throws {
        let yes = try interpreter(printing: "1")
        let no = try interpreter(printing: "0")
        #expect(MfluxProbes.supportsBaseModel(python: yes))
        #expect(MfluxProbes.supportsPidDecode(python: yes))
        #expect(!MfluxProbes.supportsBaseModel(python: no))
    }

    @Test func versionComesFromTheInterpreter() throws {
        let python = try interpreter(printing: "0.21.0")
        #expect(MfluxProbes.mfluxVersion(python: python) == "0.21.0")
    }

    /// The cache probe gets the hub folder and one `family=repo` per request,
    /// and its JSON comes back keyed by repo.
    @Test func cacheCompletenessAsksAboutEachRepo() throws {
        let url = FakeRuntime.tempDirectory("probe").appendingPathComponent("python")
        try FakeRuntime.writeExecutable("#!/bin/sh\nprintf '{\"%s %s\": true, \"%s\": false}' \"$3\" \"$4\" \"$5\"\n", to: url)
        let verdicts = MfluxProbes.hfCacheCompleteness(
            python: url.path, script: URL(fileURLWithPath: "/probe.py"), hubDir: URL(fileURLWithPath: "/hub"),
            requests: [("flux.2", "org/a"), ("krea2", "org/b")]
        )
        #expect(verdicts == ["/hub flux.2=org/a": true, "krea2=org/b": false])
    }

    @Test func noInterpreterMeansUnsupported() {
        #expect(!MfluxProbes.supportsBaseModel(python: nil))
        #expect(!MfluxProbes.supportsPidDecode(python: nil))
        #expect(MfluxProbes.mfluxVersion(python: nil) == nil)
    }

    /// A wedged interpreter must not hold the caller (the flux arg builder runs
    /// on the main actor) indefinitely.
    @Test func aHungProbeGivesUpAtItsTimeout() throws {
        let url = FakeRuntime.tempDirectory("probe").appendingPathComponent("python")
        try FakeRuntime.writeExecutable("#!/bin/sh\nexec sleep 30\n", to: url)
        let start = Date()
        #expect(MfluxProbes.runProbe(python: url.path, code: "", timeout: 0.5) == nil)
        #expect(Date().timeIntervalSince(start) < 5)
    }
}
