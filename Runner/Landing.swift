import Foundation

/// A runner's latest landing: one output image of a run reaching disk.
///
/// It is state, not an event. Several images that land in the same main-actor
/// turn overwrite each other before an observer runs, so the value carries the
/// run's first image along rather than relying on the observer to see each one.
nonisolated struct Landing: Equatable, Sendable {
    /// Counts every landing of the runner, so two landings in a row never compare
    /// equal: a second batch of the same size still reads as new.
    let seq: Int
    /// Counts the runner's runs. A new value means a new run began landing.
    let run: Int
    /// The first image of ``run``: the one the gallery selects.
    let firstPath: String
}

/// Compares every queue's ``Landing`` before and after a change, for the one
/// handler that rescans the gallery and selects a run's first image.
nonisolated enum LandingDiff {
    nonisolated struct Outcome: Equatable {
        /// Any queue has a new landing, so the gallery needs a rescan.
        let landed: Bool
        /// The first image of a run that began landing, if one did. When two
        /// queues begin a run together (the gate makes that rare), the later one
        /// in run order wins.
        let selectPath: String?
    }

    /// `old` and `new` hold one landing per queue, in the same order.
    static func compare(old: [Landing?], new: [Landing?]) -> Outcome {
        var landed = false
        var selectPath: String?
        for (index, landing) in new.enumerated() {
            guard let landing else { continue }
            let previous = index < old.count ? old[index] : nil
            guard landing != previous else { continue }
            landed = true
            if landing.run != previous?.run {
                selectPath = landing.firstPath
            }
        }
        return Outcome(landed: landed, selectPath: selectPath)
    }
}
