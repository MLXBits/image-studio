import SwiftUI

/// Per-model settings form. Shows inside the Settings "Models" tab.
///
/// The form bodies live in `ModelDefaultsView+Forms` and the reusable field
/// builders in `ModelDefaultsView+Fields`; both reach `settings` (internal here)
/// and the shared helpers. Caching state stays private to this file.
struct ModelDefaultsView: View {
    private enum CachePhase: Equatable {
        case idle, running, done, failed(String)
    }

    @Environment(AppSettings.self) var settings
    @State private var selectedModel: FluxModelVariant = .builtIn[0]
    @State private var cachePhase: CachePhase = .idle
    @State private var cacheLog: String = ""
    @State private var cacheProcess: Process?
    @State private var cacheRevision = UUID()
    @State private var userCancelledCache = false
    @State private var cacheStartedAt: Date?
    @State private var pendingDeleteVariant: (model: FluxModelVariant, quantize: Int)?

    var body: some View {
        HStack(spacing: 0) {
            // Left: model list
            modelList
                .frame(width: 160)
            Divider()
            // Right: settings for selected model
            modelForm
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onChange(of: selectedModel) { _, _ in
            cachePhase = .idle
            cacheLog = ""
            cacheProcess?.terminate()
            cacheProcess = nil
        }
        .alert("Delete cached weights?", isPresented: Binding(
            get: { pendingDeleteVariant != nil },
            set: { if !$0 { pendingDeleteVariant = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let pending = pendingDeleteVariant {
                    deleteCachedVariant(model: pending.model, quantize: pending.quantize)
                }
                pendingDeleteVariant = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteVariant = nil }
        } message: {
            if let pending = pendingDeleteVariant {
                let qLabel = pending.quantize == 0 ? pending.model.baseWeightLabel : "Q\(pending.quantize)"
                Text(
                    "This will permanently delete the \(qLabel) weights for"
                        + " \(pending.model.displayName) from disk. You can re-download them later."
                )
            }
        }
    }

    // MARK: - Model list

    private var modelList: some View {
        List(selection: $selectedModel) {
            Section("FLUX.2") {
                ForEach(FluxModelVariant.builtIn, id: \.self) { model in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.displayName).font(.callout)
                        Text(model.isDistilled
                            ? "Distilled · \(model.defaultSteps) steps"
                            : "Base · \(model.defaultSteps) steps")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(model)
                }
            }
            Section("Ideogram") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ideogram 4").font(.callout)
                    Text("Preset-based · gated FP8")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(FluxModelVariant.ideogram4)
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Per-model form

    private var modelForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                modelHeader
                Divider()
                if selectedModel.isIdeogram4 {
                    ideogram4FormContent()
                } else {
                    formContent(model: selectedModel, defaults: settings.defaults(for: selectedModel))
                }
            }
        }
    }

    private var modelHeader: some View {
        let quantize: Int
        let typeLabel: String
        if selectedModel.isIdeogram4 {
            quantize = settings.lastIdeogramQuantize ?? 8
            typeLabel = "Preset-based"
        } else {
            quantize = settings.defaults(for: selectedModel).quantize ?? selectedModel.recommendedQuantize
            typeLabel = selectedModel.isDistilled ? "Distilled" : "Base model"
        }
        let factor: Double = quantize == 4 ? 0.25 : quantize == 8 ? 0.5 : 1.0
        let vramGB = selectedModel.approximateBF16SizeGB * factor
        let quantLabel = quantize == 0 ? selectedModel.baseWeightLabel : "Q\(quantize)"
        let vramColor: Color = vramGB > 30 ? .orange : vramGB > 18 ? .yellow : .green

        return VStack(alignment: .leading, spacing: 6) {
            Text(selectedModel.displayName)
                .font(.headline)

            HStack(spacing: 10) {
                Label(
                    typeLabel,
                    systemImage: selectedModel.isDistilled ? "bolt.fill" : "cpu"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if vramGB > 0 {
                    Label(
                        "≈\(String(format: "%.0f", vramGB)) GB with \(quantLabel)",
                        systemImage: "memorychip"
                    )
                    .font(.caption)
                    .foregroundStyle(vramColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(vramColor.opacity(0.1), in: Capsule())
                }
            }

            cacheStatusRow(model: selectedModel, quantize: quantize)

            if cachePhase != .idle {
                cacheLogView
            }

            if selectedModel.isIdeogram4 {
                Text(
                    "Gated model — accept access at huggingface.co/ideogram-ai/ideogram-4-fp8,"
                        + " then set your HF token in Settings → Advanced."
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(
                    "Overrides global defaults when this model is selected."
                        + " The memory estimate above reflects your current quantize setting."
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
    }

    // MARK: - Cache log

    private var cacheLogView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(cacheLog.isEmpty ? "Starting…" : cacheLog)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .textSelection(.enabled)
                Color.clear.frame(height: 1).id("cacheLogEnd")
            }
            .frame(height: 120)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            .onChange(of: cacheLog) { _, _ in proxy.scrollTo("cacheLogEnd") }
            .onAppear { proxy.scrollTo("cacheLogEnd") }
        }
    }

    @ViewBuilder
    private func cacheStatusRow(model: FluxModelVariant, quantize: Int) -> some View {
        switch cachePhase {
        case .running:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    let verb = model.isOnDisk(quantize: 0, savedIn: settings.effectiveMfluxCacheDir) && quantize != 0
                        ? "Converting" : "Downloading"
                    TimelineView(.periodic(from: cacheStartedAt ?? Date(), by: 1)) { ctx in
                        let elapsed = Int(ctx.date.timeIntervalSince(cacheStartedAt ?? ctx.date))
                        let mm = elapsed / 60
                        let ss = elapsed % 60
                        Text("\(verb)… \(mm > 0 ? "\(mm)m " : "")\(String(format: "%02d", ss))s")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel") {
                        userCancelledCache = true
                        cacheProcess?.terminate()
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                Text("You can close Settings — this continues in the background.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

        case let .failed(message):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Label("Failed", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                    Button("Retry") { startCache(model: model, quantize: quantize) }
                        .buttonStyle(.bordered).controlSize(.small)
                    Spacer()
                }
                Text(message)
                    .font(.caption2).foregroundStyle(.red.opacity(0.8))
            }

        case .idle, .done:
            HStack(spacing: 6) {
                // swiftlint:disable:next redundant_discardable_let
                let _ = cacheRevision // invalidates view when cache changes on disk
                let cachedVariants = [0, 4, 8].filter { model.isOnDisk(quantize: $0, savedIn: settings.effectiveMfluxCacheDir) }
                ForEach(cachedVariants, id: \.self) { qLevel in
                    HStack(spacing: 3) {
                        Text(qLevel == 0 ? model.baseWeightLabel : "Q\(qLevel)")
                            .font(.caption2).fontWeight(.medium)
                        Button {
                            pendingDeleteVariant = (model, qLevel)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.green.opacity(0.15), in: Capsule())
                    .foregroundStyle(.green)
                }
                let cacheDir = settings.effectiveMfluxCacheDir
                // Ideogram 4: quantization not supported — FP8 only. Hide Q4/Q8 entirely.
                let availableQuantLevels = model.isIdeogram4 ? [0] : [0, 4, 8]
                ForEach(availableQuantLevels.filter { !model.isOnDisk(quantize: $0, savedIn: cacheDir) }, id: \.self) { qLevel in
                    let qLabel = qLevel == 0 ? model.baseWeightLabel : "Q\(qLevel)"
                    Button("Download \(qLabel)") {
                        startCache(model: model, quantize: qLevel)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                if model.isIdeogram4 && !model.isOnDisk(quantize: 0, savedIn: cacheDir) {
                    Text("~28 GB · quantization not yet supported")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private func deleteCachedVariant(model: FluxModelVariant, quantize: Int) {
        let savePath = model.savedModelPath(quantize: quantize, in: settings.effectiveMfluxCacheDir)
        try? FileManager.default.removeItem(at: savePath)
        if let hfURL = model.onDiskURL(quantize: quantize) {
            try? FileManager.default.removeItem(at: hfURL)
        }
        cacheRevision = UUID()
    }

    // MARK: - Model caching

    private func startCache(model: FluxModelVariant, quantize: Int) {
        cachePhase = .running
        cacheLog = ""
        cacheStartedAt = Date()
        userCancelledCache = false
        Task { await runMfluxSave(model: model, quantize: quantize) }
    }

    private func runMfluxSave(model: FluxModelVariant, quantize: Int) async {
        // Ideogram 4 support is only in the uv-installed mflux; skip the configured dev dir.
        let saveBinary = model.isIdeogram4
            ? BinaryDetector.detect("mflux-save")
            : BinaryDetector.mfluxSave(in: settings.mfluxBinaryDir)
        guard !saveBinary.isEmpty, FileManager.default.fileExists(atPath: saveBinary) else {
            cachePhase = .failed("mflux-save not found. Check Settings → Advanced.")
            return
        }
        let savePath = model.savedModelPath(quantize: quantize, in: settings.effectiveMfluxCacheDir)
        try? FileManager.default.createDirectory(at: savePath, withIntermediateDirectories: true)

        var args: [String]
        if quantize != 0 {
            // Prefer local BF16 as source (no download needed); fall back to pre-quantized repo or HF ID.
            let bf16Saved = model.savedModelPath(quantize: 0, in: settings.effectiveMfluxCacheDir)
            if FluxModelVariant.hasSavedWeights(at: bf16Saved) {
                args = ["--model", bf16Saved.path, "--quantize", "\(quantize)", "--path", savePath.path]
            } else if model.isOnDisk(quantize: 0), let bf16Repo = model.bf16HFRepoID {
                args = ["--model", bf16Repo, "--quantize", "\(quantize)", "--path", savePath.path]
            } else if let preRepo = model.preQuantizedRepoID(quantize: quantize) {
                args = ["--model", preRepo, "--path", savePath.path]
            } else {
                args = ["--model", model.mfluxModelID, "--quantize", "\(quantize)", "--path", savePath.path]
            }
        } else if let preRepo = model.preQuantizedRepoID(quantize: quantize) {
            args = ["--model", preRepo, "--path", savePath.path]
        } else {
            args = ["--model", model.mfluxModelID, "--path", savePath.path]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: saveBinary)
        process.arguments = args
        process.environment = settings.buildEnvironment()
        cacheProcess = process

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let stream = AsyncStream<String> { continuation in
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    continuation.finish()
                } else if let text = String(data: data, encoding: .utf8) {
                    continuation.yield(text)
                }
            }
            process.terminationHandler = { _ in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.finish()
                }
            }
        }

        do { try process.run() } catch {
            cacheProcess = nil
            cachePhase = .failed(error.localizedDescription)
            return
        }

        for await chunk in stream {
            cacheLog = appendCacheLog(chunk, to: cacheLog)
        }
        process.waitUntilExit()
        cacheProcess = nil

        if process.terminationStatus == 0 {
            let savedFiles = (try? FileManager.default.contentsOfDirectory(
                at: savePath, includingPropertiesForKeys: nil
            ))?.map(\.lastPathComponent) ?? []
            cacheLog += "\nSaved to: \(savePath.path)\nFiles: \(savedFiles.isEmpty ? "(none found)" : savedFiles.joined(separator: ", "))"
            cachePhase = .done
            cacheRevision = UUID()
        } else if process.terminationReason == .uncaughtSignal {
            try? FileManager.default.removeItem(at: savePath)
            if userCancelledCache {
                cachePhase = .idle
            } else {
                cachePhase = .failed("Process crashed (signal \(process.terminationStatus)). Check the log below.")
            }
        } else {
            cachePhase = .failed("mflux-save exited with status \(process.terminationStatus). Check the log below.")
        }
    }

    private func appendCacheLog(_ chunk: String, to log: String) -> String {
        var result = log
        var idx = chunk.startIndex
        while idx < chunk.endIndex {
            let char = chunk[idx]
            idx = chunk.index(after: idx)
            if char == "\u{1B}" {
                // ESC — consume the full CSI sequence \x1b[<params><letter>
                guard idx < chunk.endIndex, chunk[idx] == "[" else { continue }
                idx = chunk.index(after: idx)
                while idx < chunk.endIndex && !chunk[idx].isLetter {
                    idx = chunk.index(after: idx)
                }
                guard idx < chunk.endIndex else { continue }
                let cmd = chunk[idx]
                idx = chunk.index(after: idx)
                if cmd == "A" {
                    // Cursor up: remove current line and the \n above it, moving to end of previous line
                    if let nl = result.lastIndex(of: "\n") {
                        result = String(result[result.startIndex ..< nl])
                    } else {
                        result = ""
                    }
                }
            } else if char == "\r" {
                if let nl = result.lastIndex(of: "\n") {
                    result = String(result[...nl])
                } else {
                    result = ""
                }
            } else {
                result.append(char)
            }
        }
        return result
    }
}
