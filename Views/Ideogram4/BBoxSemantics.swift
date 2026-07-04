import Foundation

// MARK: - Photo field tokens

/// `style_description.photo` is a comma-separated list of photographic descriptors
/// (e.g. "wide-angle lens, low-angle shot looking up, shallow depth of field").
/// These helpers add/replace one descriptor per "dimension" (angle, shot size, lens,
/// depth of field) without disturbing the others or any free text the user typed.
/// All managed clauses are comma-free so each is exactly one token.
enum PhotoTokens {
    static func split(_ photo: String?) -> [String] {
        (photo ?? "")
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Removes whichever token belongs to `vocabulary`, then appends `clause`
    /// (unless nil/empty), preserving every other token in place.
    static func apply(_ clause: String?, vocabulary: Set<String>, to photo: String?) -> String {
        var tokens = split(photo).filter { !vocabulary.contains($0) }
        if let clause, !clause.isEmpty { tokens.append(clause) }
        return tokens.joined(separator: ", ")
    }

    /// The token from `vocabulary` currently present, if any.
    static func current(vocabulary: Set<String>, in photo: String?) -> String? {
        split(photo).first { vocabulary.contains($0) }
    }
}

// MARK: - Photo dimensions

/// One axis of the shot description that maps to a single `photo` token. Feeds
/// `style_description.photo` only — camera is never encoded in a bbox.
protocol PhotoDimension: CaseIterable, Hashable {
    var label: String { get }
    var clause: String { get }
}

extension PhotoDimension {
    static var vocabulary: Set<String> {
        Set(allCases.map(\.clause))
    }

    /// The current selection for this dimension in `photo`, if any.
    static func current(in photo: String?) -> Self? {
        guard let present = PhotoTokens.current(vocabulary: vocabulary, in: photo) else { return nil }
        return allCases.first { $0.clause == present }
    }

    /// `photo` with this dimension cleared.
    static func clear(in photo: String?) -> String {
        PhotoTokens.apply(nil, vocabulary: vocabulary, to: photo)
    }

    /// `photo` with this dimension set to `self`.
    func write(to photo: String?) -> String {
        PhotoTokens.apply(clause, vocabulary: Self.vocabulary, to: photo)
    }
}

// MARK: - Camera angle (owned by the horizon line)

/// Vertical camera angle. This is the *only* shot dimension the horizon line drives;
/// framing / lens / depth of field live in the camera menu (see `ShotSize` etc.).
enum CameraPOV: String, CaseIterable, Identifiable, PhotoDimension {
    case high, eye, low

    /// POV implied by a horizon-line position (0–1000 y).
    static func forHorizon(_ y: Int) -> Self {
        if y < 333 { return .high }
        if y < 667 { return .eye }
        return .low
    }

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .high: "High angle"
        case .eye: "Eye level"
        case .low: "Low angle"
        }
    }

    var clause: String {
        switch self {
        case .high: "high-angle shot looking down"
        case .eye: "eye-level shot"
        case .low: "low-angle shot looking up"
        }
    }

    /// Default horizon-line position (0–1000 y): low angle puts the horizon near the
    /// bottom, high angle near the top, eye level in the middle.
    var defaultHorizon: Int {
        switch self {
        case .high: 150
        case .eye: 500
        case .low: 850
        }
    }
}

// MARK: - Shot size / lens / depth of field (the camera menu)

enum ShotSize: CaseIterable, PhotoDimension {
    case extremeCloseUp, closeUp, medium, full, wide, establishing

    var label: String {
        switch self {
        case .extremeCloseUp: "Extreme close-up"
        case .closeUp: "Close-up"
        case .medium: "Medium shot"
        case .full: "Full shot"
        case .wide: "Wide shot"
        case .establishing: "Establishing shot"
        }
    }

    var clause: String {
        switch self {
        case .extremeCloseUp: "extreme close-up"
        case .closeUp: "close-up shot"
        case .medium: "medium shot"
        case .full: "full shot"
        case .wide: "wide shot"
        case .establishing: "establishing shot"
        }
    }
}

enum Lens: CaseIterable, PhotoDimension {
    case ultraWide, wide, normal, telephoto, macro

    var label: String {
        switch self {
        case .ultraWide: "Ultra-wide"
        case .wide: "Wide-angle"
        case .normal: "Normal (50mm)"
        case .telephoto: "Telephoto"
        case .macro: "Macro"
        }
    }

    var clause: String {
        switch self {
        case .ultraWide: "ultra-wide lens"
        case .wide: "wide-angle lens"
        case .normal: "50mm lens"
        case .telephoto: "telephoto lens"
        case .macro: "macro lens"
        }
    }
}

enum DepthOfField: CaseIterable, PhotoDimension {
    case veryShallow, shallow, moderate, deep, veryDeep

    var label: String {
        switch self {
        case .veryShallow: "Very shallow (f/1.4)"
        case .shallow: "Shallow (f/2.8)"
        case .moderate: "Moderate (f/5.6)"
        case .deep: "Deep (f/8)"
        case .veryDeep: "Very deep (f/16)"
        }
    }

    var clause: String {
        switch self {
        case .veryShallow: "very shallow depth of field (f/1.4)"
        case .shallow: "shallow depth of field (f/2.8)"
        case .moderate: "moderate depth of field (f/5.6)"
        case .deep: "deep depth of field (f/8)"
        case .veryDeep: "very deep depth of field (f/16)"
        }
    }
}

// MARK: - Orientation clause

/// Translates an in-box orientation anchor into `desc` language such as
/// "head at bottom left of frame, feet at top center of frame". A bbox holds the
/// whole object and cannot rotate, so orientation lives in the element's `desc`.
enum OrientationClause {
    /// A single "<label> at <zone> of frame" fragment. `[A-Za-z]+` label followed
    /// by a frame zone produced by `BBoxGeometry.frameZone`.
    private static let fragment =
        #"[A-Za-z]+ at (?:top|bottom|center)(?: (?:left|center|right))? of frame"#

    /// Builds the clause for two labeled anchor endpoints and their zones.
    static func make(partA: String, zoneA: String, partB: String, zoneB: String) -> String {
        "\(partA) at \(zoneA), \(partB) at \(zoneB)"
    }

    /// Removes any previously-written orientation fragments (and their separators)
    /// from `desc`, so re-applying replaces rather than duplicates.
    static func strip(from desc: String) -> String {
        // Remove ", <fragment>" and standalone "<fragment>", then tidy separators.
        let patterns = [",\\s*" + fragment, fragment]
        var out = desc
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: "")
        }
        // Collapse doubled/leading/trailing separators left behind.
        out = out.replacingOccurrences(of: #"\s*,\s*,\s*"#, with: ", ", options: .regularExpression)
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        return out
    }

    /// Replaces the managed orientation clause in `desc` with a fresh one.
    static func apply(partA: String, zoneA: String, partB: String, zoneB: String, to desc: String) -> String {
        let clause = make(partA: partA, zoneA: zoneA, partB: partB, zoneB: zoneB)
        let base = strip(from: desc)
        return base.isEmpty ? clause : "\(base), \(clause)"
    }
}
