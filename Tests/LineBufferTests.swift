import Foundation
@testable import MLXBits_Image_Studio
import Testing

@Suite("LineBuffer")
struct LineBufferTests {
    private static let samples = ["a…b", "caf\u{E9}!", "x\u{1F600}y"]

    @Test func ndjsonLineSplitAcrossTwoChunks() {
        var buffer = LineBuffer()
        let line = #"{"event":"loading","message":"Loading…"}"#
        let bytes = Data((line + "\n").utf8)
        let mid = bytes.count / 2
        #expect(buffer.append(bytes[..<mid]).isEmpty)
        #expect(buffer.append(bytes[mid...]) == [line])
    }

    @Test func multibyteCharacterSplitAtEveryByteOffset() {
        for sample in Self.samples {
            let bytes = Data((sample + "\n").utf8)
            for split in 0 ... bytes.count {
                var buffer = LineBuffer()
                var lines = buffer.append(bytes[..<split])
                lines += buffer.append(bytes[split...])
                #expect(lines == [sample], "\(sample) split at \(split)")
            }
        }
    }

    @Test func severalLinesInOneChunk() {
        var buffer = LineBuffer()
        #expect(buffer.append(Data("one\ntwo\n\nthree\npart".utf8)) == ["one", "two", "", "three"])
        #expect(buffer.flush() == "part")
    }

    @Test func crlfLineEndingsAreStripped() {
        var buffer = LineBuffer()
        #expect(buffer.append(Data("one\r\ntwo\r\n".utf8)) == ["one", "two"])
    }

    @Test func remainderFlushedAtEOF() {
        var buffer = LineBuffer()
        #expect(buffer.append(Data("done\nlast line".utf8)) == ["done"])
        #expect(buffer.flush() == "last line")
        #expect(buffer.flush() == nil)
    }

    @Test func invalidUTF8DecodesLossilyInsteadOfDropping() {
        var buffer = LineBuffer()
        let lines = buffer.append(Data([0x61, 0xFF, 0x62, 0x0A]))
        #expect(lines == ["a\u{FFFD}b"])
    }
}

@Suite("TextChunkDecoder")
struct TextChunkDecoderTests {
    @Test func multibyteCharacterSplitAtEveryByteOffset() {
        for sample in ["a…b\r", "caf\u{E9}", "x\u{1F600}y", "\u{1F600}"] {
            let bytes = Data(sample.utf8)
            for split in 0 ... bytes.count {
                var decoder = TextChunkDecoder()
                var text = decoder.decode(bytes[..<split])
                text += decoder.decode(bytes[split...])
                text += decoder.flush() ?? ""
                #expect(text == sample, "\(sample) split at \(split)")
            }
        }
    }

    @Test func textWithoutNewlinesPassesThrough() {
        var decoder = TextChunkDecoder()
        #expect(decoder.decode(Data("10%|\r".utf8)) == "10%|\r")
    }

    @Test func truncatedSequenceAtEOFFlushesLossily() {
        var decoder = TextChunkDecoder()
        #expect(decoder.decode(Data([0x61, 0xE2, 0x80])) == "a")
        #expect(decoder.flush() == "\u{FFFD}")
        #expect(decoder.flush() == nil)
    }

    @Test func invalidBytesAreNotDropped() {
        var decoder = TextChunkDecoder()
        #expect(decoder.decode(Data([0x61, 0xFF, 0x62])) == "a\u{FFFD}b")
    }

    @Test func streamEndingWithProcessEmitsTruncatedTailOnce() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/printf")
        process.arguments = ["a\\342\\200"] // "a" plus a truncated 3-byte sequence
        let pipe = Pipe()
        process.standardOutput = pipe
        let chunks = TextChunkDecoder.stream(reading: pipe, endingWith: process)
        try process.run()
        var text = ""
        for await chunk in chunks {
            text += chunk
        }
        #expect(text == "a\u{FFFD}")
    }
}
