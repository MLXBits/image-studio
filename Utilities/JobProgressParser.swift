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
        for line in log.components(separatedBy: "\n") {
            guard let countRange = line.range(of: #"\b(\d+)/(\d+)\b"#, options: .regularExpression) else { continue }
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
}
