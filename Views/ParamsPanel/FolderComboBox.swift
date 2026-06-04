import SwiftUI

struct FolderComboBox: View {
    @Binding var text: String
    let options: [String]
    var placeholder: String = ""

    @State private var showSuggestions = false
    @State private var hoveredItem: String?
    @FocusState private var fieldFocused: Bool

    private var suggestions: [String] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let filtered = trimmed.isEmpty ? options : options.filter { $0.localizedCaseInsensitiveContains(trimmed) }
        return filtered.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        HStack(spacing: 4) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onChange(of: text) { _, _ in
                    // Only filter while the user is actively typing; don't auto-open on focus
                    // (auto-open steals keyboard focus on macOS when field has a pre-filled value)
                    if fieldFocused { showSuggestions = !suggestions.isEmpty }
                }
                .popover(isPresented: $showSuggestions, arrowEdge: .bottom) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(suggestions, id: \.self) { item in
                                Button {
                                    text = item
                                    showSuggestions = false
                                } label: {
                                    Text(item)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(
                                            hoveredItem == item
                                                ? Color.accentColor.opacity(0.12)
                                                : Color.clear
                                        )
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .focusEffectDisabled()
                                .onHover { hoveredItem = $0 ? item : nil }
                            }
                        }
                    }
                    .frame(minWidth: 200, maxHeight: 220)
                }

            if !text.isEmpty {
                Button {
                    text = ""
                    showSuggestions = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear group")
            }

            Button {
                showSuggestions = !options.isEmpty
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(options.isEmpty)
            .help("Show existing groups")
        }
    }
}
