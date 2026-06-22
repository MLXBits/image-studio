import AppKit
import SwiftUI

// MARK: - NotepadView

/// A free-form markdown scratchpad for storing reusable prompt notes.
///
/// Edits autosave through ``AppSettings/notepadText`` (the binding writes straight
/// back to the persisted setting), so there's no explicit save step. The header
/// toggles between editing the markdown source and a rendered preview.
struct NotepadView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case edit = "Edit"
        case preview = "Preview"

        var id: String {
            rawValue
        }
    }

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .edit
    @State private var copied = false

    var body: some View {
        @Bindable var settings = settings

        VStack(spacing: 0) {
            header

            Group {
                switch mode {
                case .edit:
                    TextEditor(text: $settings.notepadText)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                case .preview:
                    MarkdownPreview(text: settings.notepadText)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(width: 640, height: 560)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("Notepad")
                .font(.headline)

            Spacer()

            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(settings.notepadText, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .disabled(settings.notepadText.isEmpty)
            .help("Copy the entire note to the clipboard")

            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - MarkdownPreview

/// Renders a markdown string as a scrollable stack of blocks. Supports ATX
/// headings (`#`–`###`), unordered list items (`-`/`*`), and paragraphs with
/// inline emphasis/code. Unknown syntax falls back to inline-rendered text.
private struct MarkdownPreview: View {
    private enum Block: Identifiable {
        case heading(level: Int, text: String)
        case bullet(text: String)
        case paragraph(text: String)
        case spacer

        var id: String {
            switch self {
            case let .heading(level, text): "h\(level):\(text)"
            case let .bullet(text): "b:\(text)"
            case let .paragraph(text): "p:\(text)"
            case .spacer: "spacer-\(UUID().uuidString)"
            }
        }
    }

    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Nothing here yet — switch to Edit and jot down some prompt notes.")
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(blocks) { block in
                        view(for: block)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .textSelection(.enabled)
        }
    }

    private var blocks: [Block] {
        text.components(separatedBy: "\n").map { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return .spacer }
            if let heading = headingBlock(line) { return heading }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                return .bullet(text: String(line.dropFirst(2)))
            }
            return .paragraph(text: line)
        }
    }

    private func headingBlock(_ line: String) -> Block? {
        for level in stride(from: 3, through: 1, by: -1) {
            let marker = String(repeating: "#", count: level) + " "
            if line.hasPrefix(marker) {
                return .heading(level: level, text: String(line.dropFirst(marker.count)))
            }
        }
        return nil
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case let .heading(level, text):
            inlineText(text)
                .font(headingFont(level))
                .padding(.top, level == 1 ? 8 : 4)
        case let .bullet(text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                inlineText(text)
            }
        case let .paragraph(text):
            inlineText(text)
        case .spacer:
            Spacer().frame(height: 4)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.bold()
        case 2: .title3.bold()
        default: .headline
        }
    }

    /// Renders inline markdown (bold/italic/code/links) for a single line,
    /// falling back to plain text if the line can't be parsed.
    private func inlineText(_ line: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: line, options: options) {
            return Text(attributed)
        }
        return Text(line)
    }
}
