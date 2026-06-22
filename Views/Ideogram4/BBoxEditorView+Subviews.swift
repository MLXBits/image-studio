import SwiftUI

// MARK: - Toolbar, side panel, popovers

extension BBoxEditorView {
    var modeToolbar: some View {
        HStack(spacing: 4) {
            toolbarButton("cursorarrow", label: "Select", active: mode == .select) {
                mode = .select
            }
            toolbarButton("rectangle.dashed", label: "Draw bbox (drag on canvas)", active: mode == .draw) {
                mode = .draw
                selectedID = nil
            }
            toolbarButton("plus", label: "Add element (centered default)", active: false) {
                pendingBBox = [250, 250, 750, 750]
                newElementType = .obj
                newElementText = ""
                newElementDesc = ""
                showCreatePopover = true
            }
            if !isExpanded {
                Spacer()
                toolbarButton("arrow.up.left.and.arrow.down.right", label: "Expand editor", active: false) {
                    showExpandedSheet = true
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    var expandedSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Bounding Boxes")
                    .font(.headline)
                Spacer()
                Button("Done") { showExpandedSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }

            Self(elements: $elements, outputWidth: outputWidth, outputHeight: outputHeight, isExpanded: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 940, height: 600)
    }

    /// Element list shown beside the canvas in expanded mode.
    var elementSidePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Elements").font(.headline)
                Spacer()
                Text("\(elements.count)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            Divider()

            if elements.isEmpty {
                VStack(spacing: 4) {
                    Spacer()
                    Text("No elements yet").font(.callout).foregroundStyle(.tertiary)
                    Text("Draw a box on the canvas").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach($elements) { $el in
                            IdeogramElementCard(
                                element: $el,
                                accentColor: BBoxGeometry.boxColor(
                                    at: elements.firstIndex { $0.id == el.id } ?? 0,
                                    type: el.type
                                ),
                                isSelected: el.id == selectedID,
                                onSelect: {
                                    selectedID = el.id
                                    focusRequest += 1
                                },
                                onTextFocus: {
                                    // Select the rectangle without bumping focusRequest:
                                    // the key catcher must NOT steal first responder back
                                    // from the text field the user just clicked into.
                                    selectedID = el.id
                                },
                                onRemove: {
                                    if selectedID == el.id { selectedID = nil }
                                    elements.removeAll { $0.id == el.id }
                                }
                            )
                        }
                    }
                    .padding(10)
                }
            }
        }
        .frame(width: 260)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    var createPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Element").font(.headline)

            Picker("Type", selection: $newElementType) {
                Text("Object").tag(IdeogramElementType.obj)
                Text("Text").tag(IdeogramElementType.text)
            }
            .pickerStyle(.segmented)

            if newElementType == .text {
                LabeledContent("Text") {
                    TextField("visible text...", text: $newElementText)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 200)
                        .focused($isPopoverFocused)
                }
            }

            LabeledContent("Description") {
                TextField("describe the element...", text: $newElementDesc)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 200)
            }

            HStack {
                Button("Cancel") {
                    showCreatePopover = false
                    pendingBBox = nil
                }
                Spacer()
                Button("Add") { commitCreate() }
                    .disabled(newElementDesc.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.return)
            }
        }
        .padding()
        .frame(width: 280)
        .onAppear { isPopoverFocused = newElementType == .text }
    }

    var selectedElement: IdeogramCaptionElement? {
        elements.first { $0.id == selectedID }
    }

    func toolbarButton(
        _ icon: String, label: String, active: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption)
                .frame(width: 26, height: 22)
                .background(active ? Color.accentColor : Color.secondary.opacity(0.15))
                .foregroundStyle(active ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(label)
    }
}
