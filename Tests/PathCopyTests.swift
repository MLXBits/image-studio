@testable import MLXBits_Image_Studio
import Testing

@Suite("PathCopy")
struct PathCopyTests {
    @Test func relativeStripsOutputDirPrefix() {
        #expect(PathCopy.relative("/Users/paul/out/board/img.png", to: "/Users/paul/out") == "board/img.png")
        #expect(PathCopy.relative("/Users/paul/out/img.png", to: "/Users/paul/out") == "img.png")
    }

    @Test func relativeHandlesTrailingSlashBase() {
        #expect(PathCopy.relative("/Users/paul/out/img.png", to: "/Users/paul/out/") == "img.png")
    }

    @Test func relativeFallsBackToAbsoluteWhenNotUnderBase() {
        #expect(PathCopy.relative("/Users/paul/other/img.png", to: "/Users/paul/out") == "/Users/paul/other/img.png")
    }

    @Test func relativeDoesNotMatchSiblingDirPrefix() {
        // "/outside" starts with the string "/out" but is a sibling dir, not under it.
        #expect(PathCopy.relative("/Users/paul/outside/img.png", to: "/Users/paul/out") == "/Users/paul/outside/img.png")
    }
}
