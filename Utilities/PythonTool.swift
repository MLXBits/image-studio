/// A command-line tool the app runs from a Python environment. Raw values are
/// the console-script names, the same names as mflux's old launcher scripts,
/// and must match `Runtime/tools.txt`: the runtime build smoke-tests every name
/// listed there, and `PythonToolTests` keeps the two in step.
nonisolated enum PythonTool: String, CaseIterable, Sendable {
    case flux2 = "mflux-generate-flux2"
    case flux2Edit = "mflux-generate-flux2-edit"
    case ideogram4 = "mflux-generate-ideogram4"
    case krea2 = "mflux-generate-krea2"
    case zImage = "mflux-generate-z-image"
    case zImageTurbo = "mflux-generate-z-image-turbo"
    case seedVR2 = "mflux-upscale-seedvr2"
    case save = "mflux-save"
    case hf
    case mlxLmGenerate = "mlx_lm.generate"
    case mlxVlmGenerate = "mlx_vlm.generate"

    /// mflux's own tools follow the DMG's Custom Python override. The rest (the
    /// Hugging Face CLI, local Gemma) always run on the bundled runtime.
    var isMflux: Bool {
        rawValue.hasPrefix("mflux-")
    }
}
