import SwiftUI

/// The "Prompt LLM" settings section, shared by both Gemma-powered features —
/// Ideogram 4 caption generation and the Scenario Generator (Flux/Krea 2 prompt
/// panels). Chooses between running Gemma locally (via `uv`/`mlx_lm`) and an
/// OpenAI-compatible HTTP endpoint (e.g. LM Studio), and lets the user test the
/// endpoint and pick a model from the list it serves (loaded automatically). Rendered inside the Advanced tab's `Form`.
struct PromptLLMSettingsView: View {
    /// State of the "Test Connection" probe against the endpoint.
    private enum ConnectionPhase { case idle, testing, ok(Int), failed(String) }

    @Environment(AppSettings.self) private var settings
    @State private var apiKeyDraft: String = ""
    @State private var discoveredModels: [String] = []
    @State private var isFetchingModels = false
    @State private var modelFetchFailed = false
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

            // Temperature governs sampling on both backends, so it lives outside the
            // switch — the endpoint-only Top P / Top K stay in `remoteFields`.
            temperatureField(s)
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
        let uvPath = GemmaChatRunner.uvPath
        let uvFound = !uvPath.isEmpty
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
                    ? "uv found at \(uvPath) — \(GemmaChatRunner.mlxLMRequirement) / "
                    + "\(GemmaChatRunner.mlxVLMRequirement) managed automatically"
                    : "uv not found — install from https://docs.astral.sh/uv/ (or: brew install uv)"
            )
            .font(.caption).foregroundStyle(.secondary)
            // Tail, not middle: the resolved path now sits at the head of the
            // string and middle truncation would eat exactly that.
            .lineLimit(1).truncationMode(.tail)
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
            Text("Endpoint-only sampling parameters. Gemma recommends "
                + "Top P 0.95, Top K 64. Top K 0 omits the field.")
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
        if case .testing = connectionPhase {
            return true
        }
        return false
    }

    /// Sampling temperature, shown for both backends — it drives `make_sampler` on the
    /// local path and the endpoint's `temperature` on the remote one. Raising it (~1.1)
    /// is what makes the Scenario Generator's queued rolls diverge.
    @ViewBuilder
    private func temperatureField(_ s: AppSettings) -> some View {
        @Bindable var s = s
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Temperature") {
                TextField("", value: $s.llmTemperature, format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                    .onChange(of: s.llmTemperature) { _, v in
                        s.llmTemperature = min(2, max(0, v))
                    }
            }
            Text("Sampling temperature for the Scenario Generator. Gemma recommends 1.0; "
                + "raise it (~1.1) so queued prompt rolls vary.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func modelField(_ s: AppSettings) -> some View {
        @Bindable var s = s
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
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
                if isFetchingModels {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await refreshModels() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Reload the model list from the endpoint")
                }
            }
            if modelFetchFailed, !isFetchingModels {
                Text("Couldn't list models from this endpoint — enter the id by hand.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        // Load the model list as soon as an endpoint is configured, and again after
        // the URL or key stops changing — debounced so typing doesn't fire a request
        // per keystroke. Changing the id cancels the pending sleep.
        .task(id: "\(s.openAIBaseURL)\n\(settings.openAIAPIKey)") {
            if !isTesting {
                connectionPhase = .idle
            } // status described the old endpoint
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await refreshModels()
        }
    }

    /// Fetches `GET /v1/models` for the current endpoint into the model picker without
    /// touching the Test Connection status. A failure clears the list — it belonged to
    /// whatever endpoint was configured before — so the hand-entry field comes back.
    private func refreshModels() async {
        let baseURL = settings.openAIBaseURL.trimmingCharacters(in: .whitespaces)
        guard !baseURL.isEmpty else {
            discoveredModels = []
            modelFetchFailed = false
            return
        }
        isFetchingModels = true
        defer { isFetchingModels = false }
        let models = try? await OpenAIChatClient.fetchModels(baseURL: baseURL, apiKey: settings.openAIAPIKey)
        // Drop a stale result if the endpoint changed while the request was in flight.
        guard !Task.isCancelled, baseURL == settings.openAIBaseURL.trimmingCharacters(in: .whitespaces) else {
            return
        }
        discoveredModels = models ?? []
        modelFetchFailed = models == nil
        if settings.openAIModel.isEmpty, let first = models?.first {
            settings.openAIModel = first
        }
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
                modelFetchFailed = false
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
