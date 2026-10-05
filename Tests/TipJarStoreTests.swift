import Foundation
@testable import MLXBits_Image_Studio
import StoreKit
import Testing

/// The App Store tip jar (spec §5): three consumable tips that unlock nothing.
struct TipJarStoreTests {
    private struct Failure: Error {}

    private func store(_ fake: FakeTipStorefront, tipped: @escaping () -> Void = {}) -> TipJarStore {
        TipJarStore(storefront: fake, onTipped: tipped)
    }

    @Test func tipsLoadCheapestFirst() async {
        let jar = store(FakeTipStorefront())
        await jar.load()
        #expect(jar.phase == .ready)
        #expect(jar.products.map(\.displayPrice) == ["$2.99", "$4.99", "$9.99"])
    }

    @Test func emptyOrFailedLoadShowsUnavailable() async {
        let empty = FakeTipStorefront()
        empty.catalog = .success([])
        let emptyJar = store(empty)
        await emptyJar.load()
        #expect(emptyJar.phase == .unavailable)

        let failing = FakeTipStorefront()
        failing.catalog = .failure(Failure())
        let failingJar = store(failing)
        await failingJar.load()
        #expect(failingJar.phase == .unavailable)

        failing.catalog = .success(FakeTipStorefront.tips)
        await failingJar.load()
        #expect(failingJar.phase == .ready)
    }

    @Test func aTipThanksAndRecordsIt() async {
        var tipped = 0
        let fake = FakeTipStorefront()
        let jar = store(fake) { tipped += 1 }
        await jar.load()
        await jar.purchase(TipJarStore.productIDs[0])
        #expect(jar.phase == .thanked)
        #expect(tipped == 1)
        #expect(jar.canPurchase)
    }

    /// Tips are consumables: the same tip, or another, can be left again
    /// right after a thank-you.
    @Test func aPersonCanTipAgain() async {
        var tipped = 0
        let fake = FakeTipStorefront()
        let jar = store(fake) { tipped += 1 }
        await jar.load()
        await jar.purchase(TipJarStore.productIDs[0])
        await jar.purchase(TipJarStore.productIDs[0])
        await jar.purchase(TipJarStore.productIDs[2])
        #expect(fake.purchases == [TipJarStore.productIDs[0], TipJarStore.productIDs[0], TipJarStore.productIDs[2]])
        #expect(tipped == 3)
        #expect(jar.phase == .thanked)
    }

    @Test func cancelledAndPendingAreQuiet() async {
        var tipped = 0
        let fake = FakeTipStorefront()
        let jar = store(fake) { tipped += 1 }
        await jar.load()

        fake.outcome = .success(.cancelled)
        await jar.purchase(TipJarStore.productIDs[0])
        #expect(jar.phase == .ready)

        fake.outcome = .success(.pending)
        await jar.purchase(TipJarStore.productIDs[0])
        #expect(jar.phase == .pending)
        #expect(tipped == 0)
    }

    @Test func aFailedPurchaseSaysSo() async {
        let fake = FakeTipStorefront()
        fake.outcome = .failure(TipJarError.unverified)
        let jar = store(fake)
        await jar.load()
        await jar.purchase(TipJarStore.productIDs[0])
        #expect(jar.phase == .failed)
        #expect(jar.canPurchase)
    }

    @Test func aSecondPurchaseWhileOneRunsIsIgnored() async {
        let fake = FakeTipStorefront()
        let gate = AsyncGate()
        fake.gate = gate
        let jar = store(fake)
        await jar.load()

        let first = Task { await jar.purchase(TipJarStore.productIDs[0]) }
        while fake.purchases.isEmpty {
            await Task.yield()
        }
        #expect(!jar.canPurchase)
        await jar.purchase(TipJarStore.productIDs[1])
        gate.open()
        await first.value
        #expect(fake.purchases == [TipJarStore.productIDs[0]])
    }

    /// Ask to Buy approved later, or a purchase interrupted last launch.
    @Test func aTransactionFinishedLaterCountsAsTipped() async {
        var tipped = 0
        let fake = FakeTipStorefront()
        let jar = store(fake) { tipped += 1 }
        jar.startFinishingTransactions()
        jar.startFinishingTransactions()
        fake.finished.continuation.yield()
        for _ in 0 ..< 100 where tipped == 0 {
            await Task.yield()
        }
        #expect(tipped == 1)
    }

    /// Dismissing the Apple Account sign-in throws rather than returning
    /// `.userCancelled`. It's still a cancel, so nothing is shown.
    @Test func aThrownCancelIsQuiet() async {
        let fake = FakeTipStorefront()
        fake.outcome = .failure(StoreKitError.userCancelled)
        let jar = store(fake)
        await jar.load()
        await jar.purchase(TipJarStore.productIDs[0])
        #expect(jar.phase == .ready)
    }

    /// Ask to Buy approved while the window is open: the waiting caption
    /// becomes the thank-you.
    @Test func anApprovedTipThanksInPlace() async {
        let fake = FakeTipStorefront()
        fake.outcome = .success(.pending)
        let jar = store(fake)
        await jar.load()
        await jar.purchase(TipJarStore.productIDs[0])
        jar.startFinishingTransactions()
        fake.finished.continuation.yield()
        for _ in 0 ..< 100 where jar.phase == .pending {
            await Task.yield()
        }
        #expect(jar.phase == .thanked)
    }

    /// Reopening the window starts without the last outcome's caption.
    @Test func reopeningClearsTheLastOutcome() async {
        let jar = store(FakeTipStorefront())
        await jar.load()
        await jar.purchase(TipJarStore.productIDs[0])
        jar.clearOutcome()
        #expect(jar.phase == .ready)
    }

    /// The IDs created in App Store Connect, which allows only letters,
    /// digits, periods and underscores (a hyphenated ID can't exist there).
    @Test func productIDsMatchAppStoreConnect() {
        #expect(TipJarStore.productIDs == [
            "com.mlxbits.imagestudio.appstore.tip.small",
            "com.mlxbits.imagestudio.appstore.tip.medium",
            "com.mlxbits.imagestudio.appstore.tip.large",
        ])
        #expect(TipJarStore.productIDs.allSatisfy {
            $0.range(of: #"^[A-Za-z0-9._]+$"#, options: .regularExpression) != nil
        })
    }

    /// The local StoreKit configuration sells the same tips the app asks for.
    @Test func theLocalConfigurationHasTheSameIDs() throws {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "Tips", withExtension: "storekit"))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let products = try #require(json["products"] as? [[String: Any]])
        #expect(Set(products.compactMap { $0["productID"] as? String }) == Set(TipJarStore.productIDs))
    }
}

private final class BundleToken {}
