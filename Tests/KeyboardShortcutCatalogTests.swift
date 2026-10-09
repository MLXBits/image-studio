@testable import MLXBits_Image_Studio
import SwiftUI
import Testing

/// Help ▸ Keyboard Shortcuts (#37): the list the window shows.
struct KeyboardShortcutCatalogTests {
    private typealias Catalog = KeyboardShortcutCatalog

    @Test func keycapsUseApplesModifierOrder() {
        #expect(Catalog.Binding(key: .return, modifiers: [.command, .option]).keycaps == ["⌥", "⌘", "↵"])
        #expect(Catalog.Binding(key: "k", modifiers: .command).symbols == "⌘K")
        #expect(Catalog.Binding(key: .delete, modifiers: [.command, .shift, .control]).symbols == "⌃⇧⌘⌫")
    }

    /// The SwiftUI buttons bind these, so the list shows what they answer to.
    @Test func boundShortcutsAreListed() {
        let listed = Set(Catalog.sections.flatMap(\.entries).flatMap(\.keys))
        let bindings: [Catalog.Binding] = [
            Catalog.showShortcuts, Catalog.generate, Catalog.generateBatch, Catalog.toggleQueue,
            Catalog.pasteImage, Catalog.deleteRejected, Catalog.addBox,
        ]
        for binding in bindings {
            #expect(listed.contains(binding.keycaps), "\(binding.symbols) is bound but not listed")
        }
    }

    @Test func sectionsAreNonEmptyAndUnambiguous() {
        #expect(Set(Catalog.sections.map(\.title)).count == Catalog.sections.count)
        for section in Catalog.sections {
            #expect(!section.entries.isEmpty, "\(section.title) is empty")
            let actions = section.entries.map(\.action)
            #expect(Set(actions).count == actions.count, "\(section.title) lists an action twice")
            // One key doing two things in the same place is a listing mistake.
            let keys = section.entries.flatMap(\.keys)
            #expect(Set(keys).count == keys.count, "\(section.title) lists a key twice")
        }
    }

    @Test func anEmptySearchShowsEverything() {
        #expect(Catalog.filtered("  ").map(\.title) == Catalog.sections.map(\.title))
    }

    @Test func searchMatchesActionsAcrossSections() {
        let found = Catalog.filtered("reject")
        #expect(found.map(\.title) == ["Gallery", "Full-Size View", "Compare View"])
        #expect(found.allSatisfy { section in
            section.entries.allSatisfy { $0.action.localizedCaseInsensitiveContains("reject") }
        })
    }

    @Test func searchMatchingASectionTitleKeepsTheWholeSection() {
        let found = Catalog.filtered("compare view")
        #expect(found.map(\.title) == ["Compare View"])
        #expect(found.first?.entries.count == Catalog.compareView.entries.count)
    }

    @Test func searchMatchesKeycaps() {
        let found = Catalog.filtered("⌥⌘")
        #expect(found.flatMap(\.entries).map(\.action) == ["Generate a batch (size set in Settings ▸ Generation)"])
    }

    @Test func aSearchWithNoMatchShowsNothing() {
        #expect(Catalog.filtered("zzzz").isEmpty)
    }
}
