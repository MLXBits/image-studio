import AppKit
import SwiftUI

/// Settings → Advanced → Python (spec §3): the bundled runtime the app runs
/// on, and, in the DMG build, the Custom Python override for mflux.
struct PythonSettingsSection: View {
    private enum CustomStatus: Equatable {
        case unchecked
        case checking
        case found(String)
        case noMflux
    }

    @Environment(AppSettings.self) private var settings
    @State private var customStatus = CustomStatus.unchecked
    /// The field's text, committed on Return, on leaving the field or on closing
    /// Settings. Committing per keystroke rebuilt the toolchain for every
    /// partial path, flashed "not found" and probed any that was executable.
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool
    /// Bumped on Return and on Browse, so re-picking the same path checks again.
    @State private var recheck = 0

    var body: some View {
        Section("Python") {
            bundledRow
            if !BuildFlavor.isAppStore {
                customPythonRow
            }
        }
        .task(id: "\(settings.toolchain.customPython)#\(recheck)") { await checkCustomPython() }
    }

    private var bundledRow: some View {
        HStack(spacing: 6) {
            if let manifest = RuntimeManifest.bundled {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Bundled Python \(manifest.python) · mflux \(manifest.version(of: "mflux") ?? "unknown")")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text(ToolchainError.runtimeMissing.localizedDescription)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var customPythonRow: some View {
        @Bindable var s = settings
        VStack(alignment: .leading, spacing: 4) {
            Text("Custom Python (advanced)")
            HStack {
                // A prompt, not a title: in a grouped Form a title renders as its own label line.
                TextField("Custom Python", text: $draft, prompt: Text("Bundled (default)"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .focused($fieldFocused)
                    .onSubmit {
                        commitDraft()
                        recheck += 1
                    }
                    .onChange(of: fieldFocused) { _, focused in
                        guard !focused else { return }
                        commitDraft()
                    }
                Button("Browse…") { browse() }
                if !s.customPythonPath.isEmpty {
                    Button("Use Bundled") { s.customPythonPath = "" }
                }
            }
            Text(
                "Runs mflux and the warm model driver with another interpreter, such as a dev "
                    + "checkout's .venv/bin/python. Captions and the Scenario Generator always use the bundled Python."
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            customStatusRow
        }
        .padding(.vertical, 2)
        .onAppear { draft = settings.customPythonPath }
        .onChange(of: settings.customPythonPath) { _, path in draft = path }
        .onDisappear { commitDraft() }
    }

    @ViewBuilder private var customStatusRow: some View {
        if case let .customPythonMissing(path)? = settings.toolchain.problem {
            statusLine(ok: false, ToolchainError.customPythonMissing(path).localizedDescription)
        } else {
            switch customStatus {
            case .unchecked:
                EmptyView()
            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking…").font(.caption).foregroundStyle(.secondary)
                }
            case let .found(version):
                statusLine(ok: true, "mflux \(version)")
            case .noMflux:
                statusLine(ok: false, "No mflux in this Python. Install it there, or use the bundled one.")
            }
        }
    }

    private func statusLine(ok: Bool, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? Color.green : Color.red)
            Text(text).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle)
        }
    }

    private func commitDraft() {
        if draft != settings.customPythonPath {
            settings.customPythonPath = draft
        }
    }

    private func checkCustomPython() async {
        let toolchain = settings.toolchain
        let python = toolchain.customPython
        guard !python.isEmpty, (try? toolchain.mfluxInterpreter()) == python else {
            customStatus = .unchecked
            return
        }
        customStatus = .checking
        // Asked afresh, not from the launch's cache: mflux may have been installed
        // there since, and re-picking the path is how to say so.
        let version = await Task.detached(priority: .utility) {
            MfluxProbes.forget(python: python)
            return MfluxProbes.mfluxVersion(python: python)
        }.value
        // The path changed while the probe ran: a newer check owns the status.
        guard !Task.isCancelled else { return }
        customStatus = version.map(CustomStatus.found) ?? .noMflux
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Python Interpreter"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true // .venv is hidden
        panel.treatsFilePackagesAsDirectories = true
        // A venv's bin/python is a symlink to its base interpreter; resolving
        // it would drop the venv, and the mflux installed in it.
        panel.resolvesAliases = false
        if panel.runModal() == .OK, let url = panel.url {
            settings.customPythonPath = url.path
            recheck += 1
        }
    }
}
