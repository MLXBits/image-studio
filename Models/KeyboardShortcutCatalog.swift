import SwiftUI

/// Every keyboard shortcut the app handles, for Help ▸ Keyboard Shortcuts (#37).
///
/// Each section is declared in an extension in the file that handles its keys,
/// so a new shortcut is listed where it's added. A SwiftUI button takes its key
/// from a ``Binding`` (`.keyboardShortcut(KeyboardShortcutCatalog.generate)`), so
/// the key it answers to and the key listed are one definition. AppKit `keyDown`
/// handlers match key codes and can't share it; their switch points to the
/// section in the same file.
enum KeyboardShortcutCatalog {
    /// A key a SwiftUI button answers to.
    struct Binding {
        private static func symbol(for key: KeyEquivalent) -> String {
            switch key {
            case .return: "↵"
            case .delete: "⌫"
            case .deleteForward: "⌦"
            case .escape: "⎋"
            case .leftArrow: "←"
            case .rightArrow: "→"
            case .upArrow: "↑"
            case .downArrow: "↓"
            default: String(key.character).uppercased()
            }
        }

        let key: KeyEquivalent
        let modifiers: EventModifiers

        /// Modifiers in Apple's order (⌃⌥⇧⌘), then the key.
        var keycaps: [String] {
            let modifierCaps: [(EventModifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            return modifierCaps.filter { modifiers.contains($0.0) }.map(\.1) + [Self.symbol(for: key)]
        }

        /// The keycaps run together, for help text: "⌥⌘↵".
        var symbols: String {
            keycaps.joined()
        }
    }

    struct Entry: Hashable {
        let action: String
        /// Alternatives, each a run of keycaps: `[["⌫"], ["⌦"]]` reads "⌫ or ⌦".
        let keys: [[String]]

        init(_ action: String, _ keys: [String]...) {
            self.action = action
            self.keys = keys
        }

        init(_ action: String, _ binding: Binding) {
            self.action = action
            keys = [binding.keycaps]
        }
    }

    struct Section: Identifiable {
        let title: String
        let entries: [Entry]

        var id: String {
            title
        }

        init(_ title: String, _ entries: [Entry]) {
            self.title = title
            self.entries = entries
        }
    }

    /// Sheets and dialogs everywhere: SwiftUI's default and cancel actions.
    static let sheets = Section("Sheets and Dialogs", [
        Entry("Confirm, or Done", ["↵"]),
        Entry("Cancel, or close", ["⎋"]),
    ])

    /// In the order the window lists them.
    static let sections: [Section] = [
        general, generating, gallery, fullSizeView, compareView, layoutEditor, sheets,
    ]

    /// The sections that match `query`: a section whose title matches keeps all
    /// its entries; otherwise only the entries whose action or keys match.
    static func filtered(_ query: String, in sections: [Section] = sections) -> [Section] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sections }
        return sections.compactMap { section in
            if section.title.localizedCaseInsensitiveContains(query) {
                return section
            }
            let entries = section.entries.filter { entry in
                entry.action.localizedCaseInsensitiveContains(query)
                    || entry.keys.contains { $0.joined().localizedCaseInsensitiveContains(query) }
            }
            return entries.isEmpty ? nil : Section(section.title, entries)
        }
    }
}

extension View {
    /// Binds a catalog shortcut, so the button and the Keyboard Shortcuts list agree.
    func keyboardShortcut(_ binding: KeyboardShortcutCatalog.Binding) -> some View {
        keyboardShortcut(binding.key, modifiers: binding.modifiers)
    }
}
