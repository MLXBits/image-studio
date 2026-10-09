import SwiftUI

extension KeyboardShortcutCatalog {
    static let showShortcuts = Binding(key: "/", modifiers: .command)

    static let general = Section("General", [
        Entry("Show or hide this list", showShortcuts),
        Entry("Settings", ["⌘", ","]),
    ])
}

/// Help ▸ Keyboard Shortcuts (#37). ⌘/ opens the window, and closes it when it's open.
struct KeyboardShortcutsCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Keyboard Shortcuts") {
                if KeyboardShortcutsView.isOpen {
                    dismissWindow(id: KeyboardShortcutsView.windowID)
                } else {
                    openWindow(id: KeyboardShortcutsView.windowID)
                }
            }
            .keyboardShortcut(KeyboardShortcutCatalog.showShortcuts)
        }
    }
}

/// Every shortcut the app handles, grouped by where it works and searchable.
/// A window rather than a sheet, so it can stay open beside the gallery.
struct KeyboardShortcutsView: View {
    static let windowID = "keyboard-shortcuts"
    /// Whether the window is on screen, so ⌘/ can close it again.
    private(set) static var isOpen = false

    @Environment(\.dismissWindow) private var dismissWindow
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let sections = KeyboardShortcutCatalog.filtered(query)
        NavigationStack {
            List {
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.entries, id: \.self) { entry in
                            HStack(spacing: 12) {
                                Text(entry.action)
                                Spacer(minLength: 8)
                                Keycaps(keys: entry.keys)
                            }
                        }
                    }
                }
            }
            .overlay {
                if sections.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, placement: .toolbar, prompt: "Search shortcuts")
            .searchFocused($searchFocused)
        }
        // Escape closes the window, as ⌘/ does.
        .background {
            Button("") { dismissWindow(id: Self.windowID) }
                .keyboardShortcut(.cancelAction)
                .hidden()
                .accessibilityHidden(true)
        }
        .frame(minWidth: 420, idealWidth: 500, minHeight: 360, idealHeight: 620)
        .onAppear {
            Self.isOpen = true
            // Typing goes straight into the search.
            searchFocused = true
        }
        .onDisappear { Self.isOpen = false }
    }
}

/// Keys drawn as keycaps, alternatives separated by "or".
private struct Keycaps: View {
    let keys: [[String]]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(keys.enumerated()), id: \.offset) { index, combo in
                if index > 0 {
                    Text("or")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 3) {
                    ForEach(Array(combo.enumerated()), id: \.offset) { _, cap in
                        Text(cap)
                            .font(.system(.callout, design: .rounded))
                            .frame(minWidth: 14)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.tertiary, lineWidth: 0.5))
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
