import Foundation
import ImageIO

// MARK: - Metadata stripping

/// Strips embedded metadata from an image file in place, preserving its
/// modification date. Returns `true` on success. PNGs are filtered chunk-by-chunk
/// (lossless); other formats are re-emitted via ImageIO without recompression.
nonisolated func stripImageMetadata(atPath path: String) -> Bool {
    let url = URL(fileURLWithPath: path)
    let originalDate = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    // The strip paths below rewrite the file atomically, which drops extended
    // attributes. Capture the cull flag/rating first and re-apply after so a
    // sanitized copy keeps its pick/reject verdict and stars.
    let flag = GalleryCulling.readFlag(path: path)
    let rating = GalleryCulling.readRating(path: path)

    let stripped = url.pathExtension.lowercased() == "png"
        ? stripPNGMetadata(at: url)
        : stripMetadataViaImageIO(at: url)

    if stripped {
        if let originalDate {
            try? FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: path)
        }
        GalleryCulling.writeFlag(flag, path: path)
        GalleryCulling.writeRating(rating, path: path)
    }
    return stripped
}

/// Removes the ancillary text/metadata chunks (`tEXt`, `zTXt`, `iTXt`, `eXIf`)
/// that carry XMP, IPTC, and EXIF data. Pixel (`IDAT`) and color chunks are copied
/// verbatim, so the image is bit-for-bit identical apart from the removed metadata.
nonisolated private func stripPNGMetadata(at url: URL) -> Bool {
    let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    guard let data = try? Data(contentsOf: url),
          data.count > signature.count,
          Array(data.prefix(signature.count)) == signature else { return false }

    let drop: Set = ["tEXt", "zTXt", "iTXt", "eXIf"]
    var out = Data(signature)
    var index = signature.count
    let count = data.count
    var sawMetadata = false

    while index + 12 <= count {
        let len = Int(data[index]) << 24 | Int(data[index + 1]) << 16
            | Int(data[index + 2]) << 8 | Int(data[index + 3])
        guard len >= 0, index + 12 + len <= count else { return false } // malformed — leave untouched
        let type = String(bytes: data[(index + 4) ..< (index + 8)], encoding: .ascii) ?? ""
        let chunkEnd = index + 12 + len
        if drop.contains(type) {
            sawMetadata = true
        } else {
            out.append(data[index ..< chunkEnd])
        }
        index = chunkEnd
        if type == "IEND" { break }
    }

    guard sawMetadata else { return true } // nothing to remove — succeed without a rewrite
    return (try? out.write(to: url, options: .atomic)) != nil
}

/// Strips EXIF/IPTC/GPS/XMP from non-PNG formats by copying the image source to a
/// fresh destination with those dictionaries excluded (no pixel recompression).
nonisolated private func stripMetadataViaImageIO(at url: URL) -> Bool {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let type = CGImageSourceGetType(source) else { return false }
    let tempURL = url.deletingLastPathComponent()
        .appendingPathComponent(".strip-\(UUID().uuidString).tmp")
    guard let destination = CGImageDestinationCreateWithURL(tempURL as CFURL, type, 1, nil) else { return false }

    let options: [CFString: Any] = [
        kCGImagePropertyExifDictionary: kCFNull,
        kCGImagePropertyGPSDictionary: kCFNull,
        kCGImagePropertyIPTCDictionary: kCFNull,
        kCGImageMetadataShouldExcludeXMP: kCFBooleanTrue as Any,
        kCGImageMetadataShouldExcludeGPS: kCFBooleanTrue as Any,
    ]
    let ok = CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil)
    guard ok else {
        try? FileManager.default.removeItem(at: tempURL)
        return false
    }
    do {
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        return true
    } catch {
        try? FileManager.default.removeItem(at: tempURL)
        return false
    }
}
