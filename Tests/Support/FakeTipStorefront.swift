import Foundation
@testable import MLXBits_Image_Studio

/// A storefront for TipJarStore's tests: set what loading and purchasing
/// return; `gate`, when set, holds a purchase until it opens.
final class FakeTipStorefront: TipStorefront {
    static let tips = [
        TipProduct(id: TipJarStore.productIDs[2], displayName: "Large Tip", displayPrice: "$9.99", price: 9.99),
        TipProduct(id: TipJarStore.productIDs[0], displayName: "Small Tip", displayPrice: "$2.99", price: 2.99),
        TipProduct(id: TipJarStore.productIDs[1], displayName: "Medium Tip", displayPrice: "$4.99", price: 4.99),
    ]

    var catalog: Result<[TipProduct], Error> = .success(tips)
    var outcome: Result<TipPurchaseOutcome, Error> = .success(.tipped)
    var gate: AsyncGate?
    private(set) var purchases: [String] = []
    let finished = AsyncStream<Void>.makeStream()

    func products(for _: [String]) async throws -> [TipProduct] {
        try catalog.get()
    }

    func purchase(_ id: String) async throws -> TipPurchaseOutcome {
        purchases.append(id)
        await gate?.wait()
        return try outcome.get()
    }

    func finishedTransactions(for _: Set<String>) -> AsyncStream<Void> {
        finished.stream
    }
}
