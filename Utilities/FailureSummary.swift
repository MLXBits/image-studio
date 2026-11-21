import Foundation

/// Reads a failed job's message and log for the failed-job view: a one-line
/// summary of what went wrong, and whether it was a gated Hugging Face repo.
nonisolated enum FailureSummary {
    private static let gatedMarkers = [
        "private or gated repo", "GatedRepoError", "is restricted", "403 Client Error", "401 Client Error",
    ]
    /// This Mac running out of memory under MLX: Metal's abort (`[METAL] Command buffer
    /// execution failed: Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)`)
    /// and MLX's refused allocation (`[metal::malloc] Attempting to allocate … greater than the
    /// maximum allowed buffer size`). Not CUDA's: that is a ComfyUI server's memory, not this Mac's.
    private static let outOfMemoryMarkers = [
        "kIOGPUCommandBufferCallbackErrorOutOfMemory", "[metal::malloc]",
    ]
    static let outOfMemoryLine = "Out of memory — this model needs more unified memory than is free. "
        + "Try Low RAM mode, a lower precision or a smaller size, or quit other apps."

    /// What ran out of memory, in words, when the job did; else the last Python
    /// exception line in the log (`ValueError: …`), which names the real cause;
    /// otherwise the first line of the message; otherwise the last non-empty log line.
    static func line(message: String, log: String) -> String {
        if isOutOfMemory(message: message, log: log) {
            return outOfMemoryLine
        }
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

    /// Whether the job ran out of this Mac's memory, as a large model on a small Mac
    /// can while it loads.
    static func isOutOfMemory(message: String, log: String) -> Bool {
        let combined = message + "\n" + log
        return outOfMemoryMarkers.contains { combined.contains($0) }
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
