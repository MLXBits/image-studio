import Foundation

// MARK: - i2e conditioning-slot excision

/// Excise unused conditioning slots from a FLUX.2 i2e graph.
///
/// Each i2e slot is a chain `LoadImage -> ImageScaleToTotalPixels -> VAEEncode -> ReferenceLatent(s)`.
/// The ReferenceLatent nodes form two parallel chains (the positive + negative conditioning streams), each
/// feeding the CFGGuider. When the user supplies fewer than `slotOrder.count` reference images, the unused
/// slots (the tail of `slotOrder`) are removed and the kept chains are rewired so the last kept
/// ReferenceLatent feeds the CFGGuider directly.
///
/// The excision set is derived from `slotOrder` (the param-map image-assignment order), which equals the
/// chain order — the param-map slots are kept aligned with the ReferenceLatent chain (pinned by
/// `i2eReferenceSlotOrderMatchesCFGGuiderChain`), so the excised slots are a contiguous tail. The
/// ReferenceLatent chains are still traced from the graph and rewired, which keeps the excision robust if
/// the two orders ever drift apart again.
///
/// - Parameters:
///   - graph: the wire-form graph to modify in place.
///   - keepCount: the number of conditioning slots to keep (1...slotOrder.count).
///   - slotOrder: the LoadImage node IDs in the order the app assigns reference images to them
///     (``ComfyParamMap/referenceSlotOrder``). Slots `slotOrder[keepCount...]` are excised.
/// - Throws: ``ComfyTemplateError`` if the chain structure is unexpected (no CFGGuider, a slot's chain is
///   broken, a slot to excise has no ReferenceLatent, or a dangling ref remains after excision).
func exciseUnusedConditioningSlots(
    _ graph: inout [String: Any],
    keepCount: Int,
    slotOrder: [String]
) throws {
    guard (1 ... slotOrder.count).contains(keepCount) else {
        throw ComfyTemplateError.missingNode("keepCount")
    }
    // Keeping every slot is a no-op: leave the graph byte-identical.
    if keepCount == slotOrder.count {
        return
    }

    let cfgID = try exciseFindCFGGuider(graph)
    let rlSlot = try exciseMapRLToSlot(graph)
    let posChain = exciseTraceChain(graph, from: exciseInputs(graph, cfgID)["positive"], rlSlot: rlSlot)
    let negChain = exciseTraceChain(graph, from: exciseInputs(graph, cfgID)["negative"], rlSlot: rlSlot)
    guard !posChain.isEmpty, posChain.count == negChain.count else {
        throw ComfyTemplateError.missingNode("conditioning chain")
    }

    let excisedSlots = Set(slotOrder[keepCount...])
    guard excisedSlots.isSubset(of: Set(rlSlot.values)) else {
        throw ComfyTemplateError.missingNode("slot \(excisedSlots.sorted().joined(separator: ","))")
    }

    let lastPos = try exciseRewireChain(&graph, chain: posChain, rlSlot: rlSlot, excised: excisedSlots)
    let lastNeg = try exciseRewireChain(&graph, chain: negChain, rlSlot: rlSlot, excised: excisedSlots)
    exciseSetRef(&graph, node: cfgID, input: "positive", to: lastPos)
    exciseSetRef(&graph, node: cfgID, input: "negative", to: lastNeg)

    exciseRemoveSlots(&graph, loadIDs: excisedSlots, rlSlot: rlSlot)
    try exciseVerifyNoDanglingRefs(graph)
}

// MARK: excision helpers (wire-form)

private func exciseFindCFGGuider(_ graph: [String: Any]) throws -> String {
    guard let cfgID = exciseNodeIDs(ofClass: "CFGGuider", in: graph).first else {
        throw ComfyTemplateError.missingNode("CFGGuider")
    }
    return cfgID
}

/// Maps each ReferenceLatent node ID to its slot (LoadImage node ID) by walking
/// `latent -> VAEEncode -> ImageScale -> LoadImage`.
private func exciseMapRLToSlot(_ graph: [String: Any]) throws -> [String: String] {
    var rlSlot: [String: String] = [:]
    for rlID in exciseNodeIDs(ofClass: "ReferenceLatent", in: graph) {
        rlSlot[rlID] = try exciseSlotForRL(graph, rlID)
    }
    return rlSlot
}

private func exciseSlotForRL(_ graph: [String: Any], _ rlID: String) throws -> String {
    let ins = exciseInputs(graph, rlID)
    guard let vaeID = exciseRefTarget(ins["latent"]),
          let scaleID = exciseRefTarget(exciseInputs(graph, vaeID)["pixels"]),
          let loadID = exciseRefTarget(exciseInputs(graph, scaleID)["image"])
    else {
        throw ComfyTemplateError.missingNode("slot chain for \(rlID)")
    }
    return loadID
}

/// Traces a ReferenceLatent chain from a CFGGuider input backward to the chain head, then returns it in
/// head-to-tail order (the order the conditioning flows).
private func exciseTraceChain(_ graph: [String: Any], from start: Any?, rlSlot: [String: String]) -> [String] {
    var chain: [String] = []
    var cur: Any? = start
    while let target = exciseRefTarget(cur), rlSlot[target] != nil {
        chain.append(target)
        cur = exciseInputs(graph, target)["conditioning"]
    }
    return chain.reversed()
}

/// Rewires the kept ReferenceLatent chain in place: each kept RL's `conditioning` points to the previous
/// kept RL. Returns the last kept RL so the caller can point the CFGGuider at it.
private func exciseRewireChain(
    _ graph: inout [String: Any],
    chain: [String],
    rlSlot: [String: String],
    excised: Set<String>
) throws -> String {
    let kept = chain.filter { rlSlot[$0].map { !excised.contains($0) } ?? false }
    guard let last = kept.last else {
        throw ComfyTemplateError.missingNode("no kept slot")
    }
    var prev: String?
    for rlID in kept {
        if let p = prev {
            exciseSetRef(&graph, node: rlID, input: "conditioning", to: p)
        }
        prev = rlID
    }
    return last
}

/// Removes each excised slot's nodes: its LoadImage + the ImageScale it feeds + the VAEEncode that feeds +
/// the ReferenceLatent(s) it feeds.
private func exciseRemoveSlots(_ graph: inout [String: Any], loadIDs: Set<String>, rlSlot: [String: String]) {
    var toRemove: Set<String> = []
    for loadID in loadIDs {
        toRemove.insert(loadID)
        let scaleIDs = exciseNodeIDs(ofClass: "ImageScaleToTotalPixels", in: graph).filter {
            exciseRefTarget(exciseInputs(graph, $0)["image"]) == loadID
        }
        toRemove.formUnion(scaleIDs)
        let vaeIDs = exciseNodeIDs(ofClass: "VAEEncode", in: graph).filter {
            guard let px = exciseRefTarget(exciseInputs(graph, $0)["pixels"]) else { return false }
            return scaleIDs.contains(px)
        }
        toRemove.formUnion(vaeIDs)
        toRemove.formUnion(rlSlot.filter { $0.value == loadID }.map(\.key))
    }
    for id in toRemove {
        graph[id] = nil
    }
}

/// Fails loudly if any `[nodeID, outputIndex]` ref in the graph points to a node that no longer exists.
private func exciseVerifyNoDanglingRefs(_ graph: [String: Any]) throws {
    for (id, v) in graph {
        guard let node = v as? [String: Any] else { continue }
        for (name, value) in node["inputs"] as? [String: Any] ?? [:] {
            if let target = exciseRefTarget(value), graph[target] == nil {
                throw ComfyTemplateError.missingNode("dangling ref \(id).\(name) -> \(target)")
            }
        }
    }
}

private func exciseNodeIDs(ofClass cls: String, in graph: [String: Any]) -> [String] {
    graph.compactMap { id, v in
        ((v as? [String: Any])?["class_type"] as? String) == cls ? id : nil
    }
}

private func exciseInputs(_ graph: [String: Any], _ nodeID: String) -> [String: Any] {
    (graph[nodeID] as? [String: Any])?["inputs"] as? [String: Any] ?? [:]
}

/// The target node ID of a `[nodeID, outputIndex]` ref, or nil if the value is not a well-formed ref.
private func exciseRefTarget(_ value: Any?) -> String? {
    guard let arr = value as? [Any], arr.count == 2, let s = arr[0] as? String else {
        return nil
    }
    return s
}

private func exciseSetRef(_ graph: inout [String: Any], node: String, input: String, to target: String) {
    guard var nodeDict = graph[node] as? [String: Any],
          var ins = nodeDict["inputs"] as? [String: Any]
    else {
        return
    }
    ins[input] = [target, 0]
    nodeDict["inputs"] = ins
    graph[node] = nodeDict
}
