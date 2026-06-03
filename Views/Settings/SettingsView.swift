import SwiftUI

extension Notification.Name {
    static let openSettingsAdvancedTab = Notification.Name("MLXBitsImageStudio.openSettingsAdvancedTab")
}

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(GalleryStore.self) private var gallery
    @State private var selectedTab: SettingsTab = .generation
    @State private var showingOutputDirPrompt: Bool = false

    enum SettingsTab: String, CaseIterable, Identifiable {
        case generation = "Generation"
        case models = "Models"
        case loras = "LoRAs"
        case advanced = "Advanced"
        var id: String { rawValue }
    }

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
    }

    // MARK: - Generation

    private var generationTab: some View {
        @Bindable var s = settings
        return Form {
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

    // MARK: - LoRAs

    private var lorasTab: some View {
        @Bindable var s = settings
        return VStack(alignment: .leading, spacing: 8) {
            Text("Default LoRAs are added to every new generation.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LoraManagerView(loras: $s.defaultLoras, showNotes: true, alwaysExpanded: true)
                .frame(maxHeight: .infinity, alignment: .top)
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

            Section {
                LabeledContent("HF_TOKEN") {
                    SecureField("Hugging Face access token", text: $s.hfToken)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("HF_HOME") {
                    TextField("default (~/.cache/huggingface)", text: $s.hfHome)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("MFLUX_CACHE_DIR") {
                    TextField("default (~/Library/Caches/mflux)", text: $s.mfluxCacheDir)
                        .textFieldStyle(.roundedBorder)
                }
                Toggle("Offline mode (HF_HUB_OFFLINE=1)", isOn: $s.hfOffline)
            } header: {
                Text("HuggingFace")
            } footer: {
                Text(
                    "HF_TOKEN grants access to gated/private models. Stored in the system Keychain. " +
                    "HF_HOME is where HuggingFace caches model files (default: ~/.cache/huggingface). " +
                    "MFLUX_CACHE_DIR is where mflux stores converted weight files (default: ~/Library/Caches/mflux). " +
                    "Leave blank to use the system defaults."
                )
                .font(.caption).foregroundStyle(.tertiary)
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

            Section("UI") {
                HStack {
                    Text("Log font size")
                    Slider(value: $s.logFontSize, in: 10...18)
                        .onChange(of: s.logFontSize) { _, v in s.logFontSize = round(v) }
                    Text("\(Int(s.logFontSize))pt").monospacedDigit().frame(width: 35)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

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
}
