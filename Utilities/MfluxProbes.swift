import Foundation

// Nonisolated: process probes, callable off the main actor.
/// Questions asked of the interpreter mflux runs on: its mflux version, and
/// whether it accepts options the app sends only when supported. Each probe
/// spawns that interpreter once and is cached by its path for the rest of the
/// launch, so choosing another Custom Python asks again.
nonisolated enum MfluxProbes {
    /// Memoises a probe per interpreter path. The probe spawns a process, so it
    /// must not run on every view body evaluation.
    private final class ProbeCache<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [String: Value] = [:]
        /// Bumped by ``remove(_:)``. A probe already running when its key is
        /// removed returns its answer but doesn't cache it.
        private var generations: [String: Int] = [:]

        func value(for key: String, compute: () -> Value) -> Value {
            lock.lock()
            if let hit = results[key] {
                lock.unlock()
                return hit
            }
            let generation = generations[key, default: 0]
            lock.unlock()
            let computed = compute()
            lock.lock()
            if generations[key, default: 0] == generation {
                results[key] = computed
            }
            lock.unlock()
            return computed
        }

        func remove(_ key: String) {
            lock.lock()
            results[key] = nil
            generations[key, default: 0] += 1
            lock.unlock()
        }
    }

    private static let pidDecodeCache = ProbeCache<Bool>()
    private static let versionCache = ProbeCache<String?>()
    private static let baseModelCache = ProbeCache<Bool>()

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
    /// interpreter per launch.
    static func supportsBaseModel(python: String?) -> Bool {
        guard let python else { return false }
        return baseModelCache.value(for: python) {
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
            """) == "1"
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

    /// Runs `python -c code` with the toolchain environment and returns its
    /// trimmed stdout, or nil when the process cannot start, writes nothing, or
    /// outlives `timeout`. Some callers wait on the main actor (the Flux argument
    /// builder), so a wedged interpreter must not hold them indefinitely.
    static func runProbe(python: String, code: String, timeout: TimeInterval = 30) -> String? {
        runProbe(python: python, arguments: ["-c", code], timeout: timeout)
    }

    /// Runs `python arguments…`, as ``runProbe(python:code:timeout:)``.
    static func runProbe(python: String, arguments: [String], timeout: TimeInterval = 30) -> String? {
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
