import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var selectedTab: SettingsTab = .generation

    enum SettingsTab: String, CaseIterable, Identifiable {
        case generation = "Generation"
        case loras = "LoRAs"
        case advanced = "Advanced"
        var id: String { rawValue }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            generationTab
                .tabItem { Label("Generation", systemImage: "wand.and.stars") }
                .tag(SettingsTab.generation)

            lorasTab
                .tabItem { Label("LoRAs", systemImage: "square.stack.3d.up") }
                .tag(SettingsTab.loras)

            advancedTab
                .tabItem { Label("Advanced", systemImage: "gearshape") }
                .tag(SettingsTab.advanced)
        }
        .padding()
        .frame(width: 500, height: 420)
    }

    // MARK: - Generation

    private var generationTab: some View {
        @Bindable var s = settings
        return Form {
            Section("Defaults") {
                Picker("Model", selection: $s.defaultModel) {
                    ForEach(FluxModelVariant.builtIn, id: \.self) { v in
                        Text(v.displayName).tag(v)
                    }
                }

                Picker("Quantize", selection: $s.defaultQuantize) {
                    Text("BF16 (no quantize)").tag(0)
                    Text("Q8").tag(8)
                    Text("Q4").tag(4)
                }

                Stepper("Width: \(s.defaultWidth)", value: $s.defaultWidth, in: 64...2048, step: 64)
                Stepper("Height: \(s.defaultHeight)", value: $s.defaultHeight, in: 64...2048, step: 64)
                Stepper("Steps: \(s.defaultSteps)", value: $s.defaultSteps, in: 1...150)

                HStack {
                    Text("Guidance")
                    Slider(value: $s.defaultGuidance, in: 1.0...15.0, step: 0.5)
                    Text(String(format: "%.1f", s.defaultGuidance))
                        .monospacedDigit().frame(width: 35)
                }

                Toggle("Low RAM mode by default", isOn: $s.defaultLowRam)
            }

            Section("Output") {
                HStack {
                    TextField("Output directory", text: $s.outputDir)
                    Button("Browse…") { browseOutputDir() }
                }
                TextField("Default board", text: $s.defaultBoard)
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

            LoraManagerView(loras: $s.defaultLoras)
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
                TextField("HF_HOME override (blank = default)", text: $s.hfHome)
                TextField("MFLUX_CACHE_DIR override (blank = default)", text: $s.mfluxCacheDir)
                Toggle("Offline mode (HF_HUB_OFFLINE=1)", isOn: $s.hfOffline)
            }

            Section("MLX") {
                HStack {
                    Text("Cache limit (GB, 0 = unlimited)")
                    Spacer()
                    TextField("0", value: $s.mlxCacheLimitGB, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                }
            }

            Section("UI") {
                HStack {
                    Text("Log font size")
                    Slider(value: $s.logFontSize, in: 10...18, step: 1)
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
