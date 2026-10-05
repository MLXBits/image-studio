import Foundation
@testable import MLXBits_Image_Studio
import StoreKit
import StoreKitTest
import Testing

/// StoreKit 2 against `Resources/Tips.storekit` (spec §7). Serialized: the
/// test session is process-wide.
///
/// No test here calls `Product.purchase()`: in this hosted test run it goes
/// to the real App Store and shows an Apple Account sign-in. Purchase
/// outcomes are covered by `TipJarStoreTests` (fake storefront) and the
/// manual run of the App Store scheme with `Tips.storekit`.
/// Off on CI (`STOREKIT_TESTS=0`): unsigned test runs aren't entitled to
/// StoreKitTest.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["STOREKIT_TESTS"] != "0"))
struct StoreKitStorefrontTests {
    private final class BundleToken {}

    private func session() throws -> SKTestSession {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "Tips", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        return session
    }

    private func unfinishedCount() async -> Int {
        var count = 0
        for await _ in Transaction.unfinished {
            count += 1
        }
        return count
    }

    @Test func theThreeTipsLoad() async throws {
        _ = try session()
        let products = try await StoreKitStorefront().products(for: TipJarStore.productIDs)
        #expect(Set(products.map(\.id)) == Set(TipJarStore.productIDs))
        #expect(products.map { String(format: "%.2f", ($0.price as NSDecimalNumber).doubleValue) }.sorted()
            == ["2.99", "4.99", "9.99"])
    }

    @Test func anUnloadedTipCantBeBought() async throws {
        _ = try session()
        await #expect(throws: TipJarError.self) { try await StoreKitStorefront().purchase(TipJarStore.productIDs[0]) }
    }

    /// A tip bought outside a purchase call, as an interrupted purchase is
    /// at the next launch, is finished by the listener.
    @Test func anInterruptedTipIsFinishedLater() async throws {
        let session = try session()
        _ = try await session.buyProduct(identifier: TipJarStore.productIDs[2])
        #expect(await unfinishedCount() == 1)

        let storefront = StoreKitStorefront()
        var finished = storefront.finishedTransactions(for: Set(TipJarStore.productIDs)).makeAsyncIterator()
        _ = await finished.next()
        #expect(await unfinishedCount() == 0)
    }
}
