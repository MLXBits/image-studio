import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// Local Gemma runs `mlx_lm.generate` (retrying VLM-only models through
/// `mlx_vlm.generate`) on the bundled interpreter via run_tool.py.
struct GemmaChatRunnerRunTests {
    @Test func localGemmaRunsMlxLmOnTheBundledInterpreter() async throws {
        // $1 is run_tool.py, $2 the tool name.
        let runtime = try FakeRuntime(python: "#!/bin/sh\necho \"tool=$2 model=$4\"\n")
        let (output, exitCode) = try await GemmaChatRunner.run(
            modelPath: "org/model", prompt: "hi", maxTokens: 8, temp: 0.1,
            environment: [:], toolchain: runtime.toolchain()
        )
        #expect(exitCode == 0)
        #expect(output.contains("tool=mlx_lm.generate model=org/model"))
    }

    @Test func vlmOnlyModelsRetryThroughMlxVlm() async throws {
        let runtime = try FakeRuntime(python: """
        #!/bin/sh
        if [ "$2" = "mlx_lm.generate" ]; then echo "Model type gemma4_unified not supported."; exit 1; fi
        echo "tool=$2"
        """)
        let (output, exitCode) = try await GemmaChatRunner.run(
            modelPath: "org/model", prompt: "hi", maxTokens: 8, temp: 0.1,
            environment: [:], toolchain: runtime.toolchain()
        )
        #expect(exitCode == 0)
        #expect(output.contains("tool=mlx_vlm.generate"))
    }

    @Test func missingRuntimeIsReported() async throws {
        let runtime = try FakeRuntime(python: nil)
        await #expect(throws: ToolchainError.runtimeMissing) {
            try await GemmaChatRunner.run(
                modelPath: "org/model", prompt: "hi", maxTokens: 8, temp: 0.1,
                environment: [:], toolchain: runtime.toolchain()
            )
        }
    }
}
