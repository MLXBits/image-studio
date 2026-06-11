# Plan: Keep Model Warm (Persistent Daemon via Unix Socket)

## Context

Today every Image Studio job spawns a fresh `mflux-generate-flux2` subprocess. Model load costs 30–60s per job — paid even for quick prompt iterations. The mflux Python library has no such constraint: instantiate `Flux2Klein` once and call `generate_image()` repeatedly. This plan adds a persistent `mflux-daemon` process that loads the model once and keeps it alive between jobs, eliminating the reload cost. IPC uses a Unix domain socket: protocol JSON flows over the socket; stdout+stderr remain a simple merged pipe for job.log (same as today). A settings toggle controls the feature; zero behaviour change when it's off.

## Architecture

**IPC**: Unix domain socket at `/tmp/mflux-daemon-<uuid>.sock`. Studio passes the path as `--socket-path` at daemon launch. Protocol is newline-delimited JSON over the socket (bidirectional). stdout+stderr merged into job.log via the existing single-pipe approach — no split needed.

**Daemon states** (tracked Swift-side):
- `notRunning` — process doesn't exist
- `modelIdle` — socket connected, model unloaded (after idle timeout or explicit unload)
- `modelLoaded` — model in Metal memory, ready
- `generating` — request in flight

**Lazy start**: daemon spawned on first job when warm mode is on.

**Multi-seed batch**: runner sends one request per seed to the daemon sequentially. Seeds 2..N skip model load.

**lowRam fallback**: `--low-ram` jobs always use the one-shot CLI path (MemorySaver with `keep_transformer=False` is incompatible with keeping the model warm).

**Model identity** drives reload decisions: `(model_id, quantize, model_path_override, is_edit, sorted(lora_paths), lora_scales)`. Any change forces unload + reload.

**Daemon exits when connection drops** (Studio ejects or crashes). The socket path is cleaned up on exit.

## Files to Create

### `mflux-lokr/src/mflux/models/flux2/cli/flux2_daemon.py` (~200 lines)

**Startup**: bind Unix socket at `--socket-path`, accept one connection, enter request loop. Print status to stderr (goes into job.log via merged pipe).

**Request loop** uses `select()` with 1-second timeout for non-blocking idle detection — single-threaded, no timer thread:

```python
buf = ""
while True:
    ready = select.select([conn], [], [], 1.0)
    if ready[0]:
        data = conn.recv(4096)
        if not data:
            break  # connection closed — exit
        buf += data.decode()
        while '\n' in buf:
            line, buf = buf.split('\n', 1)
            if line.strip():
                req = json.loads(line)
                match req["type"]:
                    case "generate":  self._handle_generate(req)
                    case "unload":    self._unload_model(); self._emit({"type":"idle"})
                    case "shutdown":  self._unload_model(); return
    else:
        # 1-second poll: check idle timeout
        if (self._model is not None
                and self._idle_timeout > 0
                and time.time() - self._last_activity > self._idle_timeout):
            self._unload_model()
            self._emit({"type": "idle"})
```

**`_emit(msg)`**: `conn.sendall((json.dumps(msg) + '\n').encode())` — always called from main thread, no lock needed.

**`ModelIdentity`**: `@dataclass(frozen=True)` — `(model, quantize, model_path, is_edit, lora_paths: tuple, lora_scales: tuple)`.

**`ProgressCallback(InLoopCallback)`**: calls `self._emit({"type":"progress","step":t+1,"total":N,"elapsed":"..."})` using `time_steps.format_dict["elapsed"]`. Registered per-generate call.

**`_handle_generate(req)`**:
1. `_last_activity = time.time()`
2. Compare `ModelIdentity.from(req)` to `self._identity`. If different: `_unload_model()`, emit `{"type":"loading","model":...}`, construct `Flux2Klein` or `Flux2KleinEdit` (based on `req["is_edit"]`), emit `{"type":"ready"}`
3. Reset `model.callbacks = CallbackRegistry()` (prevents callback leak across calls)
4. Register per-call `ProgressCallback`, `StepwiseHandler` (if `stepwise_dir` provided), `MemorySaver(keep_transformer=True)`
5. `model.generate_image(...)` — `image_paths=` for edit mode, `image_path=` for generate
6. `generated_image.save(path=req["output_path"])`
7. Emit `{"type":"complete","seed":...,"generation_time":...,"output_path":...}`
8. On `StopImageGenerationException` (SIGINT → KeyboardInterrupt): emit `{"type":"error","message":"Cancelled"}` — model stays loaded, loop continues
9. On any other exception: emit `{"type":"error","message":str(e)}`
10. `_last_activity = time.time()`

**`_unload_model()`**: `self._model = None; self._identity = None; gc.collect(); mx.clear_cache()`

**`_resolve_model_path(req)`**: daemon receives `model` (predefined name e.g. `"flux2-klein-4b"` for `ModelConfig.from_name()`) and `model_path` (optional resolved source: pre-quantized HF repo ID, local saved path, or null). `Flux2Initializer` uses `model_path` if set, else falls back to `model_config.model_name`.

**SIGTERM handler**: `signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))` — Python atexit handles cleanup.

**`main()`**: argparse for `--socket-path` (required), `--idle-timeout-seconds` (default 300), `--mlx-cache-limit-gb` (optional). Set MLX cache limit at startup if provided.

**Cleanup**: `atexit.register(cleanup)` removes the socket file.

### `mflux-lokr/pyproject.toml`

Add one line to `[project.scripts]`:
```toml
mflux-daemon = "mflux.models.flux2.cli.flux2_daemon:main"
```

### `MLXBits Image Studio/Runner/DaemonProcessManager.swift` (~200 lines)

`@Observable @MainActor final class DaemonProcessManager`

**Socket I/O**: POSIX socket APIs + `DispatchSource.makeReadSource` (consistent with the existing `DispatchSource.makeFileSystemObjectSource` in `FluxJobRunner`). No Network.framework needed.

```swift
private var socketFD: Int32 = -1
private var readSource: DispatchSourceRead?
private var receiveBuffer = ""
```

**`ModelIdentity`**: Swift mirror of the Python side. Static `from(job:settings:) -> ModelIdentity`.

**Process launch**: single merged `Pipe()` for stdout+stderr → job.log (identical to current one-shot CLI approach):

```swift
private func spawnDaemon(settings: AppSettings) throws {
    let socketPath = "/tmp/mflux-daemon-\(UUID().uuidString).sock"
    self.socketPath = socketPath

    let p = Process()
    p.executableURL = URL(fileURLWithPath: BinaryDetector.mfluxDaemon(in: settings.mfluxBinaryDir))
    p.arguments = buildDaemonArgs(socketPath: socketPath, settings: settings)
    p.environment = settings.buildEnvironment()

    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe          // merged — goes to job.log same as CLI today
    p.terminationHandler = { [weak self] _ in
        Task { @MainActor [weak self] in self?.handleProcessTermination() }
    }
    try p.run()
    self.process = p
    self.logPipe = pipe             // runner attaches readability handler per-job
    state = .modelIdle
}
```

**`ensureRunning(settings:) async throws`**:
1. If `state != .notRunning`, return immediately
2. Call `spawnDaemon(settings:)`
3. Poll for socket file (100ms intervals, 15s timeout) — socket appears as soon as Python binds it, before any model load
4. Connect: `connectSocket(path: socketPath)`
5. `startReceiving()`

**`connectSocket(path:)`**: POSIX `socket()` + `connect()`:

```swift
private func connectSocket(path: String) throws {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw DaemonError.socketFailed }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    path.withCString { src in
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            UnsafeMutableRawPointer(dst).copyMemory(from: src, byteCount: min(path.utf8.count + 1, 104))
        }
    }

    let result = withUnsafePointer(to: addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Foundation.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else { close(fd); throw DaemonError.socketFailed }
    self.socketFD = fd
}
```

**`startReceiving()`**: `DispatchSource.makeReadSource` reads chunks, splits on `\n`, dispatches complete lines to `handleDaemonMessage(_:)` on MainActor:

```swift
private func startReceiving() {
    let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: .global())
    source.setEventHandler { [weak self] in
        guard let self else { return }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(self.socketFD, &buf, buf.count)
        guard n > 0, let text = String(bytes: buf[..<n], encoding: .utf8) else {
            source.cancel(); return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.receiveBuffer += text
            while let nl = self.receiveBuffer.firstIndex(of: "\n") {
                let line = String(self.receiveBuffer[..<nl])
                self.receiveBuffer = String(self.receiveBuffer[self.receiveBuffer.index(after: nl)...])
                if !line.isEmpty { self.handleDaemonMessage(line) }
            }
        }
    }
    source.resume()
    readSource = source
}
```

**`handleDaemonMessage(_:)`**: parses JSON, drives state machine + fulfils continuations:
- `"loading"` / `"ready"` → update `statusLine` on active job via `activeJobStatusHandler`
- `"progress"` → call `progressHandler: ((Int, Int, String?) -> Void)?`
- `"complete"` → resolve `pendingContinuation` with `DaemonResponse`, state → `.modelLoaded`
- `"error"` → resolve continuation with `DaemonError.generationFailed`, state → `.modelLoaded`
- `"idle"` → state → `.modelIdle`, nil `currentIdentity`

**`sendMessage(_ dict:)`**: serialize to JSON + `\n`, write via `write(socketFD, ...)`. Always called from MainActor so no lock needed.

**`generate(request:progressHandler:statusHandler:) async throws -> DaemonResponse`**: encodes and sends request JSON, stores handlers, awaits `withCheckedThrowingContinuation`.

**`cancelGeneration()`**: `process?.interrupt()` (SIGINT). Daemon emits `{"type":"error","message":"Cancelled"}`, model stays loaded.

**`eject()`**: `process?.terminate()`, `handleProcessTermination()`.

**`sendShutdown()`**: `sendMessage(["type":"shutdown"])`, give process 2s to exit, then force-terminate.

**`handleProcessTermination()`**: cancel `readSource`, close `socketFD`, set state to `.notRunning`, nil everything, resume any pending continuation with `.crashed`.

**`logPipe: Pipe?`**: exposed so `FluxJobRunner` can attach its existing readability handler to it when a job starts (identical to how it reads from the current one-shot process pipe).

**`buildDaemonArgs(socketPath:settings:) -> [String]`**:
```swift
["--socket-path", socketPath,
 "--idle-timeout-seconds", "\(settings.daemonIdleTimeoutMinutes * 60)"]
+ (settings.mlxCacheLimitGB > 0 ? ["--mlx-cache-limit-gb", "\(settings.mlxCacheLimitGB)"] : [])
```

**`DaemonGenerateRequest`**: `Encodable` struct with snake_case `CodingKeys`. Fields: `type` (= `"generate"`), `model`, `model_path`, `quantize`, `is_edit`, `prompt`, `seed`, `steps`, `height`, `width`, `guidance`, `lora_paths`, `lora_scales`, `image_path`, `image_strength`, `edit_image_paths`, `stepwise_dir`, `output_path`.

## Files to Modify

### `AppSettings.swift`

```swift
var keepModelWarm: Bool       { didSet { save() } }  // default false
var daemonIdleTimeoutMinutes: Int { didSet { save() } }  // default 5
```

Add to `Stored` struct as `Bool?` / `Int?` (optional for backward-compat decode, same pattern as existing fields). Add:
```swift
var isDaemonAvailable: Bool { !BinaryDetector.mfluxDaemon(in: mfluxBinaryDir).isEmpty }
```

### `BinaryDetector.swift`

```swift
static func mfluxDaemon(in dir: String) -> String {
    if !dir.isEmpty {
        let p = "\(dir)/mflux-daemon"
        if FileManager.default.fileExists(atPath: p) { return p }
    }
    return detect("mflux-daemon")
}
```

### `Runner/FluxJobRunner.swift`

Add `var daemonManager: DaemonProcessManager?` property.

**Dispatch at top of `run(_:settings:)`** (after stepDir + stepwise watcher setup, before binary path check):
```swift
if settings.keepModelWarm && !job.lowRam,
   let manager = daemonManager, settings.isDaemonAvailable {
    await runDaemon(job, settings: settings, manager: manager)
    return
}
// ... existing CLI path unchanged ...
```

**New `runDaemon(_:settings:manager:)` method**:
- `try await manager.ensureRunning(settings:)` — falls back to CLI on `DaemonError`
- Attach `manager.logPipe` readability handler → `job.log` (same handler body as today's merged-pipe path)
- Compute `resolvedModelID` and `resolvedModelPath` (helpers extracted from `buildArgs`): pre-quantized repo, saved path, or base ID + quantize flag
- Loop over `seedsToRun`, one `DaemonGenerateRequest` per seed
- `progressHandler` updates `job.currentStep`, `job.totalSteps`, `job.stepTiming`, `job.isDenoising`
- `statusHandler` updates `job.statusLine` from `"loading"`/`"ready"` messages
- On `.cancelled` → `finishJob(.cancelled)`, return
- On `.crashed` / `.ejected` → `finishJob(.failed("Daemon unavailable"))`, return
- Uses existing `expandedPaths`, `startBatchPoller`, `loadThumbnail`, `MetadataSidecar.write`, `finishJob` unchanged

**Adapt `cancel()`**:
```swift
func cancel() {
    if let dm = daemonManager, case .generating = dm.state {
        dm.cancelGeneration()
    } else {
        currentProcess?.terminate()
    }
}
```

### `MLXBitsImageStudioApp.swift`

Add `@State private var daemonManager = DaemonProcessManager()`. Inject as `.environment(daemonManager)`. Wire termination:
```swift
.onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
    daemonManager.sendShutdown()
}
```

### `ContentView.swift`

Read `@Environment(DaemonProcessManager.self) private var daemonManager`. Set `runner.daemonManager = daemonManager` in `.onAppear`.

### `Views/Settings/SettingsView.swift`

Add `@Environment(DaemonProcessManager.self) private var daemonManager`.

New **"Warm Mode"** section in the Advanced tab:
- **Toggle** "Keep model warm between jobs" — disabled + red "mflux-daemon not found" label when `!settings.isDaemonAvailable`
- **Memory warning** (orange) when enabled and `ProcessInfo.processInfo.physicalMemory / 1_073_741_824 <= 32`: "Model stays in RAM while idle. On XGB Macs this may pressure other apps."
- **Idle timeout** field (minutes) — only shown when enabled
- **Status indicator**: coloured dot + label (`notRunning`→grey, `modelIdle`→yellow, `modelLoaded`→green, `generating`→blue)
- **Eject button**: `daemonManager.eject()` — disabled when `state == .notRunning`
- Toggle `onChange`: if turned off while running → `daemonManager.eject()`

Add `.environment(daemonManager)` to the `Settings { SettingsView() }` call site.

## Edge Cases

| Case | Handling |
|------|----------|
| Daemon crash mid-generate | `terminationHandler` → state `.notRunning`, continuation resolves `.crashed`, runner falls to CLI |
| Cancel mid-generate | SIGINT → daemon emits error, model stays loaded, runner marks `.cancelled` |
| Model switch between jobs | Identity mismatch → daemon unloads + reloads; Studio sees normal load latency for that job |
| `--low-ram` job | Skip daemon, use CLI path |
| `mflux-daemon` not installed | `isDaemonAvailable = false`, toggle disabled, CLI path always used |
| Warm mode toggled off while alive | `daemonManager.eject()` from toggle `onChange` |
| App quit with daemon running | `sendShutdown()` in `willTerminate`; daemon exits cleanly |
| Idle timeout fires during generate | `select()` timeout only triggers between requests; cannot fire mid-generate |
| Studio reconnect after crash | Daemon exits when connection drops; Studio spawns fresh daemon on next job |
| Socket file collision | UUID in socket path; `atexit` cleanup removes it on exit |
| Socket connect timeout | 15s poll for socket file; `DaemonError.socketTimeout` → CLI fallback |

## Implementation Sequence

1. `flux2_daemon.py` + `pyproject.toml` — standalone test: `mflux-daemon --socket-path /tmp/test.sock` then connect with `nc -U /tmp/test.sock` and send JSON
2. `BinaryDetector.swift` — one static method
3. `AppSettings.swift` — two properties + `isDaemonAvailable`
4. `DaemonProcessManager.swift` — core new Swift file
5. `FluxJobRunner.swift` — dispatch logic + `runDaemon` + adapted `cancel()`
6. `MLXBitsImageStudioApp.swift` — inject environment, wire termination
7. `ContentView.swift` — pass manager to runner
8. `SettingsView.swift` — warm mode section

Steps 1–3 are independent. Step 4 depends on 3. Steps 5–8 depend on 4.

## Verification

1. **Daemon standalone**: `mflux-daemon --socket-path /tmp/t.sock --idle-timeout-seconds 10`, connect with `nc -U /tmp/t.sock`, send generate JSON, observe progress + complete JSON responses
2. **Idle unload**: wait 10s after generation, observe `{"type":"idle"}`, verify Metal memory drops (Activity Monitor → GPU Memory)
3. **Studio warm path**: enable toggle, generate two images back-to-back with same model — second skips "Loading model…" in log
4. **Model switch**: generate 4B then 9B — second job log shows reload
5. **Cancel mid-generate**: cancel running job — job marked cancelled, daemon still alive for next job
6. **Eject**: click Eject — status dot goes grey, next job loads fresh
7. **lowRam fallback**: enable warm mode + lowRam, generate — job log shows CLI command echo (not daemon path)
8. **App quit during generation**: quit — daemon exits, no zombie process, Metal memory released
9. **mflux-daemon not installed**: rename binary, verify toggle is greyed out, jobs still work via CLI
