import Foundation

/// Reads a failed job's message and log for the failed-job view: a one-line
/// summary of what went wrong, and whether it was a gated Hugging Face repo.
nonisolated enum FailureSummary {
    private static let gatedMarkers = [
        "private or gated repo", "GatedRepoError", "is restricted", "403 Client Error", "401 Client Error",
    ]

    /// The last Python exception line in the log (`ValueError: …`), which names
    /// the real cause; otherwise the first line of the message; otherwise the
    /// last non-empty log line.
    static func line(message: String, log: String) -> String {
        let logLines = log.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let exception = logLines.last(where: { isExceptionLine($0) }) {
            return exception
        }
        let firstMessageLine = message.split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if !firstMessageLine.isEmpty {
            return firstMessageLine
        }
        return logLines.last ?? "Unknown error"
    }

    /// Whether the failure was a gated or private Hugging Face repo, which needs
    /// the user to accept its terms and add a token.
    static func isGatedRepo(message: String, log: String) -> Bool {
        let combined = message + "\n" + log
        return gatedMarkers.contains { combined.contains($0) }
    }

    /// `ValueError: …`, `torch.OutOfMemoryError: …`, `Exception: …`, `KeyboardInterrupt`
    /// — a dotted name ending in (or being) Error, Exception or Interrupt, alone or
    /// followed by a colon.
    private static func isExceptionLine(_ line: String) -> Bool {
        line.range(
            of: #"^(?:[A-Za-z_][\w.]*)?(Error|Exception|Interrupt)(:.*)?$"#,
            options: .regularExpression
        ) != nil
    }
}
