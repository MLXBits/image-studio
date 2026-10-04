/// Which app this binary is: the GitHub DMG or the sandboxed App Store build.
/// A constant rather than `#if` at each use, so both sides of every check
/// compile in both flavors (spec §7) and CI's App Store compile job catches
/// breakage in either.
nonisolated enum BuildFlavor {
    #if APP_STORE
        static let isAppStore = true
    #else
        static let isAppStore = false
    #endif
}
