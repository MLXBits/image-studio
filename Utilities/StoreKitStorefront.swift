import Foundation
import StoreKit

/// StoreKit 2 behind ``TipStorefront``. Only the App Store build calls it;
/// it compiles in both (spec §7).
final class StoreKitStorefront: TipStorefront {
    private static func verified(_ result: VerificationResult<Transaction>) throws -> Transaction {
        switch result {
        case let .verified(transaction): transaction
        case .unverified: throw TipJarError.unverified
        }
    }

    private static func finish(
        _ result: VerificationResult<Transaction>, ids: Set<String>, continuation: AsyncStream<Void>.Continuation
    ) async {
        guard let transaction = try? verified(result), ids.contains(transaction.productID) else { return }
        await transaction.finish()
        continuation.yield()
    }

    private var loaded: [String: Product] = [:]

    func products(for ids: [String]) async throws -> [TipProduct] {
        let products = try await Product.products(for: ids)
        loaded = Dictionary(products.map { ($0.id, $0) }) { first, _ in first }
        return products.map { TipProduct(id: $0.id, displayName: $0.displayName, displayPrice: $0.displayPrice, price: $0.price) }
    }

    func purchase(_ id: String) async throws -> TipPurchaseOutcome {
        guard let product = loaded[id] else { throw TipJarError.productUnavailable }
        switch try await product.purchase() {
        case let .success(verification):
            let transaction = try Self.verified(verification)
            await transaction.finish()
            return .tipped
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    /// Unfinished tips from before (an interrupted purchase), then every later
    /// update (Ask to Buy approved). Unverified ones are left alone.
    func finishedTransactions(for ids: Set<String>) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                for await result in Transaction.unfinished {
                    await Self.finish(result, ids: ids, continuation: continuation)
                }
                for await result in Transaction.updates {
                    await Self.finish(result, ids: ids, continuation: continuation)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
