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
    /// Closes the hosting floating panel (the window titlebar's close button and the
    /// "Use" action both route through here).
    var onClose: () -> Void = {}

    @Environment(AppSettings.self) private var settings

    @State private var showGemmaLog: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // The window titlebar carries the "Scenario Generator" name, so the only
            // in-view chrome is the Gemma-log button — shown once a log exists.
            if !session.lastGemmaLog.isEmpty {
                gemmaLogBar
                Divider()
            }
            // The content scrolls so the auto-growing Outline and Result fields can
            // expand with their text without ever clipping the pinned footer.
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    outlineSection
                    categorySection
                    wildcardRow
                    generatingRow
                    if let err = session.generateError { errorBox(err) }
                    if !session.result.isEmpty { resultPreview }
                }
                .padding(12)
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onExitCommand { onClose() }
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
        // The warm LLM is freed when the panel closes — see ScenarioPanelController's
        // windowWillClose, which fires reliably even when the panel is only ordered out.
        .sheet(isPresented: $showGemmaLog) { gemmaLogSheet }
    }

    // MARK: - Header / footer

    private var gemmaLogBar: some View {
        HStack {
            Spacer()
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
            Button("Generate") { startGenerate() }
                .disabled(session.isGenerating || session.outline.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Use") {
                onSelect(session.result)
                onClose()
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

    /// Progress + cancel indicator shown only while generating. The Generate action
    /// itself lives in the footer (a single button that also re-rolls).
    @ViewBuilder
    private var generatingRow: some View {
        if session.isGenerating {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Generating…")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Cancel") { session.task?.cancel() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var resultPreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Result")
                .font(.caption2).fontWeight(.medium).foregroundStyle(.secondary)
            // Same auto-growing editor as the Outline: it expands with the generated
            // text (the surrounding ScrollView absorbs overflow) and stays editable so
            // the expanded prompt can be tweaked before "Use".
            GrowingPromptField(
                text: $session.result,
                placeholder: "",
                label: "Generated scenario",
                hint: "The expanded prompt — edit before using it if you like",
                minHeight: 80
            )
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
/// button. Owns the session so closing the window never loses state, and the
/// controller so a click toggles the floating panel.
struct ScenarioGeneratorButton: View {
    let onSelect: (String) -> Void

    @Environment(AppSettings.self) private var settings
    @State private var session = ScenarioSession()
    @State private var controller = ScenarioPanelController()

    var body: some View {
        Button {
            controller.toggle(session: session, settings: settings, onSelect: onSelect)
        } label: {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 10))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Scenario generator")
    }
}

/// Hosts the scenario generator in a floating utility panel rather than a popover, so
/// it stays open beside the params while you tweak and re-roll. One controller per
/// button; the panel is reused (never released) so a click toggles it, and closing it
/// frees the warm Gemma model.
@MainActor
final class ScenarioPanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private weak var session: ScenarioSession?

    func toggle(session: ScenarioSession, settings: AppSettings, onSelect: @escaping (String) -> Void) {
        if let panel {
            if panel.isVisible { panel.close() } else { attachAndShow(panel) }
            return
        }
        self.session = session
        let root = ScenarioGeneratorView(
            session: session,
            onSelect: { [weak self] text in
                onSelect(text)
                self?.panel?.close()
            },
            onClose: { [weak self] in self?.panel?.close() }
        )
        .environment(settings)

        // A resizable panel with a fixed default size — NOT NSHostingController's
        // `.preferredContentSize` auto-sizing, which resizes the window mid display
        // cycle and throws in `_postWindowNeedsUpdateConstraints` (hard crash).
        let hosting = NSHostingController(rootView: root)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 640),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Scenario Generator"
        // Added as a child of the main app window (see attachAndShow): it stays above the
        // app's own windows but, at normal level, recedes behind other apps when you switch
        // away — unlike `.floating`, which keeps it above every app (e.g. over VS Code).
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.minSize = NSSize(width: 380, height: 420)
        panel.contentViewController = hosting
        panel.delegate = self
        panel.center()
        panel.setFrameAutosaveName("ScenarioGeneratorPanel")
        self.panel = panel
        attachAndShow(panel)
    }

    /// Attaches the panel as a child of the app's main window so it floats above the app
    /// but not other applications, then brings it forward. Re-attaches on reopen because
    /// closing a child window detaches it from its parent.
    private func attachAndShow(_ panel: NSPanel) {
        if panel.parent == nil,
           let parent = NSApp.mainWindow ?? NSApp.keyWindow
           ?? NSApp.windows.first(where: { $0.isVisible && $0 !== panel }) {
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    /// Fires on both the titlebar close button and programmatic `close()`, so the warm
    /// LLM is always released (kept resident across re-rolls only while the panel is up).
    func windowWillClose(_: Notification) {
        session?.generator.shutdown()
    }
}
