import Foundation

/// A subprocess's stdout as one ordered stream. Every chunk read is buffered
/// before the stream finishes, so when it finishes at EOF, a consumer that runs
/// exit handling after the loop never loses a final line, however late it runs.
/// The backstop path can drop bytes still unread in the pipe.
nonisolated enum DriverOutputStream {
    /// Call before `process.run()`: it sets the process's `terminationHandler`.
    /// The stream finishes at EOF, or `backstop` after exit if EOF never comes
    /// (something else holds the pipe open).
    static func make(
        stdout: FileHandle, process: Process, backstop: Duration = .seconds(2)
    ) -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        stdout.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                // Drop the handler at EOF, or it keeps firing and pins a core.
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }
        // shortcut: the backstop skips draining the pipe, so unread bytes are lost; drain it
        // without blocking if a driver ever spawns children that hold stdout open.
        process.terminationHandler = { _ in
            Task {
                try? await Task.sleep(for: backstop)
                stdout.readabilityHandler = nil
                continuation.finish()
            }
        }
        return stream
    }
}
