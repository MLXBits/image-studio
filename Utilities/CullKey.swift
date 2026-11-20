import AppKit

/// A Lightroom-style culling key: P pick, X reject, U unflag, 0–5 rate.
/// Matched on characters, so it works on any keyboard layout; a ⌘ shortcut
/// (⌘X Cut, ⌘P Print) is never one. The gallery grid, the full-size viewer
/// and Compare all read keys through this.
enum CullKey: Equatable {
    case flag(PickFlag?)
    case rating(Int)

    init?(characters: String?, command: Bool) {
        guard !command, let characters, characters.count == 1 else { return nil }
        switch characters {
        case "p", "P": self = .flag(.pick)
        case "x", "X": self = .flag(.reject)
        case "u", "U": self = .flag(nil)
        case "0", "1", "2", "3", "4", "5": self = .rating(Int(characters) ?? 0)
        default: return nil
        }
    }

    init?(_ event: NSEvent) {
        self.init(characters: event.charactersIgnoringModifiers, command: event.modifierFlags.contains(.command))
    }
}
