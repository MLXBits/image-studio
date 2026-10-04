import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// The model picker offers a family only when the active toolchain can run its
/// CLI: always with the bundled runtime, and per installed launcher with a
/// Custom Python.
struct ModelAvailabilityTests {
    @Test func bundledRuntimeOffersEveryModel() throws {
        let toolchain = try FakeRuntime().toolchain()
        #expect(FluxModelVariant.customTargets(toolchain: toolchain) == FluxModelVariant.allModels)
    }

    @Test func customPythonOffersOnlyFamiliesItHasLaunchersFor() throws {
        let bin = FakeRuntime.tempDirectory("venv").appendingPathComponent("bin")
        try FakeRuntime.writeExecutable(FakeRuntime.succeeding, to: bin.appendingPathComponent("python"))
        try FakeRuntime.writeExecutable(FakeRuntime.succeeding, to: bin.appendingPathComponent("mflux-generate-flux2"))
        let toolchain = try FakeRuntime().toolchain(customPython: bin.appendingPathComponent("python").path)
        #expect(FluxModelVariant.customTargets(toolchain: toolchain) == FluxModelVariant.builtIn)
    }

    @Test func everyModelNamesAToolTheRuntimeShips() {
        for model in FluxModelVariant.allModels {
            #expect(model.generateTool != nil, "\(model) has no generation tool")
        }
        #expect(FluxModelVariant.custom.generateTool == nil)
    }
}
