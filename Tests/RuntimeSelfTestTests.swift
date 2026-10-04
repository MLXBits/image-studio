import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// `--runtime-self-test` imports the heavy packages and runs every tool's
/// `--help` on the bundled interpreter, and fails if any of them fails.
struct RuntimeSelfTestTests {
    private func run(_ runtime: FakeRuntime) -> (status: Int32, lines: [String]) {
        var lines: [String] = []
        let status = RuntimeSelfTest.run(toolchain: runtime.toolchain(), environment: [:]) { lines.append($0) }
        return (status, lines)
    }

    @Test func everyToolAndTheImportsPass() throws {
        let (status, lines) = try run(FakeRuntime())
        #expect(status == 0)
        #expect(lines.filter { $0.hasPrefix("ok ") }.count == PythonTool.allCases.count + 1)
        #expect(lines.last == "Runtime self-test passed")
    }

    @Test func oneFailingToolFailsTheRunAndSaysWhy() throws {
        // $1 is run_tool.py (or -c), $2 the tool name (or the import line).
        let runtime = try FakeRuntime(python: """
        #!/bin/sh
        if [ "$2" = "mflux-save" ]; then echo "boom" >&2; exit 3; fi
        exit 0
        """)
        let (status, lines) = run(runtime)
        #expect(status == 1)
        #expect(lines.contains { $0.hasPrefix("FAIL mflux-save") && $0.contains("exit 3") && $0.contains("boom") })
        #expect(lines.last == "Runtime self-test: 1 failed")
    }

    @Test func missingRuntimeFails() throws {
        let (status, lines) = try run(FakeRuntime(python: nil))
        #expect(status == 1)
        #expect(lines.first?.hasPrefix("FAIL runtime") == true)
    }
}
