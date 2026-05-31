import Foundation

struct LoraEntry: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var path: String = ""
    var strength: Double = 1.0
    var enabled: Bool = true
    var notes: String = ""

    var displayName: String {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return path.isEmpty ? "Unnamed LoRA" : path
    }

    var isValid: Bool { !path.trimmingCharacters(in: .whitespaces).isEmpty }
}
