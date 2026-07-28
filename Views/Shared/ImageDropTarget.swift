import SwiftUI
import UniformTypeIdentifiers

/// One drop target that accepts an image from either source the app can be handed one.
///
/// Two sources, two pasteboard types:
/// - the in-app gallery is an `NSCollectionView` whose drag writes the file path as
///   plain text (`GalleryCollectionView.pasteboardWriterForItemAt`), and
/// - a Finder drag arrives as `public.file-url`.
///
/// The wells used to declare those as two separate targets on the same view —
/// `.dropDestination(for: String.self)` for the first and `.onDrop(of: [.fileURL])`
/// for the second. Stacking two drop targets means only one of them ever receives
/// the drag session, so whichever lost was silently dead. This handles both
/// representations inside a single `.onDrop`.
extension View {
    /// - Parameters:
    ///   - extensions: lowercased file extensions to accept; anything else is ignored.
    ///   - isTargeted: bound to the hover state so the well can highlight itself.
    ///   - allowsMultiple: when false only the first accepted path is delivered.
    ///   - onPaths: receives the accepted paths on the main actor, never empty.
    func imageDropTarget(
        extensions: Set<String>,
        isTargeted: Binding<Bool>,
        allowsMultiple: Bool = false,
        onPaths: @escaping ([String]) -> Void
    ) -> some View {
        onDrop(of: [.fileURL, .text], isTargeted: isTargeted) { providers in
            let candidates = allowsMultiple ? providers : Array(providers.prefix(1))
            guard !candidates.isEmpty else { return false }
            ImageDropResolver.resolve(providers: candidates) { paths in
                let accepted = paths.filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) }
                guard !accepted.isEmpty else { return }
                onPaths(allowsMultiple ? accepted : Array(accepted.prefix(1)))
            }
            return true
        }
    }
}

/// Turns dropped item providers into file paths, whichever representation they carry.
enum ImageDropResolver {
    static func resolve(providers: [NSItemProvider], completion: @escaping ([String]) -> Void) {
        let group = DispatchGroup()
        // Indexed so the delivered order matches the drop order regardless of which
        // provider finishes loading first — it decides multi-image reference order.
        var byIndex: [Int: String] = [:]
        let lock = NSLock()

        for (index, provider) in providers.enumerated() {
            group.enter()
            path(from: provider) { path in
                if let path {
                    lock.lock(); byIndex[index] = path; lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(byIndex.keys.sorted().compactMap { byIndex[$0] })
        }
    }

    private static func path(from provider: NSItemProvider, completion: @escaping (String?) -> Void) {
        let fileURL = UTType.fileURL.identifier
        if provider.hasItemConformingToTypeIdentifier(fileURL) {
            provider.loadDataRepresentation(forTypeIdentifier: fileURL) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else {
                    completion(nil); return
                }
                completion(url.path)
            }
            return
        }
        // The gallery hands over a plain path string; tolerate a file:// URL too, since
        // some sources write the text representation of a URL rather than a bare path.
        let text = UTType.utf8PlainText.identifier
        if provider.hasItemConformingToTypeIdentifier(text) {
            provider.loadDataRepresentation(forTypeIdentifier: text) { data, _ in
                guard let data, let raw = String(data: data, encoding: .utf8) else {
                    completion(nil); return
                }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
                    completion(url.path)
                } else {
                    completion(trimmed.isEmpty ? nil : trimmed)
                }
            }
            return
        }
        completion(nil)
    }
}
