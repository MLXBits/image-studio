import CryptoKit
import Foundation

/// Copies a source image from outside the library into a profile's `Inputs/`
/// folder (spec §4). The copy is named by a hash of its contents, so an image
/// brought in twice is kept once.
enum SourceImageImport {
    static func adopt(_ path: String, library: String, inputs: URL) throws -> String {
        let source = URL(fileURLWithPath: path).standardizedFileURL
        if isInside(source.path, library) || isInside(source.path, inputs.path) {
            return path
        }
        let data = try Data(contentsOf: source)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let ext = source.pathExtension.lowercased()
        let copy = inputs.appendingPathComponent(ext.isEmpty ? hash : "\(hash).\(ext)")
        if !FileManager.default.fileExists(atPath: copy.path) {
            try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
            try data.write(to: copy, options: .atomic)
        }
        return copy.path
    }

    private static func isInside(_ path: String, _ folder: String) -> Bool {
        guard !folder.isEmpty else { return false }
        let relation = ProfileRules.relation(of: path, to: folder)
        return relation == .inside || relation == .same
    }
}
