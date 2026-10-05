import Foundation

/// When the one-time support nudge shows (spec §5).
nonisolated enum SupportNudge {
    static let defaultThreshold = 50
    static let message = "Image Studio is free and built in spare time. If it's useful to you, a tip helps cover the costs "
        + "to build and maintain it. We appreciate anything you can provide."

    /// After `threshold` images, unless it was dismissed, the Support window
    /// was opened, or a tip was made.
    static func shouldShow(imagesGenerated: Int, threshold: Int, retired: Bool, tipped: Bool, windowOpened: Bool) -> Bool {
        imagesGenerated >= threshold && !retired && !tipped && !windowOpened
    }

    /// 50, or in DEBUG builds the launch argument `-supportNudgeThreshold <n>`
    /// (it lands in the arguments domain of `UserDefaults.standard`).
    static func configuredThreshold(arguments: any SupportDefaults = UserDefaults.standard) -> Int {
        #if DEBUG
            let override = arguments.integer(forKey: "supportNudgeThreshold")
            if override > 0 {
                return override
            }
        #endif
        return defaultThreshold
    }
}
