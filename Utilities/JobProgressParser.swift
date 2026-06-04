import Foundation

enum JobProgressParser {
    static func parseStep(from log: String) -> (current: Int, total: Int)? {
        // tqdm: "  3/4 [" — grab last occurrence
        var best: (Int, Int)?
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
}
