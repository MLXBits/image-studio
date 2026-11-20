@testable import MLXBits_Image_Studio
import Testing

/// The cross-family run gate, and the order queued work runs in across families.
@Suite("Generation coordinator")
struct GenerationCoordinatorTests {
    // MARK: - Gate

    @Test func anIdleGateGoesToTheFirstFamilyToAsk() {
        let gate = GenerationCoordinator()
        #expect(gate.tryAcquire(.krea2))
        #expect(gate.activeFamily == .krea2)
    }

    /// The holder asks again for each job in its queue.
    @Test func theHolderCanAcquireAgain() {
        let gate = GenerationCoordinator()
        _ = gate.tryAcquire(.flux)
        #expect(gate.tryAcquire(.flux))
    }

    @Test func anotherFamilyWaitsWhileOneRuns() {
        let gate = GenerationCoordinator()
        _ = gate.tryAcquire(.flux)
        #expect(!gate.tryAcquire(.seedvr2))
        #expect(gate.activeFamily == .flux)
    }

    @Test func releaseFreesTheGateForTheNextFamily() {
        let gate = GenerationCoordinator()
        _ = gate.tryAcquire(.flux)
        gate.release(.flux)
        #expect(gate.activeFamily == nil)
        #expect(gate.tryAcquire(.qwen21))
    }

    /// A late release from a family that no longer holds the gate leaves the holder alone.
    @Test func onlyTheHolderCanRelease() {
        let gate = GenerationCoordinator()
        _ = gate.tryAcquire(.zimage)
        gate.release(.krea2)
        #expect(gate.activeFamily == .zimage)
    }

    // MARK: - Run order across families

    @Test func nothingRunsWhenNothingWaits() {
        #expect(GenerationCoordinator.nextFamily { _ in false } == nil)
    }

    @Test func everyFamilyIsInTheRunOrderOnce() {
        #expect(Set(GenerationCoordinator.runOrder) == Set(ModelFamily.allCases))
        #expect(GenerationCoordinator.runOrder.count == ModelFamily.allCases.count)
    }

    /// Fixed family order, not FIFO: Flux, Ideogram 4, Krea 2, Z-Image, Qwen,
    /// then SeedVR2 upscales.
    @Test func familiesRunInTheFixedOrder() {
        #expect(GenerationCoordinator.runOrder == [.flux, .ideogram4, .krea2, .zimage, .qwen21, .seedvr2])
    }

    /// Each family's turn comes only when every earlier family has nothing waiting.
    @Test func theEarliestFamilyWithWaitingJobsRunsNext() {
        let order = GenerationCoordinator.runOrder
        for index in order.indices {
            let waiting = Set(order[index...])
            #expect(GenerationCoordinator.nextFamily { waiting.contains($0) } == order[index])
        }
    }

    /// Upscales wait behind every generative queue, so a batch is not split by
    /// a model switch to SeedVR2 and back.
    @Test func upscalesWaitForGenerativeQueues() {
        let next = GenerationCoordinator.nextFamily { $0 == .seedvr2 || $0 == .qwen21 }
        #expect(next == .qwen21)
    }
}
