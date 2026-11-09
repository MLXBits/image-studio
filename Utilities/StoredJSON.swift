import Foundation

nonisolated enum StoredJSON {
    /// `url` decoded as `T`; `nil` when there is no file or it doesn't decode. A file
    /// that doesn't decode is moved aside to a uniquely named `<name>.corrupt-….json`,
    /// so neither the next save nor a later corruption can replace it.
    static func load<T: Decodable>(_: T.Type, from url: URL, decoder: JSONDecoder = JSONDecoder()) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let value = try? decoder.decode(T.self, from: data) {
            return value
        }
        let stamp = Int(Date().timeIntervalSince1970)
        let name = url.deletingPathExtension().lastPathComponent
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent("\(name).corrupt-\(stamp)-\(UUID().uuidString.prefix(8)).json")
        try? FileManager.default.moveItem(at: url, to: aside)
        return nil
    }
}
