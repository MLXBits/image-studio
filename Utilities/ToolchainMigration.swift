import Foundation

/// The one-time move from the old "mflux binary directory" setting to the
/// toolchain (spec §3). A uv-managed mflux, the one this app used to install,
/// gives way to the bundled runtime. Any other folder, such as a dev checkout,
/// becomes the Custom Python, using the interpreter its launcher names.
nonisolated enum ToolchainMigration {
    /// The Custom Python to carry over from `dir`, or nil to use the bundled runtime.
    static func customPython(fromLegacyBinaryDir dir: String) -> String? {
        guard !dir.isEmpty else { return nil }
        let shim = ((dir as NSString).expandingTildeInPath as NSString)
            .appendingPathComponent(PythonTool.flux2.rawValue)
        guard let python = venvPython(fromShim: shim), !isUVManaged(python: python) else { return nil }
        return python
    }

    /// uv installs tools into `<data dir>/uv/tools/<name>/`, wherever
    /// `XDG_DATA_HOME` puts the data dir.
    static func isUVManaged(python: String) -> Bool {
        python.contains("/uv/tools/")
    }

    /// The interpreter a launcher script runs: its shebang or, for the `/bin/sh`
    /// form pip and uv write when the path has spaces or is long, the path on
    /// its `'''exec' <python> "$0" "$@"` line. Nil unless that interpreter exists.
    static func venvPython(fromShim shimPath: String) -> String? {
        guard !shimPath.isEmpty,
              let handle = FileHandle(forReadingAtPath: shimPath),
              let head = try? handle.read(upToCount: 2048),
              let text = String(data: head, encoding: .utf8),
              text.hasPrefix("#!") else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var python = lines[0].dropFirst(2).trimmingCharacters(in: .whitespaces)
        if python == "/bin/sh" {
            // Only the exec form names an interpreter; any other shell script doesn't.
            guard lines.count > 1 else { return nil }
            let words = shellWords(lines[1], limit: 2)
            guard words.count == 2, words[0] == "exec" else { return nil }
            python = words[1]
        }
        return FileManager.default.isExecutableFile(atPath: python) ? python : nil
    }

    /// The first `limit` words of a shell command line, with quoting removed:
    /// single-quoted text is literal, double-quoted text honours backslash
    /// escapes, and adjacent pieces join into one word. pip quotes the path in
    /// double quotes; uv in single quotes, writing an apostrophe as `'"'"'`.
    static func shellWords(_ line: Substring, limit: Int) -> [String] {
        var words: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for char in line {
            if escaped {
                word.append(char)
                escaped = false
            } else if let open = quote {
                if char == open {
                    quote = nil
                } else if char == "\\", open == "\"" {
                    escaped = true
                } else {
                    word.append(char)
                }
            } else if char == "'" || char == "\"" {
                quote = char
                inWord = true
            } else if char == "\\" {
                escaped = true
                inWord = true
            } else if char == " " || char == "\t" {
                if inWord {
                    words.append(word)
                    if words.count == limit {
                        return words
                    }
                    word = ""
                    inWord = false
                }
            } else {
                word.append(char)
                inWord = true
            }
        }
        if inWord, quote == nil {
            words.append(word)
        }
        return words
    }
}
