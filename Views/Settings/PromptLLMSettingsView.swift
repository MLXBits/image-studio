import SwiftUI

/// The "Prompt LLM" settings section, shared by both Gemma-powered features —
/// Ideogram 4 caption generation and the Scenario Generator (Flux/Krea 2 prompt
/// panels). Chooses between running Gemma locally (via `uv`/`mlx_lm`) and an
/// OpenAI-compatible HTTP endpoint (e.g. LM Studio), and lets the user test the
/// endpoint and pick a model. Rendered inside the Advanced tab's `Form`.
struct PromptLLMSettingsView: View {
    /// State of the "Test Connection" probe against the endpoint.
    private enum ConnectionPhase { case idle, testing, ok(Int), failed(String) }

    @Environment(AppSettings.self) private var settings
    @State private var apiKeyDraft: String = ""
    @State private var discoveredModels: [String] = []
    @State private var connectionPhase: ConnectionPhase = .idle

    var body: some View {
        @Bindable var s = settings
        Section {
            Picker("Backend", selection: $s.llmBackend) {
                ForEach(LLMBackendKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .padding(.vertical, 2)

            switch s.llmBackend {
            case .local:
                localFields
            case .remote:
                remoteFields
            }
        } header: {
            Text("Prompt LLM")
        } footer: {
            Text(
                "Powers the Scenario Generator in the Flux and Krea 2 prompt panels, "
                    + "and generates the structured captions Ideogram 4 expects."
            )
            .font(.caption).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Local Gemma

    @ViewBuilder
    private var localFields: some View {
        @Bindable var s = settings
        let uvPath = NSHomeDirectory() + "/.local/bin/uv"
        let uvFound = FileManager.default.fileExists(atPath: uvPath)
        VStack(alignment: .leading, spacing: 4) {
            TextField("mlx-community/gemma-3-12b-it-4bit", text: $s.gemmaModelPath)
                .textFieldStyle(.roundedBorder)
            Text(
                "HF repo ID or local path for the Gemma model. "
                    + "Requires mlx_lm — install with: uv tool install mlx-lm"
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)

        HStack(spacing: 6) {
            Image(systemName: uvFound ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(uvFound ? Color.green : Color.red)
            Text(
                uvFound
                    ? "uv found — \(GemmaChatRunner.mlxLMRequirement) / \(GemmaChatRunner.mlxVLMRequirement) "
                    + "managed automatically"
                    : "uv not found at ~/.local/bin/uv"
            )
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Remote endpoint

    @ViewBuilder
    private var remoteFields: some View {
        @Bindable var s = settings
        VStack(alignment: .leading, spacing: 4) {
            TextField("http://localhost:1234/v1", text: $s.openAIBaseURL)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            Text("Base URL of an OpenAI-compatible endpoint (e.g. LM Studio).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)

        modelField(s)

        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Temperature") {
                TextField("", value: $s.openAITemperature, format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                    .onChange(of: s.openAITemperature) { _, v in
                        s.openAITemperature = min(2, max(0, v))
                    }
            }
            LabeledContent("Top P") {
                TextField("", value: $s.openAITopP, format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                    .onChange(of: s.openAITopP) { _, v in
                        s.openAITopP = min(1, max(0, v))
                    }
            }
            LabeledContent("Top K") {
                TextField("", value: $s.openAITopK, format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                    .onChange(of: s.openAITopK) { _, v in
                        s.openAITopK = max(0, v)
                    }
            }
            Text("Sampling parameters sent to the endpoint. Gemma recommends "
                + "temperature 1.0, Top P 0.95, Top K 64. Top K 0 omits the field.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SecureField("API key (optional)", text: $apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { settings.openAIAPIKey = apiKeyDraft }
                    .onChange(of: apiKeyDraft) { _, v in settings.openAIAPIKey = v }
                if !settings.openAIAPIKey.isEmpty {
                    Button("Clear") {
                        apiKeyDraft = ""
                        settings.openAIAPIKey = ""
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
            Text("Leave blank for LM Studio. Stored in the system Keychain.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .onAppear { apiKeyDraft = settings.openAIAPIKey }

        HStack(spacing: 8) {
            Button("Test Connection") { testConnection() }
                .disabled(isTesting)
            connectionStatusRow
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var connectionStatusRow: some View {
        switch connectionPhase {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting…").font(.caption).foregroundStyle(.secondary)
            }
        case let .ok(count):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Connected — \(count) model\(count == 1 ? "" : "s") available")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case let .failed(message):
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.tail)
            }
        }
    }

    private var isTesting: Bool {
        if case .testing = connectionPhase { return true }
        return false
    }

    @ViewBuilder
    private func modelField(_ s: AppSettings) -> some View {
        @Bindable var s = s
        VStack(alignment: .leading, spacing: 4) {
            if discoveredModels.isEmpty {
                TextField("Model id (e.g. as shown in LM Studio)", text: $s.openAIModel)
                    .textFieldStyle(.roundedBorder)
            } else {
                Picker("Model", selection: $s.openAIModel) {
                    // Keep a current value that isn't in the fetched list visible.
                    if !s.openAIModel.isEmpty, !discoveredModels.contains(s.openAIModel) {
                        Text(s.openAIModel).tag(s.openAIModel)
                    }
                    ForEach(discoveredModels, id: \.self) { id in
                        Text(id).tag(id)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .padding(.vertical, 2)
    }

    /// Probes the endpoint's `GET /v1/models`, updating the status row and
    /// populating the model picker on success.
    private func testConnection() {
        connectionPhase = .testing
        let baseURL = settings.openAIBaseURL
        let apiKey = settings.openAIAPIKey
        Task {
            do {
                let models = try await OpenAIChatClient.fetchModels(baseURL: baseURL, apiKey: apiKey)
                discoveredModels = models
                connectionPhase = .ok(models.count)
                if settings.openAIModel.isEmpty, let first = models.first {
                    settings.openAIModel = first
                }
            } catch {
                connectionPhase = .failed(error.localizedDescription)
            }
        }
    }
}
