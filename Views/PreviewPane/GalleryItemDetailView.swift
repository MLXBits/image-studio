import AppKit
import SwiftUI

struct GalleryItemDetailView: View {
    let item: GalleryItem
    let onRemix: (GenerationMetadata) -> Void
    let onApplySettings: (GenerationMetadata) -> Void
    let onRemixIdeogram: (Ideogram4Metadata) -> Void
    let onApplyIdeogramSettings: (Ideogram4Metadata) -> Void
    var onRemixKrea2: ((Krea2Metadata) -> Void)?
    var onApplyKrea2Settings: ((Krea2Metadata) -> Void)?
    let onUseInImg2Img: (String) -> Void
    var onEditBoxesOverImage: ((Ideogram4Metadata, NSImage) -> Void)?
    var onShowFullSize: ((NSImage) -> Void)?
    var onSetFlag: ((PickFlag?) -> Void)?
    var onSetRating: ((Int) -> Void)?
    var onUpscale: ((String) -> Void)?

    @State private var image: NSImage?
    @State private var showingLog: Bool = false

    var body: some View {
        let info = if item.ideogram4Metadata != nil {
            ImageMetadataInfo(ideogram4Item: item)
        } else if item.krea2Metadata != nil {
            ImageMetadataInfo(krea2Item: item) ?? ImageMetadataInfo(path: item.path)
        } else if item.seedVR2Metadata != nil {
            ImageMetadataInfo(seedVR2Item: item) ?? ImageMetadataInfo(path: item.path)
        } else {
            ImageMetadataInfo(item: item) ?? ImageMetadataInfo(path: item.path)
        }
        VStack(spacing: 0) {
            ZStack {
                Color.black.opacity(0.05)
                if let img = image {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding()
            .onTapGesture(count: 2) {
                if let img = image { onShowFullSize?(img) }
            }
            .contextMenu {
                Button("Copy Image") {
                    guard let img = NSImage(contentsOfFile: item.path) else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([img])
                }
                if let meta = item.metadata {
                    Divider()
                    Button("Apply Settings") {
                        var corrected = meta
                        corrected.board = item.board == "Default" ? nil : item.board
                        onApplySettings(corrected)
                    }
                    Button("Remix (new seed)") { onRemix(meta) }
                    Button("Use as Img2Img Input") { onUseInImg2Img(item.path) }
                } else if let meta = item.ideogram4Metadata {
                    Divider()
                    Button("Apply Settings") { onApplyIdeogramSettings(correctedIdeogram(meta)) }
                    Button("Remix (new seed)") { onRemixIdeogram(meta) }
                    if let img = image {
                        Button("Adjust Boxes…") { onEditBoxesOverImage?(meta, img) }
                    }
                } else if let meta = item.krea2Metadata {
                    Divider()
                    Button("Apply Settings") { onApplyKrea2Settings?(correctedKrea2(meta)) }
                    Button("Remix (new seed)") { onRemixKrea2?(meta) }
                }
                if let onUpscale {
                    Divider()
                    Button("Upscale…") { onUpscale(item.path) }
                }
                if info.log != nil {
                    Divider()
                    Button("Show Log") { showingLog = true }
                }
                Divider()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
                }
            }

            if onSetFlag != nil || onSetRating != nil {
                cullControlRow
                Divider()
            }

            ImageMetadataPanel(
                info: info,
                onApplySettings: applySettingsAction,
                onRemix: remixAction,
                onUseInImg2Img: item.ideogram4Metadata == nil && item.krea2Metadata == nil
                    ? { onUseInImg2Img(item.path) } : nil,
                onEditBoxes: editBoxesAction,
                onRevealInFinder: {
                    NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
                },
                onShowLog: info.log != nil ? { showingLog = true } : nil,
                onUpscale: onUpscale.map { fn in { fn(item.path) } }
            )
        }
        .onAppear { loadImage() }
        .onChange(of: item.id) { _, _ in loadImage() }
        .sheet(isPresented: $showingLog) { logSheet(log: info.log ?? "") }
    }

    /// Interactive cull row — pick/reject toggles and 0–5 stars, mirroring the
    /// keyboard shortcuts for mouse users. Clicking the current top star clears down
    /// one; clicking an active flag clears it.
    private var cullControlRow: some View {
        HStack(spacing: 12) {
            Button { onSetFlag?(item.flag == .pick ? nil : .pick) } label: {
                Image(systemName: item.flag == .pick ? "flag.fill" : "flag")
                    .foregroundStyle(item.flag == .pick ? .green : .secondary)
            }
            .buttonStyle(.plain).help("Pick (P)")

            Button { onSetFlag?(item.flag == .reject ? nil : .reject) } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(item.flag == .reject ? .red : .secondary)
            }
            .buttonStyle(.plain).help("Reject (X)")

            Divider().frame(height: 14)

            HStack(spacing: 3) {
                ForEach(1 ... 5, id: \.self) { star in
                    Button { onSetRating?(item.rating == star ? star - 1 : star) } label: {
                        Image(systemName: star <= item.rating ? "star.fill" : "star")
                            .foregroundStyle(star <= item.rating ? .yellow : .secondary)
                    }
                    .buttonStyle(.plain).help("Rate \(star)")
                }
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    /// Apply-Settings closure for the metadata panel footer, selecting the Flux or
    /// Ideogram replay path based on which sidecar the item carries.
    private var applySettingsAction: (() -> Void)? {
        if let meta = item.metadata {
            return {
                var corrected = meta
                corrected.board = item.board == "Default" ? nil : item.board
                onApplySettings(corrected)
            }
        }
        if let meta = item.ideogram4Metadata {
            return { onApplyIdeogramSettings(correctedIdeogram(meta)) }
        }
        if let meta = item.krea2Metadata, let fn = onApplyKrea2Settings {
            return { fn(correctedKrea2(meta)) }
        }
        return nil
    }

    private var remixAction: (() -> Void)? {
        if let meta = item.metadata { return { onRemix(meta) } }
        if let meta = item.ideogram4Metadata { return { onRemixIdeogram(meta) } }
        if let meta = item.krea2Metadata, let fn = onRemixKrea2 { return { fn(meta) } }
        return nil
    }

    /// "Adjust Boxes" closure — available only for Ideogram images once the image
    /// has loaded, so the boxes can be overlaid on it.
    private var editBoxesAction: (() -> Void)? {
        guard let meta = item.ideogram4Metadata, let img = image else { return nil }
        return { onEditBoxesOverImage?(meta, img) }
    }

    /// Restores the board from the item's gallery folder (the sidecar may predate
    /// foldering or carry a stale value), matching the Flux Apply-Settings behavior.
    private func correctedIdeogram(_ meta: Ideogram4Metadata) -> Ideogram4Metadata {
        var corrected = meta
        corrected.board = item.board == "Default" ? nil : item.board
        return corrected
    }

    private func correctedKrea2(_ meta: Krea2Metadata) -> Krea2Metadata {
        var corrected = meta
        corrected.board = item.board == "Default" ? nil : item.board
        return corrected
    }

    private func logSheet(log: String) -> some View {
        NavigationStack {
            ScrollView {
                Text(log)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Generation Log")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingLog = false }
                }
            }
        }
        .frame(width: 640, height: 480)
    }

    private func loadImage() {
        image = nil
        let url = item.url
        Task.detached(priority: .userInitiated) {
            let img = NSImage(contentsOf: url)
            await MainActor.run { image = img }
        }
    }
}
