import Foundation

// MARK: - Job params

/// The per-job values injected into a template's mapped inputs. Field names map 1:1 to the param-map keys
/// (snake_case): `prompt`, `negative_prompt`, `seed`, `width`, `height`, `steps`, `cfg`, `sampler`, `scheduler`,
/// `denoise`, `unet_name`, `clip_name`, `vae_name`, `source_image`, plus the LoRA-slot keys.
struct ComfyJobParams: Equatable, Sendable {
    /// One LoRA in the job's stack.
    struct LoraEntry: Equatable, Sendable {
        var name: String
        var strengthModel: Double
        var strengthClip: Double
    }

    var prompt: String
    var negativePrompt: String?
    var seed: Int
    var width: Int
    var height: Int
    var steps: Int
    var cfg: Double
    var sampler: String
    var scheduler: String
    var denoise: Double?
    var unetName: String?
    var clipName: String?
    var vaeName: String?
    var sourceImageName: String?
    var loras: [LoraEntry]
}

// MARK: - LoRA mechanism

/// How unused LoRA slots are neutralized. Fixed by the dry-run harness's `--lora-test` (Task 1) against the live
/// server: whichever variant produces a byte-identical output to the no-LoRA baseline is the clean no-op.
enum LoraMechanism: Equatable, Sendable {
    /// Unused slot: empty `lora_name` (a no-op on this server).
    case emptyNoOp
    /// Unused slot: a valid name + zero strengths (a no-op on this server).
    case strengthZero
    /// Unused slot: switched off (bypassed).
    case switchBased
}

/// The number of LoRA slots in a template's param map. The app caps its LoRA stack at this count.
let kComfyLoraSlotCount = 10

// MARK: - Render

/// Renders a `/prompt` graph from a template + param map + job params.
///
/// Fills each mapped scalar input from `params` (throwing on a stale param map — a target whose node or input is
/// missing), wires the 10-slot LoRA chain (used slots get name + strengths, unused slots are neutralized per
/// `loraMechanism`), and sets the i2i source-image filename. Throws on a param-map mismatch or more than 10 LoRAs.
func renderGraph(
    template: ComfyTemplate,
    paramMap: ComfyParamMap,
    params: ComfyJobParams,
    loraMechanism: LoraMechanism
) throws -> [String: ComfyNode] {
    var graph = template.nodes

    // 1. Fill the mapped scalar inputs from params. LoRA-slot params (keyed `lora*`) are handled by the chain below.
    for (param, target) in paramMap.params where !param.hasPrefix("lora") {
        guard let value = scalarValue(for: param, params: params) else { continue }
        try setNodeInput(graph: &graph, node: target.node, input: target.input, value: value)
    }

    // 2. Wire the 10-slot LoRA chain.
    try wireLoraChain(graph: &graph, paramMap: paramMap, params: params, mechanism: loraMechanism)

    return graph
}

/// The scalar value for a param name, or nil if the param has no value to fill (e.g. an absent negative prompt).
private func scalarValue(for param: String, params: ComfyJobParams) -> ComfyInputValue? {
    switch param {
    case "prompt": return .scalar(.string(params.prompt))
    case "negative_prompt":
        guard let neg = params.negativePrompt, !neg.isEmpty else { return nil }
        return .scalar(.string(neg))
    case "seed": return .scalar(.int(params.seed))
    case "width": return .scalar(.int(params.width))
    case "height": return .scalar(.int(params.height))
    case "steps": return .scalar(.int(params.steps))
    case "cfg": return .scalar(.double(params.cfg))
    case "sampler": return .scalar(.string(params.sampler))
    case "scheduler": return .scalar(.string(params.scheduler))
    case "denoise":
        guard let d = params.denoise else { return nil }
        return .scalar(.double(d))
    case "unet_name":
        guard let n = params.unetName else { return nil }
        return .scalar(.string(n))
    case "clip_name":
        guard let n = params.clipName else { return nil }
        return .scalar(.string(n))
    case "vae_name":
        guard let n = params.vaeName else { return nil }
        return .scalar(.string(n))
    case "source_image":
        guard let n = params.sourceImageName else { return nil }
        return .scalar(.string(n))
    default: return nil
    }
}

/// Sets a node's input, throwing if the node or input is missing (a stale param map — Review Focus #1).
private func setNodeInput(graph: inout [String: ComfyNode], node: String, input: String, value: ComfyInputValue) throws {
    guard var n = graph[node] else { throw ComfyTemplateError.missingNode(node) }
    guard n.inputs[input] != nil else { throw ComfyTemplateError.missingInput(node: node, input: input) }
    n.inputs[input] = value
    graph[node] = n
}

/// Wires the 10-slot LoRA chain: used slots get name + strengths (+ switch on), unused slots are neutralized per the
/// mechanism. Throws if there are more than 10 LoRAs (Review Focus #2).
private func wireLoraChain(
    graph: inout [String: ComfyNode],
    paramMap: ComfyParamMap,
    params: ComfyJobParams,
    mechanism: LoraMechanism
) throws {
    if params.loras.count > kComfyLoraSlotCount {
        throw ComfyTemplateError.tooManyLoras(params.loras.count)
    }

    // A placeholder name for `strengthZero` neutralization: the first used LoRA's name (a name that exists on the
    // server), or empty if no LoRAs are used.
    let placeholderName = params.loras.first?.name ?? ""

    for slot in 1 ... kComfyLoraSlotCount {
        if slot <= params.loras.count {
            let lora = params.loras[slot - 1]
            try setLoraSlot(
                graph: &graph,
                paramMap: paramMap,
                slot: slot,
                values: .init(name: lora.name, sm: lora.strengthModel, sc: lora.strengthClip, on: true)
            )
        } else {
            switch mechanism {
            case .emptyNoOp:
                try setLoraSlot(graph: &graph, paramMap: paramMap, slot: slot, values: .init(name: "", sm: nil, sc: nil, on: true))
            case .strengthZero:
                try setLoraSlot(graph: &graph, paramMap: paramMap, slot: slot, values: .init(name: placeholderName, sm: 0, sc: 0, on: true))
            case .switchBased:
                try setLoraSlot(graph: &graph, paramMap: paramMap, slot: slot, values: .init(name: nil, sm: nil, sc: nil, on: false))
            }
        }
    }
}

/// The values for one LoRA slot. `nil` values leave the input untouched.
private struct LoraSlotValues {
    var name: String?
    var sm: Double?
    var sc: Double?
    var on: Bool?
}

/// Sets a LoRA slot's inputs (only the keys present in the param map). `nil` values leave the input untouched.
private func setLoraSlot(graph: inout [String: ComfyNode], paramMap: ComfyParamMap, slot: Int, values: LoraSlotValues) throws {
    try setSlotInput(graph: &graph, paramMap: paramMap, key: "lora\(slot)_name", value: values.name.map { .scalar(.string($0)) })
    try setSlotInput(graph: &graph, paramMap: paramMap, key: "lora\(slot)_sm", value: values.sm.map { .scalar(.double($0)) })
    try setSlotInput(graph: &graph, paramMap: paramMap, key: "lora\(slot)_sc", value: values.sc.map { .scalar(.double($0)) })
    try setSlotInput(graph: &graph, paramMap: paramMap, key: "lora\(slot)_on", value: values.on.map { .scalar(.bool($0)) })
}

/// Sets one LoRA-slot input if the key is in the param map + the value is non-nil.
private func setSlotInput(graph: inout [String: ComfyNode], paramMap: ComfyParamMap, key: String, value: ComfyInputValue?) throws {
    guard let value, let target = paramMap.params[key] else { return }
    try setNodeInput(graph: &graph, node: target.node, input: target.input, value: value)
}
