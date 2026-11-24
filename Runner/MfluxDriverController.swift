import Foundation

/// Owns the warm-model driver process (`Resources/mflux_driver.py`) and the
/// model-management policy around it: opportunistic load on first job,
/// idle-timeout eviction, proactive eviction on model switches, manual eject,
/// and auto text-encoder policy from measured peak memory.
///
/// The driver runs on the toolchain's mflux interpreter (the bundled runtime,
/// or the DMG's Custom Python) and speaks NDJSON over stdio:
/// protocol events on stdout, mflux's own output on stderr (routed into the
/// active job's log via ``onLog``). Any startup or handshake failure marks
/// the controller unavailable and jobs fall back to the one-shot CLI path.
@Observable
@MainActor
final class MfluxDriverController {
    enum Availability: Equatable {
        case unknown
        case available
        case unavailable(String)
    }

    // MARK: - Static helpers

    /// Combined chunk stream for one pipe (same pattern as
    /// ``RunnerSupport/outputStream(for:)`` but per-pipe).
    nonisolated private static func chunkStream(for pipe: Pipe) -> AsyncStream<String> {
        TextChunkDecoder.stream(reading: pipe)
    }

    private(set) var availability: Availability = .unknown
    /// Fingerprint of the resident model, or nil when nothing is loaded.
    private(set) var loadedFingerprint: String?
    /// ``ModelSelection/key`` of the resident model, for the model button's halo and switch eviction.
    private(set) var loadedSelectionKey: String?
    /// ``ModelSelection/key`` of the model being loaded, or nil when no load is in progress.
    private(set) var loadingSelectionKey: String?
    private(set) var loadedMemoryGB: Double?
    private(set) var isGenerating = false
    /// True once a cooperative cancel has been asked for and the driver hasn't
    /// settled the run yet. Drives the Stop → Force Stop button state.
    private(set) var isStopping = false

    /// Receives driver stderr chunks (mflux prints, download bars) so the
    /// active job's log matches what the CLI path would show.
    var onLog: ((String) -> Void)?

    private weak var settings: AppSettings?
    private var process: Process?
    /// The interpreter the running (or last attempted) driver started on. A
    /// different one in the toolchain means the Custom Python changed.
    private(set) var interpreter: String?
    private var stdinHandle: FileHandle?
    private var stdoutTail = ""
    private var handshake: CheckedContinuation<Bool, Never>?
    private var jobEventHandler: ((DriverEvent) -> Void)?
    /// Resolver for the in-flight `run(request:)` continuation, so a hard
    /// cancel (or crash) can settle it without a driver event.
    private var finishRun: ((DriverRunResult) -> Void)?
    /// Set when a run is intentionally ended (`hardKill`, or a Stop-write failure) so
    /// `processDied` reports it as cancelled rather than a crash and stays available.
    private var intentionalKill = false
    /// True between the driver's `phase: denoise` and `phase: decode` events —
    /// the only stretch where the driver polls the cancel flag.
    private var inDenoise = false
    /// `id` of the in-flight request, so a cancel names its job and a watchdog
    /// can't fire onto a later one.
    private var runID: String?
    private var cancelWatchdog: Task<Void, Never>?
    private var lastProgressAt: Date?
    /// Most recent gap between `progress` events, used to size the watchdog
    /// grace — a 4K Ideogram step dwarfs a 512px FLUX one.
    private var lastStepInterval: TimeInterval?
    private var idleTask: Task<Void, Never>?
    private let switchEviction: SwitchEviction
    /// Peak MLX memory (GB) reported by the last completed job; drives the
    /// `auto` text-encoder policy.
    private var lastPeakGB: Double?
    /// True while a teardown (Stop write failed, hard kill, interpreter switch) is
    /// in flight until the process exits; ``ensureRunning()`` waits out the exit first.
    private var isTearingDown = false
    /// Continuations from ``ensureRunning()`` awaiting the teardown's exit; resumed by ``processDied(_:)``.
    private var teardownResolvers: [CheckedContinuation<Void, Never>] = []

    var isLoaded: Bool {
        loadedFingerprint != nil
    }

    var isRunning: Bool {
        process?.isRunning == true
    }

    init(settings: AppSettings, switchEvictionDelay: Duration = .seconds(3)) {
        self.settings = settings
        switchEviction = SwitchEviction(delay: switchEvictionDelay)
    }

    // MARK: - Lifecycle

    /// Starts the driver (if needed) and completes the hello/ready handshake. Returns false —
    /// without throwing — when the driver can't be used, so callers fall back to the CLI.
    func ensureRunning() async -> Bool {
        // A changed Custom Python retires the current driver, and re-arms one
        // that failed on the old interpreter: the next job must run on the new one.
        let wanted = try? settings?.toolchain.mfluxInterpreter()
        if wanted != interpreter {
            retire()
            availability = .unknown
        }
        // A teardown is in flight and the dying process is still resident until it exits.
        // Wait for the exit so the one-shot fallback can't load a model while the warm
        // driver still has one resident, then fall back as usual.
        if isTearingDown {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                teardownResolvers.append(cont)
            }
            return false
        }
        if case .unavailable = availability {
            return false
        }
        if isRunning {
            return true
        }
        return await start()
    }

    /// Re-arms a controller previously marked unavailable (e.g. after the
    /// user fixes the binary directory or toggles the setting).
    func resetAvailability() {
        if case .unavailable = availability, process?.isRunning != true {
            availability = .unknown
        }
    }

    /// Stops the driver now, for a restart on another interpreter; the termination
    /// callback that follows is ignored because `process` no longer points at it.
    /// Skipped while a teardown is in flight, so it doesn't clear the run's state.
    private func retire() {
        guard let proc = process, !isTearingDown else { return }
        processDied(proc)
        proc.terminate()
    }

    private func start() async -> Bool {
        guard let settings else { return false }
        guard let script = Bundle.main.url(forResource: "mflux_driver", withExtension: "py") else {
            availability = .unavailable("mflux_driver.py missing from app bundle")
            return false
        }
        let python: String
        do {
            python = try settings.toolchain.mfluxInterpreter()
        } catch {
            interpreter = nil
            availability = .unavailable(error.localizedDescription)
            return false
        }
        interpreter = python

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [script.path]
        proc.environment = settings.buildEnvironment(interpreter: python)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do { try proc.run() } catch {
            availability = .unavailable("Driver launch failed: \(error.localizedDescription)")
            return false
        }
        process = proc
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutTail = ""

        let outStream = Self.chunkStream(for: stdoutPipe)
        Task { [weak self] in
            for await chunk in outStream {
                self?.consumeStdout(chunk)
            }
        }
        let errStream = Self.chunkStream(for: stderrPipe)
        Task { [weak self] in
            for await chunk in errStream {
                self?.onLog?(chunk)
            }
        }
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.processDied(proc) }
        }

        send(["cmd": "hello"])
        // The first venv import can be slow; the timeout only guards a wedged interpreter.
        let ready = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            handshake = cont
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(90))
                self?.resolveHandshake(false, reason: "Driver handshake timed out")
            }
        }
        if ready {
            availability = .available
        }
        return ready
    }

    private func resolveHandshake(_ ok: Bool, reason: String? = nil) {
        guard let cont = handshake else { return }
        handshake = nil
        if !ok {
            availability = .unavailable(reason ?? "Driver failed to start")
            process?.terminate()
        }
        cont.resume(returning: ok)
    }

    /// Clears the per-run cancel bookkeeping. Called on both ends of a run and
    /// when the process dies, so nothing leaks into the next job.
    private func resetCancelState() {
        cancelWatchdog?.cancel()
        cancelWatchdog = nil
        isStopping = false
        inDenoise = false
        lastProgressAt = nil
        lastStepInterval = nil
    }

    private func processDied(_ proc: Process) {
        // A retired driver's exit arrives after its replacement started.
        guard proc === process else { return }
        let wasGenerating = finishRun != nil
        let cancelled = intentionalKill
        intentionalKill = false
        resetCancelState()
        process = nil
        stdinHandle = nil
        loadedFingerprint = nil
        loadedSelectionKey = nil
        loadingSelectionKey = nil
        loadedMemoryGB = nil
        idleTask?.cancel()
        resolveHandshake(false, reason: "Driver exited during startup")
        // Teardown (if any) is over: release the ensureRunning() waiters now the process is gone.
        isTearingDown = false
        let teardownResolvers = self.teardownResolvers
        self.teardownResolvers = []
        for resolver in teardownResolvers {
            resolver.resume()
        }
        guard wasGenerating else { return }
        if cancelled {
            // Intentional hard kill: settle as cancelled and stay available so
            // the next job starts a fresh driver and reloads the model.
            finishRun?(.cancelled)
        } else {
            availability = .unavailable("Driver process died mid-job")
            finishRun?(.failed(proc.terminationReason == .uncaughtSignal
                    ? RunnerSupport.crashReason("The warm driver", signal: proc.terminationStatus)
                    : "Warm driver process died (exit status \(proc.terminationStatus))"))
        }
    }

    // MARK: - Job execution

    /// Sends one generate request and streams its events to `onEvent` until
    /// the driver reports done/error. Non-terminal events (loading, loaded,
    /// progress, image) are forwarded; terminal ones resolve the result.
    func run(request: DriverGenerateRequest, onEvent: @escaping (DriverEvent) -> Void) async -> DriverRunResult {
        guard stdinHandle != nil else { return .failed("Warm driver is not running") }
        isGenerating = true
        runID = request.id
        resetCancelState()
        idleTask?.cancel()
        switchEviction.cancel()
        defer {
            isGenerating = false
            loadingSelectionKey = nil
            jobEventHandler = nil
            finishRun = nil
            runID = nil
            resetCancelState()
            scheduleIdleEviction()
            // The selection may have moved while this job ran: evict now, as a switch would have.
            switchEviction.schedule(on: self)
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<DriverRunResult, Never>) in
            var finished = false
            let finish: (DriverRunResult) -> Void = { [weak self] result in
                guard !finished else { return }
                finished = true
                self?.finishRun = nil
                cont.resume(returning: result)
            }
            finishRun = finish
            jobEventHandler = { [weak self] event in
                switch event.event {
                case "loading":
                    if event.component == "model" { // not the text encoder, which reloads on warm runs too
                        self?.loadingSelectionKey = request.selectionKey
                    }
                    onEvent(event)
                case "loaded":
                    self?.loadedFingerprint = event.fingerprint
                    self?.loadedSelectionKey = request.selectionKey
                    self?.loadingSelectionKey = nil
                    self?.loadedMemoryGB = event.memoryGb
                    onEvent(event)
                case "done":
                    if let peak = event.peakGb {
                        self?.lastPeakGB = peak
                    }
                    if let memory = event.memoryGb {
                        self?.loadedMemoryGB = memory
                    }
                    // A warm run emits no `loaded` event — the state fields
                    // still describe this request's model.
                    self?.loadedFingerprint = request.fingerprint
                    self?.loadedSelectionKey = request.selectionKey
                    finish(event.cancelled == true ? .cancelled : .completed)
                case "error":
                    finish(.failed(event.message ?? "Unknown driver error"))
                default:
                    onEvent(event)
                }
            }
            var toSend = request
            toSend.tePolicy = resolvedTEPolicy().rawValue
            sendEncodable(toSend) { finish(.failed("Could not send job to driver")) }
        }
    }

    /// Cancels the in-flight generate, preferring the cooperative path so the warm model
    /// survives. Returns true when the driver was asked to abort rather than killed outright.
    ///
    /// MLX compute can't be interrupted from another thread, so the driver only notices the
    /// cancel flag between denoise steps (the `phase` window); an abort there is guaranteed
    /// within one step and the model stays resident. Outside it — load, encode, decode —
    /// SIGTERM is the only way to stop, and a second Stop press means the user wants out now.
    /// Both lose the warm model, as before.
    @discardableResult
    func cancel() -> Bool {
        guard isGenerating, let process, process.isRunning else { return false }
        guard inDenoise, !isStopping, let runID else {
            hardKill()
            return false
        }
        isStopping = true
        send(["cmd": "cancel", "id": runID])
        armCancelWatchdog()
        return true
    }

    private func hardKill() {
        guard let process, process.isRunning else { return }
        intentionalKill = true
        isTearingDown = true
        process.terminate()
    }

    /// Backstop for a wedged driver, not a slow step: the user's second Stop press is the
    /// escape hatch when an abort is taking a while, so this window can be generous.
    private func armCancelWatchdog() {
        cancelWatchdog?.cancel()
        let token = runID
        let grace = max(10, (lastStepInterval ?? 1) * 3)
        cancelWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(grace))
            guard !Task.isCancelled, let self, isGenerating, runID == token else { return }
            hardKill()
        }
    }

    // MARK: - Eviction policy

    /// Manual/automatic unload. The `unloaded` event clears the state fields.
    func eject(reason: String = "eject") {
        guard isLoaded, !isGenerating else { return }
        send(["cmd": "unload", "reason": reason])
    }

    /// The main window's selection changed: see ``SwitchEviction``.
    func selectionChanged(to key: String) {
        switchEviction.select(key, on: self)
    }

    private func scheduleIdleEviction() {
        idleTask?.cancel()
        let minutes = settings?.warmIdleMinutes ?? 0
        guard minutes > 0, isLoaded else { return }
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            guard !Task.isCancelled else { return }
            self?.eject(reason: "idle")
        }
    }

    /// Resolves the text-encoder policy for the next request. `auto` keeps the encoder until a
    /// measured peak crowds physical RAM (>70%), then evicts after every encode (embeddings are
    /// memoized driver-side, so the encoder is only reloaded when the prompt changes).
    private func resolvedTEPolicy() -> WarmTextEncoderPolicy {
        switch settings?.warmTextEncoderPolicy ?? .auto {
        case .keep: return .keep
        case .evict: return .evict
        case .auto:
            let physicalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1e9
            return (lastPeakGB ?? 0) > physicalGB * 0.7 ? .evict : .keep
        }
    }

    // MARK: - Transport

    private func consumeStdout(_ chunk: String) {
        stdoutTail += chunk
        while let newline = stdoutTail.firstIndex(of: "\n") {
            let line = String(stdoutTail[..<newline])
            stdoutTail.removeSubrange(...newline)
            guard let data = line.data(using: .utf8), !line.isEmpty else { continue }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            guard let event = try? decoder.decode(DriverEvent.self, from: data) else { continue }
            deliver(event)
        }
    }

    private func deliver(_ event: DriverEvent) {
        switch event.event {
        case "ready":
            resolveHandshake(true)
        case "fatal":
            resolveHandshake(false, reason: event.message ?? "Driver reported a fatal error")
        case "phase":
            // Controller-only: gates whether cancel can be cooperative.
            inDenoise = event.phase == "denoise"
        case "progress":
            let now = Date()
            if let last = lastProgressAt {
                lastStepInterval = now.timeIntervalSince(last)
            }
            lastProgressAt = now
            jobEventHandler?(event)
        case "unloaded":
            loadedFingerprint = nil
            loadedSelectionKey = nil
            loadedMemoryGB = nil
            idleTask?.cancel()
        // Mid-job refingerprint unloads are internal; the loading/loaded events that follow repopulate state.
        case "pong":
            if let memory = event.memoryGb {
                loadedMemoryGB = memory
            }
        default:
            jobEventHandler?(event)
        }
    }

    private func send(_ command: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: command) else { return }
        writeLine(data)
    }

    private func sendEncodable(_ request: DriverGenerateRequest, onFailure: () -> Void) {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(request) else {
            onFailure()
            return
        }
        writeLine(data)
    }

    private func writeLine(_ data: Data) {
        guard let stdinHandle else { return }
        do {
            try stdinHandle.write(contentsOf: data + Data("\n".utf8))
        } catch {
            writeFailed(error)
        }
    }

    /// The driver's stdin is gone (it died or closed the pipe). Logs the error and stays in
    /// teardown until the process exits; ``processDied(_:)`` then settles the run (``.cancelled``
    /// when a user Stop was in flight, else a crash/exit failure) and clears the model state.
    private func writeFailed(_ error: any Error) {
        let reason = "Could not write to the warm driver: \(error.localizedDescription)"
        onLog?(reason + "\n")
        // Preserve the Stop intent in processDied's classification: a write that fails while a
        // user Stop is in flight settles as cancelled; an unsolicited failure stays a failure.
        intentionalKill = isStopping
        isTearingDown = true
        // Leave the run and handshake pending: processDied settles them on exit.
        process?.terminate()
    }
}
