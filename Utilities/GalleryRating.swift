import Foundation

/// Lightroom-style pick/reject verdict for a gallery image. A missing value means
/// "unflagged". Persisted per file as an extended attribute (see ``GalleryCulling``)
/// so it is model-agnostic (works for images without a sidecar), travels with the
/// file on in-app board moves, and never mutates the file's modification date.
enum PickFlag: String, Equatable {
    case pick
    case reject
}

/// Filter option for the gallery's flag axis.
enum FlagFilter: String, CaseIterable, Identifiable {
    case all
    case picks
    case rejects
    case unflagged

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .all: "All"
        case .picks: "Picks"
        case .rejects: "Rejects"
        case .unflagged: "Unflagged"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "flag.slash"
        case .picks: "flag.fill"
        case .rejects: "xmark.bin"
        case .unflagged: "flag"
        }
    }
}

/// Reads and writes pick/reject flags and 0–5 star ratings as extended attributes
/// on the image file itself. All operations are `nonisolated` so they can run inside
/// the detached gallery scan. Writing an xattr does not touch the file's contents or
/// modification date, so gallery ordering is unaffected.
enum GalleryCulling {
    static let flagAttr = "com.mlxbits.imagestudio.flag"
    static let ratingAttr = "com.mlxbits.imagestudio.rating"

    nonisolated static func readFlag(path: String) -> PickFlag? {
        readXattr(flagAttr, path: path).flatMap(PickFlag.init(rawValue:))
    }

    nonisolated static func readRating(path: String) -> Int {
        guard let raw = readXattr(ratingAttr, path: path), let value = Int(raw) else { return 0 }
        return min(5, max(0, value))
    }

    nonisolated static func writeFlag(_ flag: PickFlag?, path: String) {
        if let flag {
            writeXattr(flagAttr, value: flag.rawValue, path: path)
        } else {
            removeXattr(flagAttr, path: path)
        }
    }

    nonisolated static func writeRating(_ rating: Int, path: String) {
        let clamped = min(5, max(0, rating))
        if clamped == 0 {
            removeXattr(ratingAttr, path: path)
        } else {
            writeXattr(ratingAttr, value: String(clamped), path: path)
        }
    }

    // MARK: - xattr primitives

    nonisolated private static func readXattr(_ name: String, path: String) -> String? {
        let length = getxattr(path, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { buffer in
            getxattr(path, name, buffer.baseAddress, length, 0, 0)
        }
        guard read >= 0 else { return nil }
        return String(data: data.prefix(read), encoding: .utf8)
    }

    nonisolated private static func writeXattr(_ name: String, value: String, path: String) {
        let data = Data(value.utf8)
        _ = data.withUnsafeBytes { buffer in
            setxattr(path, name, buffer.baseAddress, data.count, 0, 0)
        }
    }

    nonisolated private static func removeXattr(_ name: String, path: String) {
        _ = removexattr(path, name, 0)
    }
}
