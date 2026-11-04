import Foundation

// MARK: - Connection test / system stats / model discovery

extension ComfyUIClient {
    struct SystemStats {
        var serverVersion: String?
        var os: String?
        var gpuNames: [String] = []
        var vramTotalGb: Double?
        /// Driver-level free VRAM (bytes) — `vram_free` from `/system_stats`. This is what actually
        /// reflects GPU occupancy, because ComfyUI's safetensors weights are held outside torch's
        /// allocator (via the CUDA driver), so `torch_vram_free` barely moves even with a large model
        /// resident. The residency signal for the header pill uses *this*, not the torch number.
        var vramFreeBytes: Int64?
        /// Driver-level total VRAM (bytes) — `vram_total`. Constant for a given device; pairs with
        /// ``vramFreeBytes`` so callers can derive occupancy as `total − free` when they want it.
        var vramTotalBytes: Int64?

        /// One-line summary for the Settings "Test Connection" button.
        var summary: String {
            let gpu = gpuNames.isEmpty ? "no GPU reported" : gpuNames.joined(separator: ", ")
            let vram = vramTotalGb.map { String(format: " · %.1f GB VRAM", $0) } ?? ""
            return "ComfyUI \(serverVersion ?? "unknown") on \(os ?? "?") — \(gpu)\(vram)"
        }
    }

    /// Hits `/system_stats` — the cheap liveness + "did we reach the right box" check.
    func systemStats() async throws -> SystemStats {
        let data = try await getData("/system_stats")
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ComfyUIError.decodeFailed("unexpected /system_stats shape")
        }
        var stats = SystemStats()
        if let system = json["system"] as? [String: Any] {
            stats.serverVersion = system["comfyui_version"] as? String
            stats.os = system["os"] as? String
        }
        if let devices = json["devices"] as? [[String: Any]] {
            for d in devices {
                if let name = d["name"] as? String, !name.isEmpty {
                    stats.gpuNames.append(name)
                }
                func asBytes(_ key: String) -> Int64? {
                    if let v = d[key] as? Int64 {
                        return v
                    }
                    if let v = d[key] as? Double {
                        return Int64(v)
                    }
                    if let v = d[key] as? Int {
                        return Int64(v)
                    }
                    return nil
                }
                // Read both the driver-level and torch-tracked figures. Driver-level (`vram_free` /
                // `vram_total`) is what actually tracks occupancy because ComfyUI loads weights through the
                // CUDA driver, not torch's allocator; we keep `torch_vram_free` out of the residency math on
                // purpose for exactly that reason (it sits near-zero even with a 30 GB model resident).
                if let free = asBytes("vram_free") {
                    stats.vramFreeBytes = free
                } else if let torchFree = asBytes("torch_vram_free"), stats.vramFreeBytes == nil {
                    // Fallback for builds that only expose the torch figure.
                    stats.vramFreeBytes = torchFree
                }
                if let total = asBytes("vram_total") {
                    stats.vramTotalBytes = total
                    stats.vramTotalGb = Double(total) / 1_073_741_824
                } else if let vram = d["vram_total"] as? Double {
                    // Older/alternate shape where the value is already GB.
                    stats.vramTotalBytes = Int64(vram * 1_073_741_824)
                    stats.vramTotalGb = vram
                }
            }
        }
        return stats
    }

    /// Pulls available UNet / CLIP / VAE / sampler lists from `/object_info`. Each loader list is read from the
    /// node that actually enumerates it on this server (verified live), not `CheckpointLoaderSimple`, which only
    /// holds monolithic checkpoints and had none of Krea 2's separate model files. LoRAs are fetched separately via
    /// ``fetchLoras()`` from `/models/loras` — the dedicated endpoint that returns *full relative* filenames
    /// (e.g. `krea2/foo.safetensors`), including any subfolder prefix, exactly as the server's node dropdown shows them.
    func discoverModels() async throws -> ComfyModelInfo {
        let data = try await getData("/object_info")
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ComfyUIError.decodeFailed("unexpected /object_info shape")
        }
        var info = ComfyModelInfo()

        func optionsFor(_ cls: String, _ key: String) -> [String]? {
            guard let node = json[cls] as? [String: Any],
                  let input = node["input"] as? [String: Any],
                  let required = input["required"] as? [String: Any],
                  let field = required[key] else { return nil }
            // ComfyUI encodes model lists as `[ ["file1", "file2", …], {optional metadata} ]` — a two-element
            // array whose first element is the string list. Handle both that and a bare `{"options": [...]}` shape.
            if let arr = field as? [Any], let opts = arr.first as? [String] {
                return opts
            }
            if let dict = field as? [String: Any], let opts = dict["options"] as? [String] {
                return opts
            }
            return nil
        }

        info.unets = optionsFor("UNETLoader", "unet_name") ?? []
        info.clips = optionsFor("CLIPLoader", "clip_name") ?? []
        info.vaes = optionsFor("VAELoader", "vae_name") ?? []
        info.loras = try await fetchLoras()
        info.samplers = optionsFor("KSampler", "sampler_name") ?? ["euler"]
        info.schedulers = optionsFor("KSampler", "scheduler") ?? ["normal"]
        return info
    }

    /// Fetches the full list of LoRA filenames from `/models/loras`. Returns the names verbatim, which are relative
    /// paths with a subfolder prefix when present (e.g. `krea2/Krea2-realism-V2.safetensors`) and bare basenames for
    /// top-level files. These strings are exactly what a `LoraLoader.lora_name` node accepts, so they double as both the
    /// cataloging identity key and the workflow submission value — no transformation needed either way. Verified live:
    /// this endpoint is path-preserving on ComfyUI 0.33 (unlike `/object_info`, which omits subfolder structure in some builds).
    func fetchLoras() async throws -> [String] {
        let data = try await getData("/models/loras")
        guard let names = (try? JSONSerialization.jsonObject(with: data)) as? [String] else {
            throw ComfyUIError.decodeFailed("unexpected /models/loras shape — expected a JSON array of filenames")
        }
        return names.filter { !$0.isEmpty }
    }
}
