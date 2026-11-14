import AppKit
import SwiftUI

/// The Edit mode reference list: an ordered, reorderable set of images added by
/// browsing, dropping, or pasting. Order matters to the models (the first image
/// is the primary subject; prompts say "image 1", "image 2"). Shared by the
/// FLUX.2 and Qwen-Image 2.1 panels. Every path goes through
/// `settings.adoptSourceImage(_:)`.
struct EditImageListView: View {
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]

    @Binding var paths: [String]
    /// Most images the model accepts; nil = no cap.
    var maxCount: Int?
    /// Whether the clipboard holds an image, from the panel's own monitor.
    var clipboardHasImage: Bool
    /// Temp-file prefix for pasted images.
    var pastePrefix: String = "pasted-edit"

    @Environment(AppSettings.self) private var settings
    @State private var isDropTargeted: Bool = false
    @State private var pasteError: String?

    private var isFull: Bool {
        maxCount.map { paths.count >= $0 } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                if let maxCount, !paths.isEmpty {
                    Text("\(paths.count) of \(maxCount)")
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
                if !paths.isEmpty {
                    Button {
                        paths = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.iconButton)
                    .accessibilityLabel("Remove all images")
                }
            }

            if !paths.isEmpty {
                VStack(spacing: 4) {
                    ForEach(Array(paths.enumerated()), id: \.offset) { idx, path in
                        row(path: path, index: idx)
                    }
                    .onMove { from, to in paths.move(fromOffsets: from, toOffset: to) }
                }
            }

            if !isFull {
                addButtons
            }
        }
        .imageDropTarget(extensions: Self.imageExtensions, isTargeted: $isDropTargeted, allowsMultiple: true) { dropped in
            append(dropped)
        }
        .dropHighlight(isDropTargeted)
        .errorAlert("Could not paste image", message: $pasteError)
    }

    private var addButtons: some View {
        HStack(spacing: 6) {
            Button {
                browse()
            } label: {
                HStack {
                    Image(systemName: "photo.badge.plus")
                    Text(paths.isEmpty ? "Choose Image…" : "Add Image…")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Add reference image")

            if clipboardHasImage {
                Button { paste() } label: {
                    Image(systemName: "doc.on.clipboard")
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(KeyboardShortcutCatalog.pasteImage)
                .accessibilityLabel("Paste image from clipboard")
                .help("Paste image from clipboard (\(KeyboardShortcutCatalog.pasteImage.symbols))")
            }
        }
    }

    private func row(path: String, index: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.caption).foregroundStyle(.tertiary)
                .help("Drag to reorder")
            if let img = NSImage(contentsOfFile: path) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .thumbnailHoverPreview(imagePath: path)
            }
            Text(URL(fileURLWithPath: path).lastPathComponent)
                .font(.caption).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                paths.remove(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.iconButton)
            .accessibilityLabel("Remove image")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    /// Adopts and appends new images, skipping duplicates and anything past `maxCount`.
    private func append(_ added: [String]) {
        for path in added.map({ settings.adoptSourceImage($0) }) where !paths.contains(path) && !isFull {
            paths.append(path)
        }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = true
        panel.title = "Select Images"
        panel.startInLibrary(settings.outputDir)
        if panel.runModal() == .OK {
            append(panel.urls.filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }.map(\.path))
        }
    }

    private func paste() {
        do {
            if let path = try ImagePasteboard.pastedImagePath(tempPrefix: pastePrefix, extensions: Self.imageExtensions) {
                append([path])
            }
        } catch {
            pasteError = "The pasted image could not be saved: \(error.localizedDescription)"
        }
    }
}
