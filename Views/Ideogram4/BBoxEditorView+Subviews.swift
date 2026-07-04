import SwiftUI

// MARK: - Toolbar, side panel, popovers

extension BBoxEditorView {
    var modeToolbar: some View {
        VStack(spacing: 0) {
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

                Divider().frame(height: 16).padding(.horizontal, 2)

                layoutsMenu
                toolbarButton("grid", label: "Rule-of-thirds guides", active: showGuides) {
                    showGuides.toggle()
                }
                toolbarButton(
                    "arrow.up.and.down.and.arrow.left.and.right",
                    label: "Orientation anchor (select a box, drag the pins)",
                    active: orientationMode
                ) {
                    orientationMode.toggle()
                    if orientationMode { mode = .select }
                }
                if cameraAvailable {
                    cameraMenu
                }

                Spacer()
                if !isExpanded {
                    toolbarButton("arrow.up.left.and.arrow.down.right", label: "Expand editor", active: false) {
                        showExpandedSheet = true
                    }
                }
            }

            if orientationMode && selectedID != nil {
                orientationBar
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    /// Composition layout picker.
    var layoutsMenu: some View {
        Menu {
            ForEach(BBoxTemplate.library) { template in
                Button {
                    chooseTemplate(template)
                } label: {
                    Label(template.name, systemImage: template.systemImage)
                }
            }
        } label: {
            toolbarMenuLabel("rectangle.3.group")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Insert a composition layout")
    }

    /// Camera menu — shot size, lens, depth of field. Writes style_description.photo
    /// (never a bbox). Camera *angle* is owned by the horizon line, not this menu.
    var cameraMenu: some View {
        Menu {
            Picker("Shot size", selection: shotSizeBinding) {
                Text("Any shot size").tag(ShotSize?.none)
                ForEach(ShotSize.allCases, id: \.self) { size in
                    Text(size.label).tag(ShotSize?.some(size))
                }
            }
            Picker("Lens", selection: lensBinding) {
                Text("Any lens").tag(Lens?.none)
                ForEach(Lens.allCases, id: \.self) { lens in
                    Text(lens.label).tag(Lens?.some(lens))
                }
            }
            Picker("Depth of field", selection: depthOfFieldBinding) {
                Text("Any depth of field").tag(DepthOfField?.none)
                ForEach(DepthOfField.allCases, id: \.self) { dof in
                    Text(dof.label).tag(DepthOfField?.some(dof))
                }
            }
        } label: {
            toolbarMenuLabel("camera")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Shot size, lens & depth of field → writes the camera/lens field (not a bbox)")
    }

    var shotSizeBinding: Binding<ShotSize?> {
        photoDimensionBinding(ShotSize.self)
    }

    var lensBinding: Binding<Lens?> {
        photoDimensionBinding(Lens.self)
    }

    var depthOfFieldBinding: Binding<DepthOfField?> {
        photoDimensionBinding(DepthOfField.self)
    }

    /// Editable labels for the orientation anchor endpoints.
    var orientationBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "figure.stand").font(.caption2).foregroundStyle(.pink)
            TextField("head", text: $anchorLabelA)
                .textFieldStyle(.roundedBorder)
                .frame(width: 74)
                .controlSize(.small)
            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
            TextField("feet", text: $anchorLabelB)
                .textFieldStyle(.roundedBorder)
                .frame(width: 74)
                .controlSize(.small)
            Text("drag the pins on the selected box")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.top, 5)
        .onChange(of: anchorLabelA) { _, _ in if anchorA != nil || anchorB != nil { writeOrientation() } }
        .onChange(of: anchorLabelB) { _, _ in if anchorA != nil || anchorB != nil { writeOrientation() } }
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

            Self(
                elements: $elements,
                outputWidth: outputWidth,
                outputHeight: outputHeight,
                isExpanded: true,
                cameraStyle: cameraStyle
            )
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
                                },
                                onMoveForward: elements.count > 1 ? { moveForward(id: el.id) } : nil,
                                onMoveBackward: elements.count > 1 ? { moveBackward(id: el.id) } : nil
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

    /// A picker binding for one photo dimension: reads/writes the matching token in
    /// `style_description.photo`, leaving other dimensions and free text untouched.
    private func photoDimensionBinding<D: PhotoDimension>(_: D.Type) -> Binding<D?> {
        Binding(
            get: { D.current(in: cameraStyle?.wrappedValue?.photo) },
            set: { newValue in
                guard let cameraStyle else { return }
                var style = cameraStyle.wrappedValue ?? IdeogramCaptionStyle()
                let updated = newValue?.write(to: style.photo) ?? D.clear(in: style.photo)
                style.photo = updated.isEmpty ? nil : updated
                cameraStyle.wrappedValue = style
            }
        )
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

    /// Styled label matching `toolbarButton` for Menu triggers.
    func toolbarMenuLabel(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.caption)
            .frame(width: 26, height: 22)
            .background(Color.secondary.opacity(0.15))
            .foregroundStyle(.primary)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
