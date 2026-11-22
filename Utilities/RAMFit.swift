import Foundation

/// How a model's RAM need compares with this Mac's physical memory. One rule for the
/// picker's RAM pill and the Settings header.
nonisolated enum RAMFit: Equatable, Sendable {
    case comfortable, tight, strained, tooBig

    /// This Mac's physical memory in GB.
    static var physicalGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }

    static func of(ramGB: Double, physicalGB: Double) -> Self {
        guard physicalGB > 0 else { return .tooBig }
        switch ramGB / physicalGB {
        case ..<0.6: return .comfortable
        case ..<0.8: return .tight
        case ..<0.9: return .strained
        default: return .tooBig
        }
    }

    var tooltip: String {
        switch self {
        case .comfortable: "Fits your Mac well"
        case .tight: "Tight — may be slower on this Mac"
        case .strained: "Very tight — expect swapping and slow runs"
        case .tooBig: "Likely too big to run on this Mac"
        }
    }
}
