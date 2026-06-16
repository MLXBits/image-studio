import SwiftUI

extension Notification.Name {
    static let openSettingsAdvancedTab = Notification.Name("MLXBitsImageStudio.openSettingsAdvancedTab")
}

struct SettingsView: View {
    private enum SetupPhase { case idle, installing, failed(String) }

    enum SettingsTab: String, CaseIterable, Identifiable {
        case generation = "Generation"
        case models = "Models"
        case loras = "LoRAs"
        case advanced = "Advanced"
        var id: String {
            rawValue
        }
    }

    @Environment(AppSettings.self) private var settings
    @Environment(GalleryStore.self) private var gallery
    @State private var selectedTab: SettingsTab = .generation
    @State private var showingOutputDirPrompt: Bool = false
    @State private var mfluxSetupPhase: SetupPhase = .idle
    @State private var loraFamily: ModelFamily = .flux
    @State private var hfTokenDraft: String = ""

    var body: some View {
        TabView(selection: $selectedTab) {
            generationTab
                .tabItem { Label("Generation", systemImage: "wand.and.stars") }
                .tag(SettingsTab.generation)

            ModelDefaultsView()
                .environment(settings)
                .tabItem { Label("Models", systemImage: "cpu") }
                .tag(SettingsTab.models)

            lorasTab
                .tabItem { Label("LoRAs", systemImage: "square.stack.3d.up") }
                .tag(SettingsTab.loras)

            advancedTab
                .tabItem { Label("Advanced", systemImage: "gearshape") }
                .tag(SettingsTab.advanced)
        }
        .frame(width: 560, height: 460)
        .onExitCommand { NSApp.keyWindow?.performClose(nil) }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsAdvancedTab)) { _ in
            selectedTab = .advanced
        }
        .sheet(isPresented: $showingOutputDirPrompt) {
            OutputDirectoryPromptView(isPresented: $showingOutputDirPrompt)
                .environment(settings)
        }
        .alert("Could not save settings", isPresented: Binding(
            get: { settings.saveError != nil },
            set: { if !$0 { settings.saveError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(settings.saveError ?? "")
        }
    }

    // MARK: - Generation

    private var generationTab: some View {
        @Bindable var s = settings
        let mfluxMissing = BinaryDetector.mfluxGenerateFlux2(in: s.mfluxBinaryDir).isEmpty
        return VStack(spacing: 0) {
            if mfluxMissing {
                mfluxSetupBanner
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
            }
            Form {
                Section {
                    Picker("Default model", selection: $s.defaultModel) {
                        ForEach(FluxModelVariant.builtIn, id: \.self) { v in
                            Text(v.displayName).tag(v)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("Steps, guidance, quantize, low RAM, and canvas size are configured per-model in the Models tab.")
                        .font(.caption).foregroundStyle(.tertiary)
                } header: {
                    Text("Model")
                }

                Section {
                    LabeledContent("Batch Size Shortcut") {
                        HStack(spacing: 8) {
                            Picker("", selection: $s.batchShortcutPreset) {
                                Text("3").tag(3)
                                Text("5").tag(5)
                                Text("10").tag(10)
                                Text("Custom").tag(0)
                            }
                            .pickerStyle(.segmented)
                            .fixedSize()
                            if s.batchShortcutPreset == 0 {
                                TextField("", value: $s.batchShortcutCustomCount, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 56)
                                    .onChange(of: s.batchShortcutCustomCount) { _, v in
                                        s.batchShortcutCustomCount = max(2, min(100, v))
                                    }
                            }
                        }
                    }
                    Text("⌘⌥↵ generates this many images at once.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("Iteration")
                }

                Section {
                    HStack {
                        TextField("Output folder", text: $s.outputDir)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse…") { browseOutputDir() }
                        Button {
                            showingOutputDirPrompt = true
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Avoid ~/Pictures and ~/Documents if you don't want iCloud to sync generated images")
                    }
                    if s.outputDir.isEmpty {
                        Label("No output folder set — images won't be saved.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    LabeledContent("Default group") {
                        FolderComboBox(
                            text: $s.defaultBoard,
                            options: gallery.boards.filter { $0 != "Default" },
                            placeholder: "Default"
                        )
                    }
                } header: {
                    Text("Output")
                } footer: {
                    Text("Tip: choose a folder outside ~/Pictures and ~/Documents to avoid automatic iCloud sync of generated images.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .formStyle(.grouped)
        }
    }

    private var mfluxSetupBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("mflux not found")
                    .font(.callout.weight(.medium))
                Text("mflux is required to run generations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch mfluxSetupPhase {
            case .idle:
                Button("Install Automatically") { Task { await installMflux() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

            case .installing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Installing…").font(.caption).foregroundStyle(.secondary)
                }

            case let .failed(msg):
                HStack(spacing: 8) {
                    Text(msg).font(.caption).foregroundStyle(.red).lineLimit(2)
                    Button("Retry") { Task { await installMflux() } }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.25), lineWidth: 1))
    }

    // MARK: - LoRAs

    private var lorasTab: some View {
        @Bindable var s = settings
        let filteredBinding = Binding<[LoraEntry]>(
            get: { s.defaultLoras.filter { $0.modelFamily == loraFamily } },
            set: { updated in
                s.defaultLoras = s.defaultLoras.filter { $0.modelFamily != loraFamily } + updated
            }
        )
        return VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $loraFamily) {
                ForEach(ModelFamily.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text("Default LoRAs are added to every new \(loraFamily.rawValue) generation.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                LoraManagerView(
                    loras: filteredBinding,
                    showNotes: true,
                    alwaysExpanded: true,
                    modelFamily: loraFamily
                )
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .padding()
    }

    // MARK: - Advanced

    private var advancedTab: some View {
        @Bindable var s = settings
        return Form {
            Section("mflux Binary") {
                HStack {
                    TextField("Binary directory", text: $s.mfluxBinaryDir)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse…") { browseBinaryDir() }
                }
                HStack {
                    let path = BinaryDetector.mfluxGenerateFlux2(in: s.mfluxBinaryDir)
                    let exists = !path.isEmpty && FileManager.default.fileExists(atPath: path)
                    Image(systemName: exists ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(exists ? .green : .red)
                    Text(path.isEmpty ? "Not found" : path)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }

            Section("HuggingFace") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        SecureField("Paste token here…", text: $hfTokenDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { settings.hfToken = hfTokenDraft }
                            .onChange(of: hfTokenDraft) { _, v in if !v.isEmpty { settings.hfToken = v } }
                        if !settings.hfToken.isEmpty {
                            Button("Clear") {
                                hfTokenDraft = ""
                                settings.hfToken = ""
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 3) {
                        Text("Required for gated and private models (e.g. Flux.1 Pro). Stored in the system Keychain. Create one at")
                            .font(.caption).foregroundStyle(.secondary)
                        if let tokenURL = URL(string: "https://huggingface.co/settings/tokens") {
                            Link("huggingface.co/settings/tokens", destination: tokenURL)
                                .font(.caption)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
                .onAppear { hfTokenDraft = settings.hfToken }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("", text: $s.hfHome)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse…") { browseHFHome() }
                    }
                    Text("Where HuggingFace caches downloaded model files. Default: ~/.cache/huggingface")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("", text: $s.mfluxCacheDir)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse…") { browseMfluxCacheDir() }
                    }
                    Text("Where mflux stores converted weight files. Default: ~/Library/Caches/mflux")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)

                Toggle("Offline mode (HF_HUB_OFFLINE=1)", isOn: $s.hfOffline)
            }

            Section {
                LabeledContent("Metal cache limit") {
                    HStack(spacing: 4) {
                        TextField("0", value: $s.mlxCacheLimitGB, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                        Text("GB")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("MLX")
            } footer: {
                Text(
                    "Limits how much GPU memory MLX keeps in its buffer pool between operations. " +
                        "0 = unlimited (default). Set to 4–8 GB if other apps are competing for memory."
                )
                .font(.caption).foregroundStyle(.tertiary)
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("mlx-community/gemma-3-12b-it-4bit", text: $s.gemmaModelPath)
                        .textFieldStyle(.roundedBorder)
                    Text(
                        "HF repo ID or local path for the Gemma model used to generate structured Ideogram 4 captions. " +
                            "Requires mlx_lm — install with: uv tool install mlx-lm"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 4) {
                    let uvPath = NSHomeDirectory() + "/.local/bin/uv"
                    let uvFound = FileManager.default.fileExists(atPath: uvPath)
                    HStack(spacing: 6) {
                        Image(systemName: uvFound ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(uvFound ? Color.green : Color.red)
                        Text(uvFound ? "uv found — mlx-lm>=0.31.3 managed automatically" : "uv not found at ~/.local/bin/uv")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 4) {
                    TextField("e.g. ideogram-ai/ideogram-4-fp8", text: Binding(
                        get: { s.ideogram4ModelRepoOverride ?? "" },
                        set: { s.ideogram4ModelRepoOverride = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Text("Override the Ideogram 4 model repo (or path to saved weights). Leave blank to use the default.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            } header: {
                Text("Ideogram 4 / Gemma")
            }

            Section("UI") {
                HStack {
                    Text("Log font size")
                    Slider(value: $s.logFontSize, in: 10 ... 18)
                        .onChange(of: s.logFontSize) { _, v in s.logFontSize = round(v) }
                    Text("\(Int(s.logFontSize))pt").monospacedDigit().frame(width: 35)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

    @MainActor
    private func installMflux() async {
        mfluxSetupPhase = .installing
        do {
            settings.mfluxBinaryDir = try await MfluxInstaller.install()
            mfluxSetupPhase = .idle
        } catch {
            mfluxSetupPhase = .failed(error.localizedDescription)
        }
    }

    private func browseOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.title = "Choose Output Directory"
        if panel.runModal() == .OK, let url = panel.url {
            settings.outputDir = url.path
        }
    }

    private func browseBinaryDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.title = "Choose mflux Binary Directory"
        if panel.runModal() == .OK, let url = panel.url {
            settings.mfluxBinaryDir = url.path
        }
    }

    private func browseHFHome() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.title = "Choose HuggingFace Cache Directory"
        if panel.runModal() == .OK, let url = panel.url {
            settings.hfHome = url.path
        }
    }

    private func browseMfluxCacheDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.title = "Choose mflux Cache Directory"
        if panel.runModal() == .OK, let url = panel.url {
            settings.mfluxCacheDir = url.path
        }
    }
}
