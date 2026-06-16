import Foundation

// MARK: - Element type

enum IdeogramElementType: String, Codable, CaseIterable, Hashable {
    case text
    case obj
}

// MARK: - Caption element

struct IdeogramCaptionElement: Identifiable {
    enum CodingKeys: String, CodingKey {
        case type, bbox, text, desc
        case colorPalette = "color_palette"
    }

    static func empty(type: IdeogramElementType) -> Self {
        Self(type: type, bbox: [100, 100, 400, 400], text: type == .text ? "" : nil, desc: "")
    }

    var id = UUID()
    var type: IdeogramElementType
    /// Normalized [y_min, x_min, y_max, x_max] 0–1000. Empty array = no bbox (omitted in JSON).
    var bbox: [Int]
    var text: String?
    var desc: String
    var colorPalette: [String]?

    var isBBoxValid: Bool {
        guard bbox.count == 4 else { return false }
        let y1 = bbox[0], x1 = bbox[1], y2 = bbox[2], x2 = bbox[3]
        return y1 >= 0 && x1 >= 0 && y2 <= 1000 && x2 <= 1000 && y2 > y1 && x2 > x1
    }

    var y1: Int {
        bbox.count >= 4 ? bbox[0] : 0
    }

    var x1: Int {
        bbox.count >= 4 ? bbox[1] : 0
    }

    var y2: Int {
        bbox.count >= 4 ? bbox[2] : 0
    }

    var x2: Int {
        bbox.count >= 4 ? bbox[3] : 0
    }
}

// MARK: - IdeogramCaptionElement + Codable

extension IdeogramCaptionElement: Codable {
    init(type: IdeogramElementType, bbox: [Int], text: String? = nil, desc: String) {
        self.type = type
        self.bbox = bbox
        self.text = text
        self.desc = desc
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(IdeogramElementType.self, forKey: .type)
        // bbox is optional per schema — missing bbox becomes [] (fails isBBoxValid, not shown on canvas)
        bbox = try (c.decodeIfPresent([Int].self, forKey: .bbox)) ?? []
        text = try c.decodeIfPresent(String.self, forKey: .text)
        desc = try (c.decodeIfPresent(String.self, forKey: .desc)) ?? ""
        colorPalette = try c.decodeIfPresent([String].self, forKey: .colorPalette)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Schema key order — obj: type, bbox, desc, color_palette
        //                  — text: type, bbox, text, desc, color_palette
        try c.encode(type, forKey: .type)
        if isBBoxValid { try c.encode(bbox, forKey: .bbox) }
        if type == .text, let text, !text.isEmpty { try c.encode(text, forKey: .text) }
        try c.encode(desc, forKey: .desc)
        if let colorPalette, !colorPalette.isEmpty { try c.encode(colorPalette, forKey: .colorPalette) }
    }
}

// MARK: - Style description

struct IdeogramCaptionStyle {
    enum CodingKeys: String, CodingKey {
        case aesthetics, lighting, photo, medium
        case artStyle = "art_style"
        case colorPalette = "color_palette"
    }

    var aesthetics: String?
    var lighting: String?
    /// Camera / lens details — photo mode only. Mutually exclusive with `artStyle`.
    /// Photo key order: aesthetics, lighting, photo, medium, color_palette.
    var photo: String?
    var medium: String?
    /// Art style description — non-photo mode only. Mutually exclusive with `photo`.
    /// Art key order: aesthetics, lighting, medium, art_style, color_palette.
    var artStyle: String?
    var colorPalette: [String]?

    var isPhotoMode: Bool {
        photo != nil
    }

    var isEmpty: Bool {
        [aesthetics, lighting, medium, artStyle, photo].allSatisfy { $0?.isEmpty ?? true }
            && (colorPalette ?? []).isEmpty
    }
}

// MARK: - IdeogramCaptionStyle + Codable

extension IdeogramCaptionStyle: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aesthetics = try c.decodeIfPresent(String.self, forKey: .aesthetics)
        lighting = try c.decodeIfPresent(String.self, forKey: .lighting)
        photo = try c.decodeIfPresent(String.self, forKey: .photo)
        medium = try c.decodeIfPresent(String.self, forKey: .medium)
        artStyle = try c.decodeIfPresent(String.self, forKey: .artStyle)
        colorPalette = try c.decodeIfPresent([String].self, forKey: .colorPalette)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let aesthetics, !aesthetics.isEmpty { try c.encode(aesthetics, forKey: .aesthetics) }
        if let lighting, !lighting.isEmpty { try c.encode(lighting, forKey: .lighting) }
        if isPhotoMode {
            // photo key order: aesthetics → lighting → photo → medium → color_palette
            if let photo, !photo.isEmpty { try c.encode(photo, forKey: .photo) }
            if let medium, !medium.isEmpty { try c.encode(medium, forKey: .medium) }
        } else {
            // art key order: aesthetics → lighting → medium → art_style → color_palette
            if let medium, !medium.isEmpty { try c.encode(medium, forKey: .medium) }
            if let artStyle, !artStyle.isEmpty { try c.encode(artStyle, forKey: .artStyle) }
        }
        if let colorPalette, !colorPalette.isEmpty { try c.encode(colorPalette, forKey: .colorPalette) }
    }
}

// MARK: - Composition

struct IdeogramCaptionComposition: Codable {
    var background: String
    var elements: [IdeogramCaptionElement]
}

// MARK: - Root caption

struct IdeogramCaption: Codable {
    enum CodingKeys: String, CodingKey {
        case highLevelDescription = "high_level_description"
        case styleDescription = "style_description"
        case compositionalDeconstruction = "compositional_deconstruction"
    }

    static func empty() -> Self {
        Self(
            highLevelDescription: "",
            styleDescription: nil,
            compositionalDeconstruction: IdeogramCaptionComposition(background: "", elements: [])
        )
    }

    static func from(jsonString: String) -> Self? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    var highLevelDescription: String
    var styleDescription: IdeogramCaptionStyle?
    var compositionalDeconstruction: IdeogramCaptionComposition

    /// Returns compact JSON for use with mflux --prompt-file.
    /// Hand-built to guarantee key order at every level — JSONEncoder routes through NSDictionary
    /// which does not preserve insertion order, causing Ideogram4CaptionWarning on the Python side.
    func toJSON() -> String? {
        func esc(_ s: String) -> String {
            var out = "\""
            for ch in s {
                switch ch {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default: out.append(ch)
                }
            }
            return out + "\""
        }

        func encodeElement(_ el: IdeogramCaptionElement) -> String {
            var p: [String] = []
            p.append("\"type\":\(esc(el.type.rawValue))")
            if el.isBBoxValid { p.append("\"bbox\":[\(el.bbox.map(String.init).joined(separator: ","))]") }
            if el.type == .text, let t = el.text, !t.isEmpty { p.append("\"text\":\(esc(t))") }
            p.append("\"desc\":\(esc(el.desc))")
            if let cp = el.colorPalette, !cp.isEmpty {
                p.append("\"color_palette\":[\(cp.map(esc).joined(separator: ","))]")
            }
            return "{\(p.joined(separator: ","))}"
        }

        func encodeStyle(_ s: IdeogramCaptionStyle) -> String? {
            var p: [String] = []
            if let a = s.aesthetics, !a.isEmpty { p.append("\"aesthetics\":\(esc(a))") }
            if let l = s.lighting, !l.isEmpty { p.append("\"lighting\":\(esc(l))") }
            if s.isPhotoMode {
                if let ph = s.photo, !ph.isEmpty { p.append("\"photo\":\(esc(ph))") }
                if let m = s.medium, !m.isEmpty { p.append("\"medium\":\(esc(m))") }
            } else {
                if let m = s.medium, !m.isEmpty { p.append("\"medium\":\(esc(m))") }
                if let a = s.artStyle, !a.isEmpty { p.append("\"art_style\":\(esc(a))") }
            }
            if let cp = s.colorPalette, !cp.isEmpty {
                p.append("\"color_palette\":[\(cp.map(esc).joined(separator: ","))]")
            }
            return p.isEmpty ? nil : "{\(p.joined(separator: ","))}"
        }

        var root: [String] = []
        root.append("\"high_level_description\":\(esc(highLevelDescription))")
        if let style = styleDescription, !style.isEmpty, let sj = encodeStyle(style) {
            root.append("\"style_description\":\(sj)")
        }
        let comp = compositionalDeconstruction
        var cd: [String] = []
        cd.append("\"background\":\(esc(comp.background))")
        cd.append("\"elements\":[\(comp.elements.map(encodeElement).joined(separator: ","))]")
        root.append("\"compositional_deconstruction\":{\(cd.joined(separator: ","))}")
        return "{\(root.joined(separator: ","))}"
    }
}
