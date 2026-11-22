import SwiftUI

nonisolated extension RAMFit {
    var color: Color {
        switch self {
        case .comfortable: .green
        case .tight: .yellow
        case .strained: .orange
        case .tooBig: .red
        }
    }
}
