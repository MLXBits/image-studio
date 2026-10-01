import Foundation

// MARK: - Workflow building (SeedVR2 upscale)
//
// Mirrors the core-node graph of the gallery templates `utility_seedvr2_{3b,7b}_int8_upscale_image` (UNETLoader +
// VAELoader, tiled VAE encode/decode, one-step euler/simple KSampler at cfg 1), but with the resize done the way
// `mflux-upscale-seedvr2` does it so a remote upscale matches a local one: the output size and the softness pre-blur
// come from ``seedVR2Geometry(sourceWidth:sourceHeight:scale:softness:)``, and colour correction is `lab` (mflux always
// runs its wavelet + LAB transfer; the template ships `none`).

extension ComfyUIClient {
    struct SeedVR2WorkflowInput {
        /// `LoadImage` value for the uploaded source, as returned by ``uploadImage(localPath:subfolder:)``.
        var imageName: String
        var geometry: SeedVR2Geometry
        var seed: Int
        /// Server-side DiT filename (`models/diffusion_models`), e.g. `seedvr2_3b_int8_convrot.safetensors`.
        var unetName: String
        /// Server-side VAE filename (`models/vae`), e.g. `seedvr2_ema_vae_fp16.safetensors`.
        var vaeName: String
        var colorCorrection: String = "lab"
        /// See ``WorkflowInput/saveSubfolder``.
        var saveSubfolder: String = ""
    }

    /// Output size and softness pre-blur size for one upscale, computed exactly as mflux's `SeedVR2Util.preprocess_image`.
    struct SeedVR2Geometry: Equatable {
        var width: Int
        var height: Int
        /// Size to bicubic-downscale to before scaling back up to `width`×`height`; nil when softness is 0.
        var softWidth: Int?
        var softHeight: Int?
    }

    /// mflux: the short side becomes `scale × short`, floored to a multiple of 16 (`ScaleFactor.get_scaled_value`); both sides
    /// follow that ratio and are floored to even. Softness maps 0…1 to a 1…8 blur factor (`1 + softness × 7`); above 1 the
    /// image is first downscaled by that factor, which is the whole of what softness does.
    static func seedVR2Geometry(sourceWidth w: Int, sourceHeight h: Int, scale: Int, softness: Double) -> SeedVR2Geometry {
        let short = min(w, h)
        let target = scale * short - (scale * short) % 16
        let ratio = Double(target) / Double(short)
        let width = Int(Double(w) * ratio) / 2 * 2
        let height = Int(Double(h) * ratio) / 2 * 2
        let factor = 1.0 + max(0.0, min(1.0, softness)) * 7.0
        guard factor > 1.0 else { return SeedVR2Geometry(width: width, height: height) }
        return SeedVR2Geometry(
            width: width, height: height,
            softWidth: max(2, Int(Double(width) / factor)), softHeight: max(2, Int(Double(height) / factor))
        )
    }

    /// Picks the SeedVR2 DiT and VAE from the server's `UNETLoader`/`VAELoader` options. Prefers the int8 build the gallery
    /// templates use; skips the `sharp` fine-tunes so the default matches the stock model mflux runs. Nil when either is
    /// missing.
    static func pickSeedVR2Files(unets: [String], vaes: [String], is7B: Bool) -> (unet: String, vae: String)? {
        let size = is7B ? "7b" : "3b"
        let candidates = unets.filter {
            let n = $0.lowercased()
            return n.contains("seedvr2") && n.contains(size) && !n.contains("sharp")
        }
        guard let unet = candidates.first(where: { $0.lowercased().contains("int8") }) ?? candidates.first,
              let vae = vaes.first(where: { $0.lowercased().contains("seedvr2") })
        else { return nil }
        return (unet, vae)
    }

    private static func bicubicScale(_ image: [Any], width: Int, height: Int) -> [String: Any] {
        let inputs: [String: Any] = ["image": image, "upscale_method": "bicubic", "width": width, "height": height, "crop": "disabled"]
        return ["class_type": "ImageScale", "inputs": inputs]
    }

    /// Node count of a ``buildSeedVR2Workflow(_:)`` graph, for "Node X of N" progress.
    static func seedVR2NodeCount(_ geometry: SeedVR2Geometry) -> Int {
        geometry.softWidth == nil ? 11 : 12
    }

    func buildSeedVR2Workflow(_ input: SeedVR2WorkflowInput) -> Any {
        let g = input.geometry
        var raw: [String: Any] = [:]
        raw["LOAD"] = ["class_type": "LoadImage", "inputs": ["image": input.imageName]]
        raw["UNET"] = ["class_type": "UNETLoader", "inputs": ["unet_name": input.unetName, "weight_dtype": "default"]]
        raw["VAEL"] = ["class_type": "VAELoader", "inputs": ["vae_name": input.vaeName]]

        // Softness: bicubic down to the soft size first, then (always) bicubic to the target. RESIZE is also the colour
        // reference for post-processing, matching mflux's "style" input.
        var resizeSource: [Any] = ["LOAD", 0]
        if let sw = g.softWidth, let sh = g.softHeight {
            raw["SOFTEN"] = Self.bicubicScale(resizeSource, width: sw, height: sh)
            resizeSource = ["SOFTEN", 0]
        }
        raw["RESIZE"] = Self.bicubicScale(resizeSource, width: g.width, height: g.height)
        // Pads to the model's multiple of 16; post-processing crops back to RESIZE's size.
        raw["PRE"] = ["class_type": "SeedVR2Preprocess", "inputs": ["resized_images": ["RESIZE", 0]]]
        // Tile settings from the gallery template.
        let tiling: [String: Any] = ["tile_size": 512, "overlap": 128, "temporal_size": 4096, "temporal_overlap": 8]
        let encodeInputs = tiling.merging(["pixels": ["PRE", 0], "vae": ["VAEL", 0]]) { a, _ in a }
        raw["ENCODE"] = ["class_type": "VAEEncodeTiled", "inputs": encodeInputs]
        // Conditioning emits positive (slot 0) and negative (slot 1) from the encoded latent.
        raw["COND"] = ["class_type": "SeedVR2Conditioning", "inputs": ["model": ["UNET", 0], "vae_conditioning": ["ENCODE", 0]]]
        let samplerInputs: [String: Any] = [
            "model": ["UNET", 0], "positive": ["COND", 0], "negative": ["COND", 1], "latent_image": ["ENCODE", 0],
            "seed": input.seed, "steps": 1, "cfg": 1.0, "sampler_name": "euler", "scheduler": "simple", "denoise": 1.0,
        ]
        raw["KSAMPLER"] = ["class_type": "KSampler", "inputs": samplerInputs]
        let decodeInputs = tiling.merging(["samples": ["KSAMPLER", 0], "vae": ["VAEL", 0]]) { a, _ in a }
        raw["DECODE"] = ["class_type": "VAEDecodeTiled", "inputs": decodeInputs]
        let postInputs: [String: Any] = [
            "images": ["DECODE", 0], "original_resized_images": ["RESIZE", 0], "color_correction_method": input.colorCorrection,
        ]
        raw["POST"] = ["class_type": "SeedVR2PostProcessing", "inputs": postInputs]
        let prefix = input.saveSubfolder.isEmpty ? "mlxbits" : "mlxbits/\(input.saveSubfolder)"
        raw["SAVE"] = ["class_type": "SaveImage", "inputs": ["images": ["POST", 0], "filename_prefix": prefix]]
        return raw
    }

    /// Model-file options of one loader input, from the per-class `/object_info/{class}` (far lighter than the full catalog).
    func loaderOptions(nodeClass: String, input key: String) async throws -> [String] {
        let data = try await getData("/object_info/\(nodeClass)")
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let node = json[nodeClass] as? [String: Any],
              let input = node["input"] as? [String: Any],
              let required = input["required"] as? [String: Any],
              let field = required[key] as? [Any],
              let opts = field.first as? [String]
        else { throw ComfyUIError.decodeFailed("unexpected /object_info/\(nodeClass) shape") }
        return opts
    }

    /// Uploads a local image to the server's input dir via `POST /upload/image` and returns the `LoadImage` value for it
    /// (`subfolder/name`). The server renames on a name clash rather than overwriting, so the returned name — not the local
    /// basename — is what must go in the graph.
    func uploadImage(localPath: String, subfolder: String = "mlxbits") async throws -> String {
        let fileData: Data
        do { fileData = try Data(contentsOf: URL(fileURLWithPath: localPath)) } catch {
            throw ComfyUIError.decodeFailed("could not read \(localPath): \(error.localizedDescription)")
        }
        let boundary = "mlxbits-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("type", "input")
        field("subfolder", subfolder)
        // Only names the server copy (the graph uses the returned name), so swap anything that would break the quoted header.
        let filename = String((localPath as NSString).lastPathComponent.map { "\"\\\r\n".contains($0) ? "_" : $0 })
        body.append(Data((
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\r\n"
                + "Content-Type: application/octet-stream\r\n\r\n"
        ).utf8))
        body.append(fileData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        let respData = try await post("/upload/image", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
        guard let json = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any],
              let name = json["name"] as? String
        else { throw ComfyUIError.decodeFailed("no name in /upload/image response") }
        let sub = json["subfolder"] as? String ?? ""
        return sub.isEmpty ? name : "\(sub)/\(name)"
    }
}
