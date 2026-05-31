import Foundation

enum JobProgressParser {
    static func parseStep(from log: String) -> (current: Int, total: Int)? {
        // tqdm: "  3/4 [" — grab last occurrence
        var best: (Int, Int)? = nil
        let lines = log.components(separatedBy: "\n")
        for line in lines {
            // Simple scan: look for "N/M" where M looks like a step count
            if let range = line.range(of: #"\b(\d+)/(\d+)\b"#, options: .regularExpression) {
                let fragment = String(line[range])
                let parts = fragment.split(separator: "/")
                if parts.count == 2,
                   let cur = Int(parts[0]),
                   let tot = Int(parts[1]),
                   tot > 0, tot <= 500 {
                    best = (cur, tot)
                }
            }
        }
        return best
    }

    static func parseSeed(from log: String) -> Int? {
        // mflux prints "Using seed: 12345" or "Seed: 12345"
        let pattern = #"(?:Using seed|Seed):\s*(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: log, range: NSRange(log.startIndex..., in: log)),
              let r = Range(match.range(at: 1), in: log) else { return nil }
        return Int(log[r])
    }
}
