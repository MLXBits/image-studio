import Foundation
@testable import MLXBits_Image_Studio
import os
import Testing

/// The probes ask the interpreter they're given (the bundled one or the Custom
/// Python) and treat "no interpreter" as "unsupported".
struct MfluxProbesTests {
    private func interpreter(printing output: String) throws -> String {
        let url = FakeRuntime.tempDirectory("probe").appendingPathComponent("python")
        try FakeRuntime.writeExecutable("#!/bin/sh\nprintf '\(output)'\n", to: url)
        return url.path
    }

    @Test func downloadSpecsDecodeTheProbesAnswer() throws {
        let json = #"{"seedvr2-7b": {"repo": "numz/SeedVR2_comfyUI", "revision": "rev123", "#
            + #""include": ["seedvr2_ema_7b_fp16.safetensors", "ema_vae_fp16.safetensors"]}}"#
        let script = FakeRuntime.tempDirectory("probe").appendingPathComponent("hf_cache_probe.py")
        let specs = try MfluxProbes.downloadSpecs(
            python: interpreter(printing: json), script: script, names: ["seedvr2-7b"]
        )
        #expect(specs?["seedvr2-7b"] == HFDownloadSpec(
            repo: "numz/SeedVR2_comfyUI", revision: "rev123",
            include: ["seedvr2_ema_7b_fp16.safetensors", "ema_vae_fp16.safetensors"]
        ))
        let failing = FakeRuntime.tempDirectory("probe").appendingPathComponent("python")
        try FakeRuntime.writeExecutable("#!/bin/sh\nexit 1\n", to: failing)
        #expect(MfluxProbes.downloadSpecs(python: failing.path, script: script, names: ["seedvr2-7b"]) == nil)
        #expect(MfluxProbes.downloadSpecs(python: nil, script: script, names: ["seedvr2-7b"]) == nil)
    }

    @Test func capabilityProbesAskTheGivenInterpreter() async throws {
        let yes = try interpreter(printing: "1")
        let no = try interpreter(printing: "0")
        #expect(await MfluxProbes.supportsBaseModel(python: yes))
        #expect(MfluxProbes.supportsPidDecode(python: yes))
        #expect(await !MfluxProbes.supportsBaseModel(python: no))
    }

    /// The Flux argument builder reads the base-model answer from the cache on the
    /// main actor, so asking must never spawn the interpreter.
    @Test func cachedBaseModelAnswerNeverProbes() async throws {
        let yes = try interpreter(printing: "1")
        #expect(MfluxProbes.cachedSupportsBaseModel(python: yes) == nil)
        #expect(await MfluxProbes.supportsBaseModel(python: yes))
        #expect(MfluxProbes.cachedSupportsBaseModel(python: yes) == true)
        #expect(MfluxProbes.cachedSupportsBaseModel(python: nil) == false)
    }

    /// A Flux job awaits the probe before its arguments are built and uses the answer it got
    /// directly: with no answer yet (nil) it leaves the flag off, and once the run captured the
    /// answer the builder passes it through. The App Store flavor ignores the Custom Python
    /// (spec §3), so the fake interpreter can't be installed there; CI tests the DMG scheme.
    @Test(.enabled(if: !BuildFlavor.isAppStore))
    func fluxArgsUseTheProbeTheJobAwaited() async throws {
        let settings = AppSettings()
        settings.suspendPersistence()
        let python = try interpreter(printing: "1")
        settings.customPythonPath = python
        let job = FluxJob(model: .custom, customModelRepo: "org/fine-tune")
        #expect(FluxRunnerSpec.baseModelArgs(base: .flux2Klein9B, baseModelSupported: nil).isEmpty)
        let supported = await FluxRunnerSpec.prepareArgs(job: job, settings: settings, python: python)
        #expect(supported == true)
        #expect(FluxRunnerSpec.baseModelArgs(base: .flux2Klein9B, baseModelSupported: supported)
            == ["--base-model", FluxModelVariant.flux2Klein9B.mfluxModelID])
    }

    /// A probe with no answer (it timed out, or wrote nothing) leaves `--base-model` off for
    /// that job only. It isn't cached, so the next job asks again.
    @Test func aBaseModelProbeWithNoAnswerIsAskedAgain() async throws {
        let url = FakeRuntime.tempDirectory("probe").appendingPathComponent("python")
        let answer = url.deletingLastPathComponent().appendingPathComponent("answer")
        try FakeRuntime.writeExecutable("#!/bin/sh\n[ -f '\(answer.path)' ] && printf 1\n", to: url)
        #expect(await !MfluxProbes.supportsBaseModel(python: url.path))
        #expect(MfluxProbes.cachedSupportsBaseModel(python: url.path) == nil)
        try Data().write(to: answer)
        #expect(await MfluxProbes.supportsBaseModel(python: url.path))
    }

    /// Changing the interpreter asks the new one: answers are keyed by its path.
    @Test func baseModelAnswerIsKeyedByInterpreter() async throws {
        let yes = try interpreter(printing: "1")
        let no = try interpreter(printing: "0")
        #expect(await MfluxProbes.supportsBaseModel(python: yes))
        #expect(MfluxProbes.cachedSupportsBaseModel(python: no) == nil)
        #expect(await !MfluxProbes.supportsBaseModel(python: no))
        #expect(MfluxProbes.cachedSupportsBaseModel(python: yes) == true)
    }

    @Test func versionComesFromTheInterpreter() throws {
        let python = try interpreter(printing: "0.21.0")
        #expect(MfluxProbes.mfluxVersion(python: python) == "0.21.0")
    }

    /// "No mflux" is cached for the launch, so installing mflux into that Python
    /// shows only once Settings forgets the answer and asks again.
    @Test func forgettingAnInterpreterAsksItAgain() throws {
        let dir = FakeRuntime.tempDirectory("probe")
        let answer = dir.appendingPathComponent("version")
        let python = dir.appendingPathComponent("python")
        try FakeRuntime.writeExecutable("#!/bin/sh\ncat '\(answer.path)' 2>/dev/null\n", to: python)
        #expect(MfluxProbes.mfluxVersion(python: python.path) == nil)
        try Data("0.21.0".utf8).write(to: answer)
        #expect(MfluxProbes.mfluxVersion(python: python.path) == nil)
        MfluxProbes.forget(python: python.path)
        #expect(MfluxProbes.mfluxVersion(python: python.path) == "0.21.0")
    }

    /// A probe that was already running when its answer was forgotten mustn't
    /// put that old answer back in the cache.
    @Test func aProbeRunningAcrossForgetDoesNotCacheItsAnswer() async throws {
        let dir = FakeRuntime.tempDirectory("probe")
        let answer = dir.appendingPathComponent("version")
        let python = dir.appendingPathComponent("python")
        // Reads the answer at once, then answers 0.6 s later.
        try FakeRuntime.writeExecutable(
            "#!/bin/sh\nv=$(cat '\(answer.path)')\nsleep 0.6\nprintf '%s' \"$v\"\n", to: python
        )
        try Data("0.20.0".utf8).write(to: answer)
        let path = python.path
        let running = Task.detached { MfluxProbes.mfluxVersion(python: path) }
        try await Task.sleep(nanoseconds: 200_000_000)
        try Data("0.21.0".utf8).write(to: answer)
        MfluxProbes.forget(python: path)
        #expect(await running.value == "0.20.0")
        #expect(MfluxProbes.mfluxVersion(python: path) == "0.21.0")
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

    @Test func noInterpreterMeansUnsupported() async {
        #expect(await !MfluxProbes.supportsBaseModel(python: nil))
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

/// The probe cache behind ``MfluxProbes/supportsBaseModel(python:)``, driven by an
/// injected probe so no interpreter runs.
struct ProbeCacheTests {
    /// A probe that counts its runs and holds each one until released.
    nonisolated private final class GatedProbe: Sendable {
        private let runs = OSAllocatedUnfairLock(initialState: 0)
        private let gate = DispatchSemaphore(value: 0)

        var runCount: Int {
            runs.withLock { $0 }
        }

        func run() -> Int {
            let run = runs.withLock {
                $0 += 1
                return $0
            }
            gate.wait()
            return run
        }

        func release(_ count: Int) {
            for _ in 0 ..< count {
                gate.signal()
            }
        }

        /// Suspends until the probe has started `count` runs.
        func waitForRuns(_ count: Int) async throws {
            while runCount < count {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
    }

    @Test func concurrentAsksForOneInterpreterShareOneProbe() async throws {
        let cache = ProbeCache<Int>()
        let probe = GatedProbe()
        let first = Task { await cache.value(for: "/py") { probe.run() } }
        try await probe.waitForRuns(1)
        let joiners = (0 ..< 4).map { _ in Task { await cache.value(for: "/py") { probe.run() } } }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(cache.cached("/py") == nil)
        probe.release(5)
        #expect(await first.value == 1)
        for joiner in joiners {
            #expect(await joiner.value == 1)
        }
        #expect(probe.runCount == 1)
        #expect(cache.cached("/py") == 1)
    }

    /// A stopped job stops waiting at once, while the shared probe runs on and
    /// still answers, and caches for, the callers that remain.
    @Test func aCancelledWaiterLeavesAtOnceAndTheProbeRunsOn() async throws {
        let cache = ProbeCache<Int>()
        let probe = GatedProbe()
        let stopped = Task { await cache.value(for: "/py") { probe.run() } }
        try await probe.waitForRuns(1)
        let staying = Task { await cache.value(for: "/py") { probe.run() } }
        stopped.cancel()
        #expect(await stopped.value == nil)
        #expect(cache.cached("/py") == nil)
        probe.release(1)
        #expect(await staying.value == 1)
        #expect(probe.runCount == 1)
        #expect(cache.cached("/py") == 1)
    }

    /// Cancelled before it starts waiting: returns nil without hanging.
    @Test func anAlreadyCancelledWaiterReturnsAtOnce() async {
        let cache = ProbeCache<Int>()
        let probe = GatedProbe()
        let waiter = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await cache.value(for: "/py") { probe.run() }
        }
        #expect(await waiter.value == nil)
        probe.release(1)
    }

    @Test func eachInterpreterGetsItsOwnProbe() async {
        let cache = ProbeCache<String>()
        #expect(await cache.value(for: "/a") { "a" } == "a")
        #expect(await cache.value(for: "/b") { "b" } == "b")
        #expect(cache.cached("/a") == "a")
        #expect(cache.cached("/b") == "b")
    }

    /// An answer the cache is told not to keep (a probe that timed out) reaches its
    /// caller but isn't cached, so the next ask probes again.
    @Test func anAnswerItDoesNotKeepIsAskedAgain() async {
        let cache = ProbeCache<Int?> { $0 != nil }
        #expect(await cache.value(for: "/py") { nil } == .some(nil))
        #expect(cache.cached("/py") == nil)
        #expect(await cache.value(for: "/py") { 1 } == 1)
        #expect(cache.cached("/py") == 1)
    }

    /// Forgetting while a probe runs: that run still answers its callers, but its
    /// answer isn't cached, and the next ask starts a fresh probe.
    @Test func forgettingDuringAProbeAsksAgain() async throws {
        let cache = ProbeCache<Int>()
        let probe = GatedProbe()
        let stale = Task { await cache.value(for: "/py") { probe.run() } }
        try await probe.waitForRuns(1)
        cache.remove("/py")
        let fresh = Task { await cache.value(for: "/py") { probe.run() } }
        try await probe.waitForRuns(2)
        probe.release(2)
        #expect(await stale.value == 1)
        #expect(await fresh.value == 2)
        #expect(cache.cached("/py") == 2)
    }
}
