import Foundation
import os

/// Memoises an ``MfluxProbes`` probe per interpreter path. The probe spawns a process, so it
/// must not run on every view body evaluation.
nonisolated final class ProbeCache<Value: Sendable>: Sendable {
    private struct State {
        var results: [String: Value] = [:]
        /// Bumped by ``remove(_:)``. A probe already running when its key is
        /// removed returns its answer but doesn't cache it.
        var generations: [String: Int] = [:]
        /// The asynchronous probe running per key, which later callers join.
        var inFlight: [String: Task<Value, Never>] = [:]
    }

    /// One wait on a shared probe: resumed by the probe's answer or by the
    /// waiter's cancellation, whichever comes first.
    private enum Wait {
        case pending
        case waiting(CheckedContinuation<Value?, Never>)
        case finished
    }

    /// `task.value`, or nil as soon as the calling task is cancelled. Awaiting an
    /// unstructured task's value directly ignores the waiter's cancellation, so a
    /// stopped job would sit until the probe ends. The task itself is not
    /// cancelled: other callers may still be waiting on it.
    private static func waitCancellably(for task: Task<Value, Never>) async -> Value? {
        let wait = OSAllocatedUnfairLock(initialState: Wait.pending)
        // Takes the continuation exactly once; later calls find `.finished` and do nothing.
        let finish: @Sendable (Value?) -> Void = { value in
            let continuation: CheckedContinuation<Value?, Never>? = wait.withLock { state in
                defer { state = .finished }
                if case let .waiting(continuation) = state {
                    return continuation
                }
                return nil
            }
            continuation?.resume(returning: value)
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let cancelledAlready: Bool = wait.withLock {
                    guard case .pending = $0 else { return true }
                    $0 = .waiting(continuation)
                    return false
                }
                if cancelledAlready {
                    continuation.resume(returning: nil)
                    return
                }
                Task.detached { await finish(task.value) }
            }
        } onCancel: {
            finish(nil)
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Whether an answer is cached. One it rejects still reaches its callers, and the next ask probes again.
    private let keeps: @Sendable (Value) -> Bool

    init(keeping keeps: @escaping @Sendable (Value) -> Bool = { _ in true }) {
        self.keeps = keeps
    }

    /// The cached answer for `key`, or nil when it hasn't been asked yet or its answer wasn't kept.
    func cached(_ key: String) -> Value? {
        state.withLock { $0.results[key] }
    }

    /// Blocks the caller while `compute` runs. Never call it from the main actor
    /// for a cold key: the probe takes seconds.
    func value(for key: String, compute: () -> Value) -> Value {
        let start: (hit: Value?, generation: Int) = state.withLock {
            ($0.results[key], $0.generations[key, default: 0])
        }
        if let hit = start.hit {
            return hit
        }
        let computed = compute()
        store(computed, for: key, generation: start.generation)
        return computed
    }

    /// Runs `compute` on a background task and suspends until it answers.
    /// Concurrent callers for one key share a single run, so one interpreter
    /// gets one probe process however many jobs and warm-ups ask at once.
    /// A cancelled caller stops waiting at once and gets nil; the probe runs on
    /// for the other callers and still caches its answer, if `keeps` accepts it.
    func value(for key: String, compute: @escaping @Sendable () -> Value) async -> Value? {
        if let hit = cached(key) {
            return hit
        }
        let task: Task<Value, Never> = state.withLock { s in
            // Answered between the check above and here: hand back a finished task.
            if let hit = s.results[key] {
                return Task { hit }
            }
            if let running = s.inFlight[key] {
                return running
            }
            let generation = s.generations[key, default: 0]
            // The task stores its own answer, so it lands even when every waiter has gone.
            let task = Task.detached(priority: .utility) { [self] in
                let computed = compute()
                store(computed, for: key, generation: generation)
                return computed
            }
            s.inFlight[key] = task
            return task
        }
        return await Self.waitCancellably(for: task)
    }

    func remove(_ key: String) {
        state.withLock {
            $0.results[key] = nil
            $0.inFlight[key] = nil
            $0.generations[key, default: 0] += 1
        }
    }

    /// Caches `value` unless ``remove(_:)`` ran since its probe began or `keeps` rejects it.
    private func store(_ value: Value, for key: String, generation: Int) {
        let keep = keeps(value)
        state.withLock {
            guard $0.generations[key, default: 0] == generation else { return }
            if keep {
                $0.results[key] = value
            }
            $0.inFlight[key] = nil
        }
    }
}

// Nonisolated: process probes, callable off the main actor.
/// Questions asked of the interpreter mflux runs on: its mflux version, and
/// whether it accepts options the app sends only when supported. Each probe
/// spawns that interpreter once and is cached by its path for the rest of the
/// launch, so choosing another Custom Python asks again.
nonisolated enum MfluxProbes {
    private static let pidDecodeCache = ProbeCache<Bool>()
    private static let versionCache = ProbeCache<String?>()
    /// Nil is a probe that couldn't answer (timed out or failed to start). It isn't kept, so a
    /// cold `import mflux` that outlives the timeout doesn't drop `--base-model` for the session.
    private static let baseModelCache = ProbeCache<Bool?> { $0 != nil }

    /// Drops every cached answer for `python`, so the next probes ask it again:
    /// mflux may have been installed or upgraded there since.
    static func forget(python: String) {
        versionCache.remove(python)
        pidDecodeCache.remove(python)
        baseModelCache.remove(python)
    }

    /// The version of the `mflux` package importable by `python`, or nil when it
    /// cannot be determined. Asks the interpreter rather than reading a
    /// `dist-info` directory name so editable installs resolve correctly.
    static func mfluxVersion(python: String?) -> String? {
        guard let python else { return nil }
        return versionCache.value(for: python) {
            runProbe(python: python, code: """
            import importlib.metadata as m, sys
            try:
                sys.stdout.write(m.version("mflux"))
            except Exception:
                pass
            """)
        }
    }

    /// Whether the mflux importable by `python` has the PiD pixel-diffusion
    /// decoder (`--pid-decode`). Gates the toggle in the Dimensions section so it
    /// only appears against an mflux that can honour it.
    ///
    /// PiD is unmerged upstream (filipstrand/mflux#490), so this cannot be
    /// inferred from a version number. Probes for the module rather than a console
    /// script: the flag is added to seven existing scripts, so no new script
    /// appears, and asking the interpreter resolves editable installs (whose
    /// `mflux` lives outside site-packages behind a `.pth`) correctly.
    ///
    /// Remove this gate and its call sites once PiD lands in a released mflux.
    static func supportsPidDecode(python: String?) -> Bool {
        guard let python else { return false }
        return pidDecodeCache.value(for: python) {
            runProbe(python: python, code: """
            import importlib.util as u, pathlib, sys
            s = u.find_spec("mflux")
            loc = (s.submodule_search_locations or [None])[0] if s else None
            ok = loc is not None and (pathlib.Path(loc) / "models/common/pid_decoder").is_dir()
            sys.stdout.write("1" if ok else "0")
            """) == "1"
        }
    }

    /// Whether the mflux importable by `python` accepts `--base-model`. Gates the flag in
    /// ``FluxRunnerSpec``'s buildArgs so a pre-option release is never handed an option its
    /// argparse rejects with exit 2.
    ///
    /// Inspects the parser's own option list rather than comparing versions or trial-parsing a
    /// value: package metadata lies on editable installs (a dev checkout reports an old version
    /// while carrying every registry key), no release boundary marks when the option landed, and
    /// this answers exactly what the gate needs — whether sending the flag would be rejected.
    /// Cached per interpreter like ``supportsPidDecode(python:)``: one process spawn per
    /// interpreter per launch. The probe imports mflux (seconds), so it runs on a background
    /// task; concurrent callers for one interpreter share that one run. A cancelled caller
    /// stops waiting at once and gets false, which isn't cached. Neither is a probe that times
    /// out: this job runs without the flag, and the next one asks again.
    static func supportsBaseModel(python: String?) async -> Bool {
        guard let python else { return false }
        let supported = await baseModelCache.value(for: python) {
            runProbe(python: python, code: """
            import sys
            ok = False
            try:
                from mflux.models.flux2.cli import flux2_generate as f
                p = f.build_parser()
                ok = any("--base-model" in (a.option_strings or ()) for a in p._actions)
            except BaseException:
                pass
            sys.stdout.write("1" if ok else "0")
            """).map { $0 == "1" }
        }
        return supported.flatMap(\.self) ?? false
    }

    /// ``supportsBaseModel(python:)``'s cached answer, or nil until that probe has
    /// answered for `python`. Never spawns a process, so the main actor can ask.
    static func cachedSupportsBaseModel(python: String?) -> Bool? {
        guard let python else { return false }
        return baseModelCache.cached(python).flatMap(\.self)
    }

    /// Starts the probes that job argument building depends on for `python`, in
    /// the background, so the first job doesn't wait on them. Called at launch and
    /// whenever the interpreter changes; a probe already cached or running is not
    /// started again.
    static func warmUp(python: String?) {
        guard let python else { return }
        Task.detached(priority: .utility) {
            _ = await supportsBaseModel(python: python)
        }
    }

    /// Which requested repos mflux would load from the Hugging Face cache at `hubDir`
    /// without downloading (#19), keyed by repo ID. Each request names the
    /// ``ModelFamily/id`` whose loader decides. Asks `script` (the bundled
    /// `hf_cache_probe.py`), which calls mflux's own completeness check, so it
    /// follows the links of huggingface_hub 2.x caches and knows which files each
    /// family loads. Not cached: the answer changes as downloads land. Nil when
    /// the probe fails; repos it can't answer for are left out.
    static func hfCacheCompleteness(
        python: String?, script: URL, hubDir: URL, requests: [(family: String, repo: String)]
    ) -> [String: Bool]? {
        guard let python, !requests.isEmpty else { return nil }
        let arguments = [script.path, "--hub", hubDir.path] + requests.map { "\($0.family)=\($0.repo)" }
        guard let out = runProbe(python: python, arguments: arguments),
              let data = out.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String: Bool].self, from: data)
    }

    /// What mflux downloads for each of `names` (`seedvr2-3b`, `seedvr2-7b`): the upstream repo,
    /// the revision mflux pins it to, and the file patterns its weight definition loads. Asks
    /// `script` (the bundled `hf_cache_probe.py --download-spec`) so a download fetches exactly
    /// what the installed mflux will load. Not cached. Nil when the probe fails; names it can't
    /// answer for are left out.
    nonisolated static func downloadSpecs(python: String?, script: URL, names: [String]) -> [String: HFDownloadSpec]? {
        guard let python, !names.isEmpty,
              let out = runProbe(python: python, arguments: [script.path, "--download-spec"] + names),
              let data = out.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String: HFDownloadSpec].self, from: data)
    }

    /// Runs `python -c code` with the toolchain environment and returns its
    /// trimmed stdout, or nil when the process cannot start, writes nothing, or
    /// outlives `timeout`. Callers wait on it (a Flux job awaits the base-model
    /// probe before building its arguments), so a wedged interpreter must not
    /// hold them indefinitely. The 60 s default clears a cold `import mflux` (~25 s even on idle hardware). A
    /// caller whose answer gates a flag should not cache a nil, or one slow import drops that flag
    /// for the rest of the session (see ``supportsBaseModel(python:)``).
    static func runProbe(python: String, code: String, timeout: TimeInterval = 60) -> String? {
        runProbe(python: python, arguments: ["-c", code], timeout: timeout)
    }

    /// Runs `python arguments…`, as ``runProbe(python:code:timeout:)``.
    static func runProbe(python: String, arguments: [String], timeout: TimeInterval = 60) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = arguments
        proc.environment = Toolchain.environment(
            base: ProcessInfo.processInfo.environment, cachesURL: Toolchain.cachesURL
        )
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return nil
        }
        // Terminating the probe closes its end of the pipe, which ends the read below.
        let watchdog = DispatchWorkItem {
            if proc.isRunning {
                proc.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        watchdog.cancel()
        guard proc.terminationReason == .exit else { return nil }
        let out = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }
}
