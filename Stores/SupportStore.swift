import Foundation

/// The `UserDefaults` calls the support state makes, so tests can keep it in
/// memory: the test host isn't sandboxed, and every suite it opens leaves a
/// file in ~/Library/Preferences.
nonisolated protocol SupportDefaults: AnyObject {
    func integer(forKey defaultName: String) -> Int
    func bool(forKey defaultName: String) -> Bool
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: SupportDefaults {}

/// What the support nudge needs to know, app-global rather than per profile
/// (spec §5): images generated, and whether the nudge was dismissed, the
/// Support window opened or a tip made.
@Observable
final class SupportStore {
    private enum Key {
        static let imagesGenerated = "support.imagesGenerated"
        static let nudgeRetired = "support.nudgeRetired"
        static let windowOpened = "support.windowOpened"
        static let hasTipped = "support.hasTipped"
    }

    private(set) var imagesGenerated: Int
    private(set) var nudgeRetired: Bool
    private(set) var windowOpened: Bool
    private(set) var hasTipped: Bool
    @ObservationIgnored let defaults: any SupportDefaults
    @ObservationIgnored private let threshold: Int

    var showsNudge: Bool {
        SupportNudge.shouldShow(
            imagesGenerated: imagesGenerated, threshold: threshold,
            retired: nudgeRetired, tipped: hasTipped, windowOpened: windowOpened
        )
    }

    init(defaults: any SupportDefaults, threshold: Int = SupportNudge.configuredThreshold()) {
        self.defaults = defaults
        self.threshold = threshold
        imagesGenerated = defaults.integer(forKey: Key.imagesGenerated)
        nudgeRetired = defaults.bool(forKey: Key.nudgeRetired)
        windowOpened = defaults.bool(forKey: Key.windowOpened)
        hasTipped = defaults.bool(forKey: Key.hasTipped)
    }

    func recordImages(_ count: Int) {
        guard count > 0 else { return }
        imagesGenerated += count
        defaults.set(imagesGenerated, forKey: Key.imagesGenerated)
    }

    func retireNudge() {
        nudgeRetired = true
        defaults.set(true, forKey: Key.nudgeRetired)
    }

    func noteWindowOpened() {
        windowOpened = true
        defaults.set(true, forKey: Key.windowOpened)
    }

    func noteTipped() {
        hasTipped = true
        defaults.set(true, forKey: Key.hasTipped)
    }
}
