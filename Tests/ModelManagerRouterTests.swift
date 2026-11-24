@testable import MLXBits_Image_Studio
import Testing

struct ModelManagerRouterTests {
    @Test func aCustomModelShowsTheCustomEntry() {
        #expect(ModelManagerRouter.item(for: .custom) == .custom)
        #expect(ModelManagerRouter.item(for: .krea2) == .model(.krea2))
    }

    @Test func aUseRequestIsIgnoredWhileAJobRuns() {
        let request = ModelManagerRouter.UseRequest(model: .krea2, quantize: 4)
        #expect(ModelManagerRouter.outcome(of: request, currentModel: .flux3Klein, busy: true) == .ignore)
        #expect(ModelManagerRouter.outcome(of: request, currentModel: .krea2, busy: true) == .ignore)
    }

    @Test func aUseRequestForThePickedModelOnlySetsThePrecision() {
        let request = ModelManagerRouter.UseRequest(model: .krea2, quantize: 8)
        #expect(ModelManagerRouter.outcome(of: request, currentModel: .krea2, busy: false) == .setQuantize)
    }

    @Test func aUseRequestForAnotherModelSwitchesThePicker() {
        let request = ModelManagerRouter.UseRequest(model: .krea2, quantize: 4)
        #expect(ModelManagerRouter.outcome(of: request, currentModel: .flux3Klein, busy: false) == .switchModel)
        #expect(ModelManagerRouter.outcome(of: request, currentModel: .custom, busy: false) == .switchModel)
    }

    @Test func aCustomUseRequestSwitchesToCustomOrUpdatesIt() {
        let request = ModelManagerRouter.UseRequest(custom: .init(repo: "org/tune", loadsAs: .krea2))
        #expect(ModelManagerRouter.outcome(of: request, currentModel: .krea2, busy: false) == .switchModel)
        #expect(ModelManagerRouter.outcome(of: request, currentModel: .custom, busy: false) == .setCustom)
        #expect(ModelManagerRouter.outcome(of: request, currentModel: .custom, busy: true) == .ignore)
    }
}
