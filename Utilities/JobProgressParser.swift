import Foundation

enum JobProgressParser {
    struct StepProgress {
        let current: Int
        let total: Int
        let elapsed: String? // e.g. "1:23"
        let remaining: String? // e.g. "0:05"
    }

    static func parseStep(from log: String) -> StepProgress? {
        // tqdm format: "  3/4 [00:01<00:05, 1.62s/it]"
        var best: StepProgress?
        // tqdm redraws with "\r", so one chunk can hold several updates; the last one wins.
        for line in log.components(separatedBy: CharacterSet(charactersIn: "\r\n")) {
            guard isStepBarCandidate(line),
                  let countRange = line.range(of: #"\b(\d+)/(\d+)\b"#, options: .regularExpression) else { continue }
            let fragment = String(line[countRange])
            let parts = fragment.split(separator: "/")
            guard parts.count == 2,
                  let cur = Int(parts[0]),
                  let tot = Int(parts[1]),
                  tot > 0, tot <= 500 else { continue }

            // Only count genuine tqdm progress bars: tqdm always renders the count as
            // "N/M [elapsed<remaining, ...]", so the count is immediately followed by " [".
            // This rejects look-alikes such as the LoRA "(336/336 keys matched)" line.
            let suffix = String(line[countRange.upperBound...])
            guard suffix.drop(while: { $0 == " " }).first == "[" else { continue }

            // Parse "[elapsed<remaining" that may follow the count
            var elapsed: String?
            var remaining: String?
            if let timingRange = suffix.range(
                of: #"\[(\d+:\d+(?::\d+)?)<(\d+:\d+(?::\d+)?)"#, options: .regularExpression
            ) {
                let timing = String(suffix[timingRange].dropFirst()) // drop leading "["
                let timeParts = timing.split(separator: "<", maxSplits: 1)
                if timeParts.count == 2 {
                    elapsed = String(timeParts[0])
                    remaining = String(timeParts[1])
                }
            }
            best = StepProgress(current: cur, total: tot, elapsed: elapsed, remaining: remaining)
        }
        return best
    }

    /// Rejects download bars before the count is read. Hugging Face ("Fetching 12 files: 3/12")
    /// and byte bars ("45.2M/1.2G [..., 12.3MB/s]") share tqdm's "N/M [" shape with step bars.
    /// Accepts a line with an iteration rate ("it/s", "s/it"), or one with no rate yet.
    private static func isStepBarCandidate(_ line: String) -> Bool {
        if line.contains("Fetching") || line.contains(" files") {
            return false
        }
        // Shard and download bars may use the default "it" unit; judge the description before the counts.
        if line.range(
            of: #"^[^\d|]*(Downloading|Loading checkpoint shards|\bshards\b)"#, options: .regularExpression
        ) != nil {
            return false
        }
        if line.range(of: #"\d\s*[kKMGT]?i?B/s"#, options: .regularExpression) != nil {
            return false
        }
        if line.range(of: #"\d[kKMGT]i?B?/\d"#, options: .regularExpression) != nil {
            return false
        }
        if line.contains("it/s") || line.contains("s/it") {
            return true
        }
        return !line.contains("/s")
    }
}
