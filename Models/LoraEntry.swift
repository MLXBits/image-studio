import Foundation

struct LoraEntry: Identifiable, Codable, Equatable, Hashable {
    enum CodingKeys: String, CodingKey {
        case id, path, strength, enabled, notes, modelFamily
    }

    var id = UUID()
    var path: String = ""
    var strength: Double = 1.0
    var enabled: Bool = true
    var notes: String = ""
    var modelFamily: ModelFamily = .flux

    var displayName: String {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return path.isEmpty ? "Unnamed LoRA" : path
    }

    var isValid: Bool {
        !path.trimmingCharacters(in: .whitespaces).isEmpty
    }

    init(
        id: UUID = UUID(),
        path: String = "",
        strength: Double = 1.0,
        enabled: Bool = true,
        notes: String = "",
        modelFamily: ModelFamily = .flux
    ) {
        self.id = id
        self.path = path
        self.strength = strength
        self.enabled = enabled
        self.notes = notes
        self.modelFamily = modelFamily
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? 1.0
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        modelFamily = try c.decodeIfPresent(ModelFamily.self, forKey: .modelFamily) ?? .flux
    }
}
