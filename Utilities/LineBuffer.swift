import Foundation
import os

/// Lossy UTF-8 decode shared by the helpers below: invalid bytes become U+FFFD
/// and nothing is dropped. Lossy decoding is the point here, so SwiftLint's advice
/// to use the failable `String(bytes:encoding:)` does not apply.
nonisolated private func decodeLossy(_ bytes: some Sequence<UInt8>) -> String {
    // swiftlint:disable:next optional_data_string_conversion
    String(decoding: Array(bytes), as: UTF8.self)
}

/// Splits a byte stream into lines without losing a multibyte character that a
/// pipe read cut in two. Splitting on the 0x0A byte before decoding is what makes
/// that safe: a newline byte never occurs inside a multibyte UTF-8 sequence.
nonisolated struct LineBuffer {
    private var pending = Data()

    /// Adds `data` and returns every line it completed, without the line ending
    /// (`\n` or `\r\n`). Bytes after the last newline stay buffered.
    mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            var line = pending[pending.startIndex ..< newline]
            if line.last == 0x0D {
                line.removeLast()
            }
            lines.append(decodeLossy(line))
            pending.removeSubrange(pending.startIndex ... newline)
        }
        return lines
    }

    /// Returns the unterminated remainder at EOF (nil when empty) and clears it.
    mutating func flush() -> String? {
        defer { pending.removeAll() }
        guard !pending.isEmpty else { return nil }
        return decodeLossy(pending.last == 0x0D ? pending.dropLast() : pending[...])
    }
}

/// Decodes a byte stream into text chunks for readers that need the raw text
/// (tqdm progress ends in `\r`, not `\n`) rather than lines. An incomplete UTF-8
/// sequence at the end of a chunk is held back and prepended to the next one, so
/// a split character is never dropped. Invalid bytes decode lossily.
nonisolated struct TextChunkDecoder {
    /// Offset where a truncated (but so far valid) multibyte sequence begins, or
    /// `bytes.count` when the data ends on a character boundary.
    private static func incompleteTailStart(in bytes: Data) -> Int {
        let end = bytes.count
        var offset = end - 1
        // A sequence is at most 4 bytes, so its lead byte is within the last 4.
        while offset >= max(0, end - 4) {
            let byte = bytes[bytes.startIndex + offset]
            if byte & 0xC0 == 0x80 {
                offset -= 1
                continue
            }
            let expected = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            return expected > end - offset ? offset : end
        }
        return end
    }

    private var tail = Data()

    /// Returns the text decodable from `data` plus any carried tail; may be empty.
    mutating func decode(_ data: Data) -> String {
        var bytes = tail
        bytes.append(data)
        let cut = Self.incompleteTailStart(in: bytes)
        tail = Data(bytes[cut...])
        return decodeLossy(bytes[..<cut])
    }

    /// Returns whatever is still held back at EOF (nil when nothing) and clears it.
    mutating func flush() -> String? {
        defer { tail.removeAll() }
        return tail.isEmpty ? nil : decodeLossy(tail)
    }
}

nonisolated extension TextChunkDecoder {
    /// Text chunks read from `pipe` until EOF, decoded through one decoder so a
    /// character split across reads survives. When `process` is given, its exit
    /// also finishes the stream after a short grace (a grandchild holding the pipe
    /// open would otherwise keep it alive); that replaces its `terminationHandler`.
    static func stream(reading pipe: Pipe, endingWith process: Process? = nil) -> AsyncStream<String> {
        AsyncStream<String> { continuation in
            // Guards the decoder and, with `finished`, the stream's completion: every finish()
            // goes through this one locked path, so the last yield always precedes finish() no
            // matter which thread (the EOF pump or the termination backstop) completes it.
            let state = OSAllocatedUnfairLock(initialState: (decoder: TextChunkDecoder(), finished: false))
            @Sendable func finish() {
                let first = state.withLock { state -> Bool in
                    let shouldFinish = !state.finished
                    if shouldFinish {
                        state.finished = true
                    }
                    return shouldFinish
                }
                guard first else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                // flush() clears the tail, so EOF and the backstop can't both emit it.
                if let rest = state.withLock({ $0.decoder.flush() }) {
                    continuation.yield(rest)
                }
                continuation.finish()
            }
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    finish()
                } else {
                    let text = state.withLock { $0.decoder.decode(data) }
                    if !text.isEmpty {
                        continuation.yield(text)
                    }
                }
            }
            process?.terminationHandler = { _ in
                // Grace period: a normal exit's pipe drains before this fires, so only a
                // grandchild holding the pipe open needs the backstop to end the stream.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05, execute: finish)
            }
        }
    }
}
