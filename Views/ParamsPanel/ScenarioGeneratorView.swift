import AppKit
import SwiftUI

/// State for one scenario-generator session, owned by the button (not the
/// popover) so accidentally clicking out loses nothing — inputs, results,
/// and even an in-flight generation survive the popover closing and are
/// restored when it reopens.
@Observable
@MainActor
final class ScenarioSession {
    var outline: String = ""
    var categories: Set<ScenarioCategory> = []
    var wildcardMode: Bool = false
    var isGenerating: Bool = false
    var result: String = ""
    var generateError: String?
    var lastGemmaLog: String = ""
    var hasSeeded: Bool = false
    var task: Task<Void, Never>?
    let generator = ScenarioGenerator()
}

/// Popover that expands a rough outline into a full image prompt via local
/// Gemma (``ScenarioGenerator``). "Use" hands the result back through
/// `onSelect`; behavior is tuned by editing the system-prompt file surfaced
/// by "Edit System Prompt…".
struct ScenarioGeneratorView: View {
    @Bindable var session: ScenarioSession
    let onSelect: (String) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var showGemmaLog: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // No outer ScrollView: the popover sizes to content and grows when
            // the result appears. The result and error boxes cap their own
            // height internally, so total height stays bounded.
            VStack(alignment: .leading, spacing: 10) {
                outlineSection
                categorySection
                wildcardRow
                generateRow
                if let err = session.generateError { errorBox(err) }
                if !session.result.isEmpty { resultPreview }
            }
            .padding(12)
            Divider()
            footer
        }
        .frame(width: 400)
        .onExitCommand { dismiss() }
        .onAppear {
            guard !session.hasSeeded else { return }
            session.hasSeeded = true
            session.outline = settings.lastScenarioOutline
            session.categories = settings.scenarioCategories
            session.wildcardMode = settings.scenarioWildcardMode
        }
        // Persist inputs as they change (save is debounced), so nothing is
        // lost across popover dismissals or app relaunches.
        .onChange(of: session.outline) { _, value in settings.lastScenarioOutline = value }
        .onChange(of: session.categories) { _, value in settings.scenarioCategories = value }
        .onChange(of: session.wildcardMode) { _, value in settings.scenarioWildcardMode = value }
        // Free the warm LLM when the popover closes (kept resident across
        // re-rolls while it's open, so only the first generation loads cold).
        .onDisappear { session.generator.shutdown() }
        .sheet(isPresented: $showGemmaLog) { gemmaLogSheet }
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack {
            Text("Scenario Generator")
                .font(.headline)
            Spacer()
            if !session.lastGemmaLog.isEmpty {
                Button {
                    showGemmaLog = true
                } label: {
                    Image(systemName: "text.alignleft")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .foregroundStyle(.secondary)
                .help("Show Gemma generation log")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Button("Edit System Prompt…") {
                try? ScenarioPromptConfig.seedIfNeeded()
                NSWorkspace.shared.open(ScenarioPromptConfig.userConfigURL)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("The editable prompt file governs what the model will write")
            Spacer()
            Button("Reroll") { startGenerate() }
                .disabled(session.isGenerating || session.result.isEmpty)
            Button("Use") {
                onSelect(session.result)
                dismiss()
            }
            .keyboardShortcut(.return, modifiers: [])
            .buttonStyle(.borderedProminent)
            .disabled(session.result.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Content sections

    private var outlineSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Outline")
                .font(.caption2).fontWeight(.medium).foregroundStyle(.secondary)
            GrowingPromptField(
                text: $session.outline,
                placeholder: "Rough concept — e.g. two people, candlelit bedroom, after a party…",
                label: "Scenario outline",
                hint: "A rough concept the generator expands into a full prompt"
            )
        }
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Text("Invent details for")
                    .font(.caption2).fontWeight(.medium).foregroundStyle(.secondary)
                InfoButton(
                    title: "Detail Categories",
                    description: "Checked categories are invented/diversified by the model. "
                        + "Unchecked ones appear only when your outline specifies them."
                )
            }
            LazyVGrid(
                columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                alignment: .leading, spacing: 4
            ) {
                ForEach(ScenarioCategory.allCases) { category in
                    Toggle(category.label, isOn: categoryBinding(category))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
            }
        }
    }

    private var wildcardRow: some View {
        HStack(spacing: 3) {
            Toggle("Emit {a|b|c} wildcard variations", isOn: $session.wildcardMode)
                .toggleStyle(.checkbox)
                .font(.caption)
            InfoButton(
                title: "Wildcard Variations",
                description: "The generated prompt wraps diversifiable details in {a|b|c} groups. "
                    + "Generate then runs one job per option of the largest group (up to 10), "
                    + "walking the options in order."
            )
        }
    }

    private var generateRow: some View {
        HStack(spacing: 8) {
            Button {
                startGenerate()
            } label: {
                HStack(spacing: 6) {
                    if session.isGenerating {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(session.isGenerating ? "Generating…" : "Generate")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(session.isGenerating || session.outline.trimmingCharacters(in: .whitespaces).isEmpty)

            if session.isGenerating {
                Button("Cancel") { session.task?.cancel() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var resultPreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Result")
                .font(.caption2).fontWeight(.medium).foregroundStyle(.secondary)
            // A DEFINITE height (not maxHeight — that collapses a ScrollView to
            // nothing) reserves the region and scrolls overflow, so long prompts
            // stay readable without the popover clipping past AppKit's max.
            ScrollView {
                Text(session.result)
                    .font(.caption)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(height: 200)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            if session.wildcardMode, !WildcardExpander.containsWildcards(session.result) {
                Text("No valid {a|b|c} groups in this result — it will run as a single prompt.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var gemmaLogSheet: some View {
        NavigationStack {
            ScrollView {
                Text(session.lastGemmaLog)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Gemma Log")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showGemmaLog = false }
                }
            }
        }
        .frame(width: 680, height: 500)
    }

    // MARK: - Actions

    private func errorBox(_ message: String) -> some View {
        ScrollView {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        }
        .frame(height: 100)
        .background(Color.red.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func categoryBinding(_ category: ScenarioCategory) -> Binding<Bool> {
        Binding(
            get: { session.categories.contains(category) },
            set: { on in
                if on { session.categories.insert(category) } else { session.categories.remove(category) }
            }
        )
    }

    private func startGenerate() {
        let session = session
        session.isGenerating = true
        session.generateError = nil
        session.task = Task {
            defer {
                session.isGenerating = false
                session.task = nil
            }
            do {
                let prompt = try await session.generator.generate(
                    outline: session.outline,
                    categories: session.categories,
                    wildcardMode: session.wildcardMode,
                    settings: settings
                )
                session.lastGemmaLog = session.generator.lastLog
                session.result = prompt
            } catch is CancellationError {
                session.lastGemmaLog = session.generator.lastLog
            } catch {
                session.lastGemmaLog = session.generator.lastLog
                session.generateError = error.localizedDescription
            }
        }
    }
}

/// The sparkle-wand affordance that opens the scenario generator; lives in
/// the Prompt section header (Flux and Krea 2 panels) beside the history
/// button. Owns the session so popover dismissal never loses state.
struct ScenarioGeneratorButton: View {
    let onSelect: (String) -> Void

    @State private var session = ScenarioSession()
    @State private var showingGenerator: Bool = false

    var body: some View {
        Button { showingGenerator = true } label: {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 10))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Scenario generator")
        .popover(isPresented: $showingGenerator) {
            ScenarioGeneratorView(session: session, onSelect: onSelect)
        }
    }
}
