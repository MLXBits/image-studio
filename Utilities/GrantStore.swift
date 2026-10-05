import Foundation

/// One remembered grant: the normalized path it was made for, and its bookmark.
struct Grant: Equatable {
    let path: String
    let bookmark: Data
}

/// Makes and resolves the bookmark data a grant is kept as. Security-scoped in
/// the app. It works outside the sandbox too, so tests use it as-is; one test
/// wraps it to fake a stale bookmark.
struct BookmarkCodec {
    static let securityScoped = Self(
        make: { url in
            try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        },
        resolve: { data in
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data, options: [.withSecurityScope, .withoutMounting, .withoutUI],
                relativeTo: nil, bookmarkDataIsStale: &isStale
            )
            return (url, isStale)
        }
    )

    var make: (URL) throws -> Data
    var resolve: (Data) throws -> (url: URL, isStale: Bool)
}

/// The App Store build's remembered grants (`grants.json` in App Support):
/// bookmark data keyed by the normalized path it was made for. One store for
/// every kind of grant — library, models folder, LoRA file — because jobs,
/// drafts, stacks and settings all carry plain paths (spec §4, as decided in
/// milestone 5).
final class GrantStore {
    private(set) var bookmarks: [String: Data]
    private let url: URL

    init(url: URL) {
        self.url = url
        bookmarks = (try? JSONDecoder().decode([String: Data].self, from: Data(contentsOf: url))) ?? [:]
    }

    func set(_ bookmark: Data, for path: String) {
        bookmarks[path] = bookmark
        save()
    }

    func remove(_ path: String) {
        guard bookmarks.removeValue(forKey: path) != nil else { return }
        save()
    }

    /// The deepest grant for `path` or a folder above it. `path` must already
    /// be ``FileAccessPath/normalized(_:)``.
    func grant(covering path: String) -> Grant? {
        var candidate = path
        while true {
            if let bookmark = bookmarks[candidate] {
                return Grant(path: candidate, bookmark: bookmark)
            }
            let parent = (candidate as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != candidate else { return nil }
            candidate = parent
        }
    }

    /// A failed write loses only this launch's new grants; the next choice
    /// writes the file again.
    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(bookmarks).write(to: url, options: .atomic)
    }
}
