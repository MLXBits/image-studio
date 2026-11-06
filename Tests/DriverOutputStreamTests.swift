import Foundation
@testable import MLXBits_Image_Studio
import Testing

@Suite("DriverOutputStream")
struct DriverOutputStreamTests {
    private func shell(_ script: String) -> (Process, Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        return (process, pipe)
    }

    private func collect(_ stream: AsyncStream<Data>) async -> String {
        var out = Data()
        for await chunk in stream {
            out.append(chunk)
        }
        return String(bytes: out, encoding: .utf8) ?? ""
    }

    /// The driver writes a result and exits; the consumer starts only after
    /// the backstop deadline has passed. The result must still arrive.
    @Test func finalLineSurvivesConsumerSlowerThanBackstop() async throws {
        let (process, pipe) = shell(#"printf '{"event":"result"}\n'"#)
        let stream = DriverOutputStream.make(
            stdout: pipe.fileHandleForReading, process: process, backstop: .milliseconds(10)
        )
        try process.run()
        process.waitUntilExit()
        try await Task.sleep(for: .milliseconds(300))
        #expect(await collect(stream) == "{\"event\":\"result\"}\n")
    }

    /// A background child keeps stdout open after the driver exits, so EOF
    /// never comes in time; the backstop still finishes the stream.
    @Test func backstopFinishesWhenEOFNeverArrives() async throws {
        let (process, pipe) = shell("echo hi; sleep 5 & exit 0")
        let stream = DriverOutputStream.make(
            stdout: pipe.fileHandleForReading, process: process, backstop: .milliseconds(100)
        )
        let start = ContinuousClock.now
        try process.run()
        #expect(await collect(stream) == "hi\n")
        #expect(ContinuousClock.now - start < .seconds(3))
    }
}
