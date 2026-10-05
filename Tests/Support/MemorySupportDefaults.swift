import Foundation
@testable import MLXBits_Image_Studio

/// In-memory ``SupportDefaults`` for tests. A real `UserDefaults` suite would
/// leave a file in ~/Library/Preferences on every run.
final class MemorySupportDefaults: SupportDefaults {
    private var values: [String: Any] = [:]

    func integer(forKey defaultName: String) -> Int {
        values[defaultName] as? Int ?? 0
    }

    func bool(forKey defaultName: String) -> Bool {
        values[defaultName] as? Bool ?? false
    }

    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }
}
