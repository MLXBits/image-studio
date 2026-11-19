import SwiftUI

/// What the menu bar can do in the frontmost main window. `ContentView`
/// publishes one with `focusedSceneValue`, so each command acts on the window
/// it was chosen in, and is disabled when no main window is in front.
struct MainWindowActions {
    /// The selected gallery image's actions.
    struct ImageActions {
        var revealInFinder: () -> Void
        /// Nil when the image has no prompt.
        var copyPrompt: (() -> Void)?
        /// Nil when the image has no settings to apply (an upscale, or no sidecar).
        var applySettings: (() -> Void)?
        var upscale: () -> Void
    }

    /// True while a sheet is up. Commands that change the form or start work
    /// wait until it closes; the sheet owns the keyboard meanwhile.
    var sheetIsUp: Bool
    var canGenerate: Bool
    /// True while a job runs, so Generate reads as Add to Queue.
    var isGenerating: Bool
    var generate: () -> Void
    var batchCount: Int
    var generateBatch: () -> Void
    var stop: () -> Void
    var showingParams: Bool
    var toggleParams: () -> Void
    var showingQueue: Bool
    var toggleQueue: () -> Void
    var showNotepad: () -> Void
    var image: ImageActions?
}

extension FocusedValues {
    @Entry var mainWindow: MainWindowActions?
}

/// Generate, View and Image menu commands for the main window.
struct MainWindowCommands: Commands {
    @FocusedValue(\.mainWindow) private var window

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button(window?.showingParams == false ? "Show Params Panel" : "Hide Params Panel") {
                window?.toggleParams()
            }
            .keyboardShortcut(KeyboardShortcutCatalog.toggleParams)
            .disabled(window == nil || window?.sheetIsUp == true)
            Button(window?.showingQueue == true ? "Hide Queue" : "Show Queue") { window?.toggleQueue() }
                .keyboardShortcut(KeyboardShortcutCatalog.toggleQueue)
                // The queue is itself a sheet: ⌘K closes it again.
                .disabled(window == nil || (window?.sheetIsUp == true && window?.showingQueue != true))
            Button("Notepad") { window?.showNotepad() }
                .keyboardShortcut(KeyboardShortcutCatalog.showNotepad)
                .disabled(window == nil || window?.sheetIsUp == true)
            Divider()
        }
        CommandMenu("Generate") {
            generateItems
        }
        CommandMenu("Image") {
            imageItems
        }
    }

    private var formIsFree: Bool {
        guard let window else { return false }
        return !window.sheetIsUp
    }

    @ViewBuilder private var generateItems: some View {
        Button(window?.isGenerating == true ? "Add to Queue" : "Generate") { window?.generate() }
            .keyboardShortcut(KeyboardShortcutCatalog.generate)
            .disabled(!formIsFree || window?.canGenerate != true)
        Button("Generate Batch of \(window?.batchCount ?? 0)") { window?.generateBatch() }
            .keyboardShortcut(KeyboardShortcutCatalog.generateBatch)
            .disabled(!formIsFree || window?.canGenerate != true)
        Button("Stop") { window?.stop() }
            .keyboardShortcut(KeyboardShortcutCatalog.stop)
            .disabled(window?.isGenerating != true)
    }

    @ViewBuilder private var imageItems: some View {
        let image = window?.image
        Button("Reveal in Finder") { image?.revealInFinder() }
            .keyboardShortcut(KeyboardShortcutCatalog.revealInFinder)
            .disabled(image == nil)
        Button("Copy Prompt") { image?.copyPrompt?() }
            .keyboardShortcut(KeyboardShortcutCatalog.copyPrompt)
            .disabled(image?.copyPrompt == nil)
        Divider()
        Button("Apply Settings") { image?.applySettings?() }
            .disabled(!formIsFree || image?.applySettings == nil)
        Button("Upscale…") { image?.upscale() }
            .disabled(!formIsFree || image == nil)
    }
}

extension KeyboardShortcutCatalog {
    static let generate = Binding(key: .return, modifiers: .command)
    /// Generates `settings.batchShortcutCount` random seeds.
    static let generateBatch = Binding(key: .return, modifiers: [.command, .option])
    static let stop = Binding(key: ".", modifiers: .command)
    static let toggleQueue = Binding(key: "k", modifiers: .command)
    static let toggleParams = Binding(key: "s", modifiers: [.command, .control])
    static let showNotepad = Binding(key: "n", modifiers: [.command, .option])
    static let revealInFinder = Binding(key: "r", modifiers: [.command, .shift])
    static let copyPrompt = Binding(key: "c", modifiers: [.command, .shift])

    static let generating = Section("Generating", [
        Entry("Generate, or add to the queue while a job runs", generate),
        Entry("Generate a batch (size set in Settings ▸ Generation)", generateBatch),
        Entry("Stop the running job", stop),
        Entry("Paste an image from the clipboard as the input image", pasteImage),
    ])

    static let windowLayout = Section("Window", [
        Entry("Show or hide the params panel", toggleParams),
        Entry("Show or hide the queue", toggleQueue),
        Entry("Open the notepad", showNotepad),
    ])

    static let imageMenu = Section("Selected Image", [
        Entry("Reveal in Finder", revealInFinder),
        Entry("Copy its prompt", copyPrompt),
    ])
}
