import Foundation

/// Where a queued job is in its run. Persisted in the job history as
/// `{"type": …, "message": …}`.
enum JobStatus: Equatable {
    case pending
    case running
    case completed
    case failed(String)
    case cancelled

    var label: String {
        switch self {
        case .pending: "Pending"
        case .running: "Running"
        case .completed: "Completed"
        case let .failed(m): "Failed: \(m)"
        case .cancelled: "Cancelled"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        default: false
        }
    }
}

extension JobStatus: Codable {
    enum CodingKey: String, Swift.CodingKey { case type, message }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKey.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "pending": self = .pending
        case "running": self = .running
        case "completed": self = .completed
        case "cancelled": self = .cancelled
        default:
            let msg = (try? c.decode(String.self, forKey: .message)) ?? type
            self = .failed(msg)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKey.self)
        switch self {
        case .pending: try c.encode("pending", forKey: .type)
        case .running: try c.encode("running", forKey: .type)
        case .completed: try c.encode("completed", forKey: .type)
        case .cancelled: try c.encode("cancelled", forKey: .type)
        case let .failed(m): try c.encode("failed", forKey: .type); try c.encode(m, forKey: .message)
        }
    }
}
