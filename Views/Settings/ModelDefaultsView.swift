// swiftlint:disable file_length
import SwiftUI

/// Per-model settings form. Shows inside the Settings "Models" tab.
struct ModelDefaultsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var selectedModel: FluxModelVariant = FluxModelVariant.builtIn[0]

    private enum CachePhase: Equatable {
        case idle, running, done, failed(String)
    }
    @State private var cachePhase: CachePhase = .idle
    @State private var cacheLog: String = ""
    @State private var cacheProcess: Process?
    @State private var cacheRevision = UUID()
    @State private var userCancelledCache = false
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
                let qLabel = pending.quantize == 0 ? "BF16" : "Q\(pending.quantize)"
                Text(
                    "This will permanently delete the \(qLabel) weights for"
                        + " \(pending.model.displayName) from disk. You can re-download them later."
                )
            }
        }
    }

    // MARK: - Model list

    private var modelList: some View {
        List(FluxModelVariant.builtIn, id: \.self, selection: $selectedModel) { model in
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(.callout)
                Text(model.isDistilled ? "Distilled · \(model.defaultSteps) steps" : "Base · \(model.defaultSteps) steps")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .tag(model)
        }
        .listStyle(.sidebar)
    }

    // MARK: - Per-model form

    private var modelForm: some View {
        let d = settings.defaults(for: selectedModel)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                modelHeader
                Divider()
                formContent(model: selectedModel, defaults: d)
            }
        }
    }

    private var modelHeader: some View {
        let d = settings.defaults(for: selectedModel)
        let quantize = d.quantize ?? selectedModel.recommendedQuantize
        let factor: Double = quantize == 4 ? 0.25 : quantize == 8 ? 0.5 : 1.0
        let vramGB = selectedModel.approximateBF16SizeGB * factor
        let quantLabel = quantize == 0 ? "BF16" : "Q\(quantize)"
        let vramColor: Color = vramGB > 30 ? .orange : vramGB > 18 ? .yellow : .green

        return VStack(alignment: .leading, spacing: 6) {
            Text(selectedModel.displayName)
                .font(.headline)

            HStack(spacing: 10) {
                Label(
                    selectedModel.isDistilled ? "Distilled" : "Base model",
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

            Text("Overrides global defaults when this model is selected. The memory estimate above reflects your current quantize setting.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
    }

    @ViewBuilder
    private func cacheStatusRow(model: FluxModelVariant, quantize: Int) -> some View {
        switch cachePhase {
        case .running:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.isOnDisk(quantize: 0, savedIn: settings.effectiveMfluxCacheDir) && quantize != 0
                         ? "Converting…" : "Downloading…")
                        .font(.caption).foregroundStyle(.secondary)
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

        case .failed(let message):
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
                let _ = cacheRevision  // invalidates view when cache changes on disk
                let cachedVariants = [0, 4, 8].filter { model.isOnDisk(quantize: $0, savedIn: settings.effectiveMfluxCacheDir) }
                ForEach(cachedVariants, id: \.self) { qLevel in
                        HStack(spacing: 3) {
                            Text(qLevel == 0 ? "BF16" : "Q\(qLevel)")
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
                ForEach([0, 4, 8].filter { !model.isOnDisk(quantize: $0, savedIn: cacheDir) }, id: \.self) { qLevel in
                    let qLabel = qLevel == 0 ? "BF16" : "Q\(qLevel)"
                    let canConvert = qLevel != 0 && model.isOnDisk(quantize: 0, savedIn: settings.effectiveMfluxCacheDir)
                    Button(canConvert ? "Convert to \(qLabel)" : "Download \(qLabel)") {
                        startCache(model: model, quantize: qLevel)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
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

    @ViewBuilder
    private func formContent(model: FluxModelVariant, defaults d: ModelDefaults) -> some View {
        Form {
            Section("Generation") {
                stepsPicker(model: model, current: d.steps)
                if !model.isDistilled {
                    guidancePicker(model: model, current: d.guidance)
                } else {
                    LabeledContent("Guidance") {
                        Text("Fixed at 1.0 (distilled)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                quantizePicker(model: model, current: d.quantize)
                modelRepoField(model: model, current: d.modelRepoOverride)
                lowRamToggle(model: model, current: d.lowRam)
            }

            if model.supportsNegativePrompt {
                Section {
                    negativePromptField(model: model, current: d.negativePrompt)
                } header: {
                    Text("Negative Prompt")
                }
            }

            Section {
                widthPicker(model: model, current: d.width)
                heightPicker(model: model, current: d.height)
            } header: {
                Text("Canvas")
            } footer: {
                Text("Falls back to the global default size in Generation if not overridden here.")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            Section {
                loraOverrideSection(model: model, current: d.loras)
            } header: {
                Text("LoRAs")
            } footer: {
                Text(
                    "Adjusts which LoRAs from the LoRAs tab are enabled and at what"
                        + " strength for this model. Add or remove LoRAs in Settings → LoRAs."
                )
                .font(.caption).foregroundStyle(.tertiary)
            }

            Section {
                Button("Reset to Defaults", role: .destructive) {
                    settings.updateDefaults(ModelDefaults(), for: model)
                }
                .foregroundStyle(.red)
                .accessibilityLabel("Reset \(model.displayName) to built-in defaults")
            }
        }
        .formStyle(.grouped)
        .id(model)  // force re-render when model changes
    }

    // MARK: - Field builders
    // All use LabeledContent so the Form's grouped style aligns labels left and controls right.
    // Reset (×) sits to the left of the control so the primary control stays at the trailing edge.

    private func stepsPicker(model: FluxModelVariant, current: Int?) -> some View {
        let bound = Binding<Int>(
            get: { current ?? model.defaultSteps },
            set: { newVal in
                var d = settings.defaults(for: model); d.steps = newVal
                settings.updateDefaults(d, for: model)
            }
        )
        return LabeledContent("Steps") {
            HStack(spacing: 6) {
                if current != nil {
                    resetButton { var d = settings.defaults(for: model); d.steps = nil; settings.updateDefaults(d, for: model) }
                }
                TextField("", value: bound, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .onSubmit { bound.wrappedValue = max(1, min(150, bound.wrappedValue)) }
                Stepper("", value: bound, in: 1...150).labelsHidden()
            }
        }
        .accessibilityLabel("Default steps for \(model.displayName)")
    }

    private func guidancePicker(model: FluxModelVariant, current: Double?) -> some View {
        let bound = Binding<Double>(
            get: { current ?? model.defaultGuidance },
            set: { newVal in
                var d = settings.defaults(for: model); d.guidance = newVal
                settings.updateDefaults(d, for: model)
            }
        )
        return LabeledContent("Guidance") {
            HStack(spacing: 6) {
                if current != nil {
                    resetButton { var d = settings.defaults(for: model); d.guidance = nil; settings.updateDefaults(d, for: model) }
                }
                Slider(value: bound, in: 1.0...15.0)
                    .frame(minWidth: 80)
                Text(String(format: "%.1f", bound.wrappedValue))
                    .monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
            }
        }
        .accessibilityLabel("Default guidance for \(model.displayName)")
    }

    private func quantizePicker(model: FluxModelVariant, current: Int?) -> some View {
        let bound = Binding<Int>(
            get: { current ?? model.recommendedQuantize },
            set: { newVal in
                var d = settings.defaults(for: model); d.quantize = newVal
                settings.updateDefaults(d, for: model)
            }
        )
        return LabeledContent("Quantization") {
            HStack(spacing: 6) {
                if current != nil {
                    resetButton { var d = settings.defaults(for: model); d.quantize = nil; settings.updateDefaults(d, for: model) }
                }
                Picker("", selection: bound) {
                    Text("BF16").tag(0)
                    Text("Q8").tag(8)
                    Text("Q4").tag(4)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 80)
            }
        }
        .accessibilityLabel("Default quantization for \(model.displayName)")
    }

    private func modelRepoField(model: FluxModelVariant, current: String?) -> some View {
        let bound = Binding<String>(
            get: { current ?? "" },
            set: { newVal in
                var d = settings.defaults(for: model)
                d.modelRepoOverride = newVal.isEmpty ? nil : newVal
                settings.updateDefaults(d, for: model)
            }
        )
        return LabeledContent("Model source") {
            HStack(spacing: 6) {
                if current != nil {
                    resetButton {
                        var d = settings.defaults(for: model)
                        d.modelRepoOverride = nil
                        settings.updateDefaults(d, for: model)
                    }
                }
                TextField("org/repo or /path/to/weights", text: bound)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .font(.caption)
                    .onSubmit {
                        let trimmed = bound.wrappedValue.trimmingCharacters(in: .whitespaces)
                        bound.wrappedValue = trimmed
                    }
                Button("Browse…") { browseModelDir(binding: bound) }
                    .controlSize(.small)
                InfoButton(
                    title: "Model source override",
                    description: "HF repo ID (e.g. mlx-community/flux2-klein-9b-8bit) " +
                        "or absolute local path. When set, replaces the mflux default for this model. " +
                        "The --quantize flag is not passed — the repo's own weight metadata is used."
                )
            }
        }
        .accessibilityLabel("Model source override for \(model.displayName)")
    }

    private func lowRamToggle(model: FluxModelVariant, current: Bool?) -> some View {
        let bound = Binding<Bool>(
            get: { current ?? false },
            set: { newVal in
                var d = settings.defaults(for: model); d.lowRam = newVal
                settings.updateDefaults(d, for: model)
            }
        )
        return LabeledContent("Low RAM mode") {
            HStack(spacing: 6) {
                if current != nil {
                    resetButton { var d = settings.defaults(for: model); d.lowRam = nil; settings.updateDefaults(d, for: model) }
                }
                Toggle("", isOn: bound).labelsHidden()
            }
        }
        .accessibilityLabel("Default low RAM mode for \(model.displayName)")
        .accessibilityHint("Streams transformer blocks from disk to reduce peak memory")
    }

    private func negativePromptField(model: FluxModelVariant, current: String?) -> some View {
        let bound = Binding<String>(
            get: { current ?? "" },
            set: { newVal in
                var d = settings.defaults(for: model)
                d.negativePrompt = newVal.isEmpty ? nil : newVal
                settings.updateDefaults(d, for: model)
            }
        )
        return HStack(alignment: .top) {
            TextEditor(text: bound)
                .font(.caption)
                .frame(minHeight: 60)
                .accessibilityLabel("Default negative prompt for \(model.displayName)")
                .accessibilityHint("Applied automatically when this model is selected")
            if current != nil {
                resetButton { var d = settings.defaults(for: model); d.negativePrompt = nil; settings.updateDefaults(d, for: model) }
            }
        }
    }

    private func widthPicker(model: FluxModelVariant, current: Int?) -> some View {
        dimensionRow(
            label: "Width", model: model, current: current,
            get: \.width,
            set: { var d = settings.defaults(for: model); d.width = $0; settings.updateDefaults(d, for: model) },
            reset: { var d = settings.defaults(for: model); d.width = nil; settings.updateDefaults(d, for: model) }
        )
    }

    private func heightPicker(model: FluxModelVariant, current: Int?) -> some View {
        dimensionRow(
            label: "Height", model: model, current: current,
            get: \.height,
            set: { var d = settings.defaults(for: model); d.height = $0; settings.updateDefaults(d, for: model) },
            reset: { var d = settings.defaults(for: model); d.height = nil; settings.updateDefaults(d, for: model) }
        )
    }

    // swiftlint:disable:next function_parameter_count
    private func dimensionRow(
        label: String, model: FluxModelVariant, current: Int?,
        get: KeyPath<ModelDefaults, Int?>,
        set: @escaping (Int) -> Void,
        reset: @escaping () -> Void
    ) -> some View {
        let bound = Binding<Int>(
            get: { current ?? 1024 },
            set: { set($0) }
        )
        return HStack {
            DimensionSliderRow(label: label, value: bound)
            if current != nil {
                resetButton(reset)
            }
        }
        .accessibilityLabel("Default \(label.lowercased()) for \(model.displayName)")
    }

    @ViewBuilder
    private func loraOverrideSection(model: FluxModelVariant, current: [LoraEntry]?) -> some View {
        let globals = settings.defaultLoras
        if globals.isEmpty {
            Text("No LoRAs configured. Add them in the LoRAs tab.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            VStack(spacing: 6) {
                ForEach(globals) { global in
                    let eff = current?.first { $0.path == global.path } ?? global
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { eff.enabled },
                                set: { v in setLoraEnabled(v, path: global.path, model: model, globals: globals, current: current) }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .scaleEffect(0.7)
                            .frame(width: 32, height: 20)
                            Text(global.displayName)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack(spacing: 6) {
                            Slider(value: Binding(
                                get: { eff.strength },
                                set: { v in setLoraStrength(v, path: global.path, model: model, globals: globals, current: current) }
                            ), in: 0...2)
                            Text(String(format: "%.2f", eff.strength))
                                .font(.caption2)
                                .monospacedDigit()
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                    .padding(8)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
                }
                if current != nil {
                    HStack {
                        Spacer()
                        Button("Reset to LoRAs tab defaults") {
                            var d = settings.defaults(for: model)
                            d.loras = nil
                            settings.updateDefaults(d, for: model)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func setLoraEnabled(
        _ enabled: Bool, path: String, model: FluxModelVariant,
        globals: [LoraEntry], current: [LoraEntry]?
    ) {
        var list = current ?? globals
        if let idx = list.firstIndex(where: { $0.path == path }) {
            list[idx].enabled = enabled
        } else if let global = globals.first(where: { $0.path == path }) {
            var entry = global; entry.enabled = enabled; list.append(entry)
        }
        var d = settings.defaults(for: model); d.loras = list
        settings.updateDefaults(d, for: model)
    }

    private func setLoraStrength(
        _ strength: Double, path: String, model: FluxModelVariant,
        globals: [LoraEntry], current: [LoraEntry]?
    ) {
        let rounded = round(strength / 0.05) * 0.05
        var list = current ?? globals
        if let idx = list.firstIndex(where: { $0.path == path }) {
            list[idx].strength = rounded
        } else if let global = globals.first(where: { $0.path == path }) {
            var entry = global; entry.strength = rounded; list.append(entry)
        }
        var d = settings.defaults(for: model); d.loras = list
        settings.updateDefaults(d, for: model)
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

    // MARK: - Model caching

    private func startCache(model: FluxModelVariant, quantize: Int) {
        cachePhase = .running
        cacheLog = ""
        userCancelledCache = false
        Task { await runMfluxSave(model: model, quantize: quantize) }
    }

    private func runMfluxSave(model: FluxModelVariant, quantize: Int) async {
        let saveBinary = BinaryDetector.mfluxSave(in: settings.mfluxBinaryDir)
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

        for await chunk in stream { cacheLog = appendCacheLog(chunk, to: cacheLog) }
        process.waitUntilExit()
        cacheProcess = nil

        if process.terminationStatus == 0 {
            let savedFiles = (try? FileManager.default.contentsOfDirectory(
                at: savePath, includingPropertiesForKeys: nil))?.map(\.lastPathComponent) ?? []
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
                while idx < chunk.endIndex && !chunk[idx].isLetter { idx = chunk.index(after: idx) }
                guard idx < chunk.endIndex else { continue }
                let cmd = chunk[idx]
                idx = chunk.index(after: idx)
                if cmd == "A" {
                    // Cursor up: remove current line and the \n above it, moving to end of previous line
                    if let nl = result.lastIndex(of: "\n") {
                        result = String(result[result.startIndex..<nl])
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

    private func browseModelDir(binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.title = "Select Model Directory"
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
        }
    }

    // A small × button to clear an override back to the model default
    private func resetButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Reset to built-in default")
        .accessibilityLabel("Reset to built-in default")
    }
}
