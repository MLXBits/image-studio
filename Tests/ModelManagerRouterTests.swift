@testable import MLXBits_Image_Studio
import Testing

struct ModelManagerRouterTests {
    @Test func showingACustomModelSelectsFlux3() {
        #expect(ModelManagerRouter.item(for: .custom) == .model(.flux3Klein))
        #expect(ModelManagerRouter.item(for: .krea2) == .model(.krea2))
    }
}
