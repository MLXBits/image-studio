import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// The registry builds every family's queue once, so the lists the app loops
/// over (the hand-off, profile switches, outcome reporting, the dock badge)
/// all come from one place and cannot miss a family.
@MainActor
struct FamilyRegistryTests {
    private let settings = AppSettings()

    private func registry(driver: MfluxDriverController? = nil) -> FamilyRegistry {
        FamilyRegistry(driver: driver ?? MfluxDriverController(settings: settings))
    }

    @Test func everyFamilyHasOneQueueInRunOrder() {
        #expect(registry().all.map(\.family) == GenerationCoordinator.runOrder)
    }

    /// One warm driver keeps one model, so every generative family shares it.
    /// SeedVR2 runs as a CLI and never uses it.
    @Test func generativeRunnersShareTheWarmDriver() {
        let driver = MfluxDriverController(settings: settings)
        let families = registry(driver: driver)
        #expect(families.flux.runner.driver === driver)
        #expect(families.ideogram4.runner.driver === driver)
        #expect(families.krea2.runner.driver === driver)
        #expect(families.zimage.runner.driver === driver)
        #expect(families.qwen21.runner.driver === driver)
        #expect(families.seedVR2.runner.driver == nil)
    }

    /// A profile switch swaps every queue's jobs, so it needs every store.
    @Test func jobStoresAreTheQueuesOwnInRunOrder() {
        let families = registry()
        let expected: [AnyObject] = [
            families.flux.store, families.ideogram4.store, families.krea2.store,
            families.zimage.store, families.qwen21.store, families.seedVR2.store,
        ]
        #expect(families.jobStores.map { ObjectIdentifier($0) } == expected.map { ObjectIdentifier($0) })
    }

    /// The support nudge and the finish notifications hear from every runner.
    @Test func reportersAreTheQueuesOwnRunnersInRunOrder() {
        let families = registry()
        let expected: [AnyObject] = [
            families.flux.runner, families.ideogram4.runner, families.krea2.runner,
            families.zimage.runner, families.qwen21.runner, families.seedVR2.runner,
        ]
        #expect(families.reporters.map { ObjectIdentifier($0) } == expected.map { ObjectIdentifier($0) })
    }

    /// The dock badge counts every queue's waiting images.
    @Test func imagesLeftCountsEveryQueue() {
        let families = registry()
        #expect(families.imagesLeft == 0)
        families.krea2.add([Krea2Job(prompt: "a fox")])
        families.seedVR2.add([SeedVR2Job(sourcePath: "/out/a.png")])
        #expect(families.imagesLeft == 2)
    }
}
