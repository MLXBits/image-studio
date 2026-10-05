import Foundation
import StoreKit

/// One tip as the store sells it: name and local price come from the store,
/// never from code (spec §5).
struct TipProduct: Identifiable, Equatable {
    let id: String
    let displayName: String
    let displayPrice: String
    let price: Decimal
}

/// How a tip purchase ended. Failures throw.
enum TipPurchaseOutcome: Equatable {
    case tipped
    case pending
    case cancelled
}

enum TipJarError: Error {
    case productUnavailable
    case unverified
}

/// Where tips are bought: StoreKit in the app (``StoreKitStorefront``), a fake
/// in tests.
protocol TipStorefront: AnyObject {
    func products(for ids: [String]) async throws -> [TipProduct]
    /// Buys, verifies and finishes one tip.
    func purchase(_ id: String) async throws -> TipPurchaseOutcome
    /// Finishes tips that completed outside a purchase call (Ask to Buy
    /// approved later, a purchase interrupted last launch), yielding once for
    /// each.
    func finishedTransactions(for ids: Set<String>) -> AsyncStream<Void>
}

/// The App Store build's tip jar: three consumable tips that unlock nothing.
@Observable
final class TipJarStore {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case unavailable
        case purchasing(String)
        case thanked
        case pending
        case failed
    }

    static let productIDs = [
        "com.mlxbits.image-studio.appstore.tip.small",
        "com.mlxbits.image-studio.appstore.tip.medium",
        "com.mlxbits.image-studio.appstore.tip.large",
    ]

    private(set) var products: [TipProduct] = []
    private(set) var phase: Phase = .idle
    @ObservationIgnored private let storefront: TipStorefront
    @ObservationIgnored private let onTipped: () -> Void
    @ObservationIgnored private var finishing: Task<Void, Never>?

    /// Tip buttons work once tips have loaded and no purchase is running.
    var canPurchase: Bool {
        switch phase {
        case .ready, .thanked, .pending, .failed: true
        case .idle, .loading, .unavailable, .purchasing: false
        }
    }

    init(storefront: TipStorefront, onTipped: @escaping () -> Void) {
        self.storefront = storefront
        self.onTipped = onTipped
    }

    /// Loads the tips, cheapest first. Again after a failure (Try Again).
    func load() async {
        guard phase == .idle || phase == .unavailable else { return }
        phase = .loading
        do {
            products = try await storefront.products(for: Self.productIDs).sorted { $0.price < $1.price }
            phase = products.isEmpty ? .unavailable : .ready
        } catch {
            phase = .unavailable
        }
    }

    func purchase(_ id: String) async {
        guard canPurchase, products.contains(where: { $0.id == id }) else { return }
        phase = .purchasing(id)
        do {
            switch try await storefront.purchase(id) {
            case .tipped:
                phase = .thanked
                onTipped()
            case .pending:
                phase = .pending
            case .cancelled:
                phase = .ready
            }
        } catch StoreKitError.userCancelled {
            // Dismissing the Apple Account sign-in throws instead of returning
            // .userCancelled; a cancel shows nothing either way.
            phase = .ready
        } catch {
            phase = .failed
        }
    }

    /// The window reopened: start without the last outcome's caption.
    func clearOutcome() {
        switch phase {
        case .thanked, .pending, .failed: phase = .ready
        default: break
        }
    }

    /// Started once at launch: finishes tips that complete outside a purchase.
    func startFinishingTransactions() {
        guard finishing == nil else { return }
        let finished = storefront.finishedTransactions(for: Set(Self.productIDs))
        finishing = Task { [weak self, onTipped] in
            for await _ in finished {
                onTipped()
                // Ask to Buy approved while the window shows "waiting".
                if self?.phase == .pending {
                    self?.phase = .thanked
                }
            }
        }
    }
}
