import SwiftUI

/// Searchable list of previously queued prompts (recorded in
/// ``AppSettings/promptHistory``). Selecting a row hands the prompt back via
/// `onSelect` and dismisses. Pinned entries sort first and survive the cap.
struct PromptHistoryPickerView: View {
    let onSelect: (String) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var searchText: String = ""

    private var displayedEntries: [PromptHistoryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let entries = query.isEmpty
            ? settings.promptHistory
            : settings.promptHistory.filter { $0.prompt.localizedCaseInsensitiveContains(query) }
        return entries.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            return $0.lastUsedAt > $1.lastUsedAt
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            pickerHeader
            Divider()
            if settings.promptHistory.isEmpty {
                emptyState
            } else {
                entryList
            }
            Divider()
            pickerFooter
        }
        .frame(width: 360)
        .onExitCommand { dismiss() }
    }

    // MARK: - Header

    private var pickerHeader: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Prompt History")
                    .font(.headline)
                Spacer()
                if settings.promptHistory.contains(where: { !$0.pinned }) {
                    Button("Clear") { settings.promptHistory.removeAll { !$0.pinned } }
                        .font(.caption2)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove all unpinned prompts")
                }
            }
            if !settings.promptHistory.isEmpty {
                TextField("Search prompts…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Footer

    private var pickerFooter: some View {
        HStack {
            Text("Prompts are saved when a job is queued")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - List

    private var emptyState: some View {
        Text("No prompts yet — generate an image and its prompt will appear here.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
    }

    private var entryList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(displayedEntries) { entry in
                    entryRow(entry)
                }
                if displayedEntries.isEmpty {
                    Text("No prompts match “\(searchText)”")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 420)
    }

    private func entryRow(_ entry: PromptHistoryEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.prompt)
                    .font(.callout)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(entry.lastUsedAt, format: .relative(presentation: .named))
                    if entry.useCount > 1 {
                        Text("· used \(entry.useCount)×")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                togglePin(entry)
            } label: {
                Image(systemName: entry.pinned ? "pin.fill" : "pin")
                    .font(.caption)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(entry.pinned ? Color.accentColor : .secondary)
            .help(entry.pinned ? "Unpin" : "Pin — pinned prompts are never evicted")

            Button {
                settings.promptHistory.removeAll { $0.id == entry.id }
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red.opacity(0.7))
            .help("Remove from history")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect(entry.prompt)
            dismiss()
        }
    }

    private func togglePin(_ entry: PromptHistoryEntry) {
        guard let idx = settings.promptHistory.firstIndex(where: { $0.id == entry.id }) else { return }
        settings.promptHistory[idx].pinned.toggle()
    }
}

/// The small clock affordance that opens the history popover; lives in the
/// Prompt section header (Flux and Krea 2 panels).
struct PromptHistoryButton: View {
    let onSelect: (String) -> Void

    @State private var showingHistory: Bool = false

    var body: some View {
        Button { showingHistory = true } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 10))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Prompt history")
        .popover(isPresented: $showingHistory) {
            PromptHistoryPickerView(onSelect: onSelect)
        }
    }
}
