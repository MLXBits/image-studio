import Foundation

// MARK: - Errors

/// Failures loading or rendering a bundled ComfyUI template.
nonisolated enum ComfyTemplateError: Error, Equatable {
    /// The template or param-map file is missing from the bundle.
    case notFound(String)
    /// A param-map target points at a node that isn't in the template (a stale param map).
    case missingNode(String)
    /// A param-map target points at an input that isn't on the node (a stale param map).
    case missingInput(node: String, input: String)
}

// MARK: - LoRA kind

/// The LoRA loader mechanism a template family needs.
nonisolated enum ComfyLoraKind {
    /// `LoraLoaderModelOnly` — model-only, no clip (Krea 2).
    case modelOnly
    /// `LoraLoader` — model + clip streams (FLUX.2).
    case full
}

// MARK: - JSON value helper

/// A flexible JSON value, used to distinguish a `[nodeID, outputIndex]` ref array from a scalar on decode.
/// Whole-number JSON numbers decode as `.int` so `steps: 20` stays an Int on the wire; `cfg: 7.0` decodes as
/// `.double` only when it is not a whole number.
nonisolated enum ComfyJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([Self])
    case object([String: Self])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let d = try? c.decode(Double.self) {
            // JSON numbers are Doubles in Foundation; whole numbers become Ints (Int 2^53 bound).
            if d == d.rounded() && abs(d) < 9_007_199_254_740_992 {
                self = .int(Int(d))
            } else {
                self = .double(d)
            }
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let a = try? c.decode([Self].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: Self].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(v): try c.encode(v)
        case let .int(v): try c.encode(v)
        case let .double(v): try c.encode(v)
        case let .string(v): try c.encode(v)
        case let .array(v): try c.encode(v)
        case let .object(v): try c.encode(v)
        }
    }
}

// MARK: - Scalar + input value

/// A scalar input value (a JSON number, string, or bool).
nonisolated enum ComfyScalar: Codable, Equatable, Sendable {
    case int(Int)
    case double(Double)
    case string(String)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        switch try ComfyJSONValue(from: decoder) {
        case let .int(v): self = .int(v)
        case let .double(v): self = .double(v)
        case let .string(v): self = .string(v)
        case let .bool(v): self = .bool(v)
        default:
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "not a scalar"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .int(v): try c.encode(v)
        case let .double(v): try c.encode(v)
        case let .string(v): try c.encode(v)
        case let .bool(v): try c.encode(v)
        }
    }
}

/// A node input: either a scalar value or a reference to another node's output (`[nodeID, outputIndex]`).
nonisolated enum ComfyInputValue: Codable, Equatable, Sendable {
    case scalar(ComfyScalar)
    case ref(nodeID: String, outputIndex: Int)

    init(from decoder: Decoder) throws {
        switch try ComfyJSONValue(from: decoder) {
        case let .array(arr):
            guard arr.count == 2, case let .string(nodeID) = arr[0], case let .int(idx) = arr[1] else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "not a [nodeID, outputIndex] ref"
                ))
            }
            self = .ref(nodeID: nodeID, outputIndex: idx)
        case let .int(v): self = .scalar(.int(v))
        case let .double(v): self = .scalar(.double(v))
        case let .string(v): self = .scalar(.string(v))
        case let .bool(v): self = .scalar(.bool(v))
        default:
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "unsupported input value"
            ))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .scalar(s): try c.encode(s)
        case let .ref(nodeID, idx): try c.encode(ComfyJSONValue.array([.string(nodeID), .int(idx)]))
        }
    }
}

// MARK: - Node + template

/// One node in the `/prompt` wire form: `{class_type, inputs}` (`_meta` and any other keys are ignored on decode).
nonisolated struct ComfyNode: Codable, Equatable, Sendable {
    private enum Key: CodingKey {
        case classType, inputs

        var stringValue: String {
            switch self {
            case .classType: "class_type"
            case .inputs: "inputs"
            }
        }

        init?(stringValue: String) {
            switch stringValue {
            case "class_type": self = .classType
            case "inputs": self = .inputs
            default: return nil
            }
        }

        init?(intValue _: Int) {
            nil
        }
    }

    let classType: String
    var inputs: [String: ComfyInputValue]

    init(classType: String, inputs: [String: ComfyInputValue]) {
        self.classType = classType
        self.inputs = inputs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        self.classType = try c.decode(String.self, forKey: .classType)
        self.inputs = try c.decode([String: ComfyInputValue].self, forKey: .inputs)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(classType, forKey: .classType)
        try c.encode(inputs, forKey: .inputs)
    }
}

/// A bundled ComfyUI template: the raw `/prompt` graph `{nodeID: {class_type, inputs}}`, decoded directly into
/// ``nodes`` (no wrapper key, so the bundled file is byte-identical to the user's ComfyUI API export).
nonisolated struct ComfyTemplate: Decodable, Equatable, Sendable {
    /// Loads the bundled template for a family/flow key (e.g. `krea2/t2i`) from `comfy_templates/<key>.json`.
    static func load(familyFlowKey key: String) throws -> Self {
        let (resource, subdirectory) = try comfyBundlePath(key: key, suffix: "")
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json", subdirectory: subdirectory) else {
            throw ComfyTemplateError.notFound("\(key).json")
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    let nodes: [String: ComfyNode]

    init(nodes: [String: ComfyNode]) {
        self.nodes = nodes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var nodes: [String: ComfyNode] = [:]
        for key in c.allKeys {
            nodes[key.stringValue] = try c.decode(ComfyNode.self, forKey: key)
        }
        self.nodes = nodes
    }
}

// MARK: - Param map

/// One param target: the node + input a param fills.
nonisolated struct ParamTarget: Codable, Equatable, Sendable {
    let node: String
    let input: String
}

/// The param-map sidecar: `{param: {node, input}}`, decoded directly into ``params``.
nonisolated struct ComfyParamMap: Decodable, Equatable, Sendable {
    /// Loads the bundled param map for a family/flow key from `comfy_templates/<key>.parammap.json`.
    static func load(familyFlowKey key: String) throws -> Self {
        let (resource, subdirectory) = try comfyBundlePath(key: key, suffix: ".parammap")
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json", subdirectory: subdirectory) else {
            throw ComfyTemplateError.notFound("\(key).parammap.json")
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    let params: [String: ParamTarget]

    init(params: [String: ParamTarget]) {
        self.params = params
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var params: [String: ParamTarget] = [:]
        for key in c.allKeys {
            params[key.stringValue] = try c.decode(ParamTarget.self, forKey: key)
        }
        self.params = params
    }
}

nonisolated extension ComfyParamMap {
    /// The i2e reference-image LoadImage node IDs in the order the app assigns reference images to them
    /// (`source_image`, `source_image_1`, `source_image_2`, ...). This is the `slotOrder` for
    /// ``exciseUnusedConditioningSlots(_:keepCount:slotOrder:)``. Empty for t2i (no reference slots).
    var referenceSlotOrder: [String] {
        let keys = params.keys.filter { $0 == "source_image" || $0.hasPrefix("source_image_") }
        func index(_ key: String) -> Int {
            key == "source_image" ? 0 : (Int(key.dropFirst("source_image_".count)) ?? 0)
        }
        return keys.sorted { index($0) < index($1) }.compactMap { params[$0]?.node }
    }
}

// MARK: - Helpers

/// Splits a family/flow key (e.g. `krea2/t2i`) into the bundle resource name + subdirectory.
nonisolated private func comfyBundlePath(key: String, suffix: String) throws -> (resource: String, subdirectory: String) {
    let parts = key.split(separator: "/").map(String.init)
    guard let resource = parts.last else { throw ComfyTemplateError.notFound(key) }
    let sub = "comfy_templates" + parts.dropLast().map { "/" + $0 }.joined()
    return (resource + suffix, sub)
}

/// A generic coding key, for decoding a top-level dict into a struct property.
nonisolated struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init(stringValue: String) {
        self.stringValue = stringValue; self.intValue = nil
    }

    init(intValue: Int) {
        self.stringValue = "\(intValue)"; self.intValue = intValue
    }
}

// MARK: - Rendering (param injection + dynamic LoRA insertion)

nonisolated extension ComfyScalar {
    /// The wire-form value (a JSON number, string, or bool).
    var wireValue: Any {
        switch self {
        case let .int(v): v
        case let .double(v): v
        case let .string(v): v
        case let .bool(v): v
        }
    }
}

nonisolated extension ComfyInputValue {
    /// The wire-form value: a scalar, or a `[nodeID, outputIndex]` ref array.
    var wireValue: Any {
        switch self {
        case let .scalar(s): s.wireValue
        case let .ref(nodeID, idx): [nodeID, idx]
        }
    }
}

nonisolated extension ComfyTemplate {
    /// Render a runnable `/prompt` graph: start from the base template, inject `params` via the
    /// param map, then dynamically insert `loras` chained between the UNETLoader and its model
    /// consumer. Swift counterpart of `scripts/comfy_dry_run.py`'s `inject()` + `insert_loras()`.
    ///
    /// `params` is keyed by param-map name (`prompt`, `seed`, `denoise`, `source_image`, …); a param
    /// absent from `params` is left at the template's baked value. Throws if a param-map target is
    /// stale (missing node/input).
    ///
    /// `loraKind` selects the loader mechanism: ``ComfyLoraKind/modelOnly`` (default, Krea 2) inserts
    /// `LoraLoaderModelOnly` nodes feeding the `KSampler.model`; ``ComfyLoraKind/full`` (FLUX.2) inserts
    /// `LoraLoader` nodes with a parallel clip chain, rewiring the model consumer by reference (covers
    /// `CFGGuider.model` — no `KSampler` needed) and every `CLIPTextEncode.clip` to the tail clip.
    func render(
        map: ComfyParamMap,
        params: [String: Any],
        loras: [ComfyLora],
        loraKind: ComfyLoraKind = .modelOnly
    ) throws -> [String: Any] {
        // 1. Base graph in wire form: {nodeID: {class_type, inputs}}.
        var graph: [String: [String: Any]] = [:]
        for (id, node) in nodes {
            var inputs: [String: Any] = [:]
            for (name, value) in node.inputs {
                inputs[name] = value.wireValue
            }
            graph[id] = ["class_type": node.classType, "inputs": inputs]
        }
        // 2. Inject params (param-map name -> node.input).
        for (name, value) in params {
            guard let target = map.params[name] else { continue } // unknown param name: leave baked
            guard var node = graph[target.node] else { throw ComfyTemplateError.missingNode(target.node) }
            guard var inputs = node["inputs"] as? [String: Any] else {
                throw ComfyTemplateError.missingInput(node: target.node, input: target.input)
            }
            // Fail loudly on a stale param map: the input must already exist on the node (never silently add it).
            guard inputs[target.input] != nil else {
                throw ComfyTemplateError.missingInput(node: target.node, input: target.input)
            }
            inputs[target.input] = value
            node["inputs"] = inputs
            graph[target.node] = node
        }
        // 3. Dynamic LoRA insertion (no fixed slots; only the user's real LoRAs).
        try insertLoras(&graph, loras, kind: loraKind)
        // 4. Upcast to the /prompt wire form.
        var wire: [String: Any] = [:]
        for (id, node) in graph {
            wire[id] = node
        }
        return wire
    }

    /// Dynamically insert LoRA loader nodes chained after the UNETLoader, in order, and rewire the
    /// model consumer to the chain tail. With no LoRAs this is a no-op (the UNET feeds its consumers
    /// directly). Node IDs match `scripts/comfy_dry_run.py`'s `insert_loras` (the reference).
    ///
    /// ``ComfyLoraKind/modelOnly`` (Krea 2): `LoraLoaderModelOnly` nodes feeding the `KSampler.model`.
    /// ``ComfyLoraKind/full`` (FLUX.2): `LoraLoader` nodes with a parallel clip chain anchored on the
    /// `CLIPLoader`; the model consumer is found by reference-rewrite (every `[unetID, 0]` ref — covers
    /// `KSampler.model`, `CFGGuider.model`, any consumer count), and every `[clipID, 0]` ref is rewired
    /// to the tail clip (feeds both positive + negative `CLIPTextEncode`).
    private func insertLoras(_ graph: inout [String: [String: Any]], _ loras: [ComfyLora], kind: ComfyLoraKind = .modelOnly) throws {
        if loras.isEmpty {
            return
        }
        switch kind {
        case .modelOnly:
            try insertModelOnlyLoras(&graph, loras)
        case .full:
            try insertFullLoras(&graph, loras)
        }
    }

    /// The Krea 2 path: `LoraLoaderModelOnly` nodes chained between the UNETLoader and the
    /// KSampler.model.
    private func insertModelOnlyLoras(_ graph: inout [String: [String: Any]], _ loras: [ComfyLora]) throws {
        guard let unet = graph.first(where: { $0.value["class_type"] as? String == "UNETLoader" })?.key,
              let ks = graph.first(where: { $0.value["class_type"] as? String == "KSampler" })?.key,
              var ksNode = graph[ks]
        else {
            // No UNETLoader/KSampler to chain between: a silent wrong graph would run the job without
            // the user's LoRAs and show no error — fail loudly.
            throw ComfyTemplateError.missingNode("UNETLoader/KSampler")
        }
        var ksInputs = ksNode["inputs"] as? [String: Any] ?? [:]
        var prev: Any = [unet, 0]
        for (i, lora) in loras.enumerated() {
            let id = "lora_ins_\(i)"
            graph[id] = [
                "class_type": "LoraLoaderModelOnly",
                "inputs": ["model": prev, "lora_name": lora.name, "strength_model": lora.strength],
            ]
            prev = [id, 0]
        }
        ksInputs["model"] = prev
        ksNode["inputs"] = ksInputs
        graph[ks] = ksNode
    }

    /// The FLUX.2 path: `LoraLoader` nodes with both model + clip streams, chained after the
    /// UNETLoader and the CLIPLoader anchor, then every model/clip consumer rewired to the chain tails.
    private func insertFullLoras(_ graph: inout [String: [String: Any]], _ loras: [ComfyLora]) throws {
        guard let unet = graph.first(where: { $0.value["class_type"] as? String == "UNETLoader" })?.key else {
            throw ComfyTemplateError.missingNode("UNETLoader")
        }
        guard let clip = clipAnchor(graph) else {
            throw ComfyTemplateError.missingNode("CLIPLoader")
        }
        // Each stream is (nodeID, outputSlot): the UNETLoader/CLIPLoader outputs are slot 0, but a
        // LoraLoader's clip is slot 1 (its slot 0 is the model).
        var prevModel: (id: String, slot: Int) = (unet, 0)
        var prevClip: (id: String, slot: Int) = (clip, 0)
        var inserted: [String] = []
        for (i, lora) in loras.enumerated() {
            let id = "lora_ins_\(i)"
            graph[id] = [
                "class_type": "LoraLoader",
                "inputs": [
                    "model": [prevModel.id, prevModel.slot],
                    "clip": [prevClip.id, prevClip.slot],
                    "lora_name": lora.name,
                    "strength_model": lora.strength,
                    "strength_clip": lora.strength, // the app uses a single LoRA strength for both
                ],
            ]
            inserted.append(id)
            prevModel = (id, 0)
            prevClip = (id, 1)
        }
        rewireConsumers(&graph, skipping: Set(inserted), tails: [unet: prevModel, clip: prevClip])
    }

    /// The `CLIPLoader` whose output feeds a `CLIPTextEncode` node's `clip` input (the anchor for the
    /// `.full` clip chain), or nil when no such anchor exists.
    private func clipAnchor(_ graph: [String: [String: Any]]) -> String? {
        for (_, node) in graph where (node["class_type"] as? String) == "CLIPTextEncode" {
            guard let inputs = node["inputs"] as? [String: Any],
                  let clip = inputs["clip"] as? [Any], clip.count == 2, clip[1] as? Int == 0,
                  let src = clip[0] as? String,
                  (graph[src]?["class_type"] as? String) == "CLIPLoader"
            else { continue }
            return src
        }
        return nil
    }

    /// Rewire every `[sourceID, 0]` ref in `tails` to its chain tail (the UNETLoader ref → model tail,
    /// the CLIPLoader ref → tail clip). Skip the inserted LoRA nodes: the first of them still
    /// references the UNETLoader/CLIPLoader by design and must not be rewritten into a self-cycle.
    private func rewireConsumers(
        _ graph: inout [String: [String: Any]],
        skipping inserted: Set<String>,
        tails: [String: (id: String, slot: Int)]
    ) {
        for (id, var node) in graph where !inserted.contains(id) {
            guard var inputs = node["inputs"] as? [String: Any] else { continue }
            var changed = false
            for (key, value) in inputs {
                guard let ref = value as? [Any], ref.count == 2, ref[1] as? Int == 0,
                      let src = ref[0] as? String, let tail = tails[src]
                else { continue }
                inputs[key] = [tail.id, tail.slot]
                changed = true
            }
            if changed {
                node["inputs"] = inputs
                graph[id] = node
            }
        }
    }
}
