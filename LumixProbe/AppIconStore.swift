import Foundation
import StoreKit

/// The app's one purchase: the custom app icons (Lens, Black Camera, and the camera
/// models). It is a one-time, non-consumable purchase that supports development; Blue
/// Camera stays free.
enum CustomIconsProduct {
    static let id = "com.web3.gm1sync.customicons"
}

enum IconPurchaseOutcome: Equatable, Sendable {
    case purchased
    case pending
    case cancelled
}

enum IconPurchaseError: LocalizedError, Equatable {
    case unavailable
    case unverified

    var errorDescription: String? {
        switch self {
        case .unavailable: return "The App Store isn't offering the custom icons right now. Try again later."
        case .unverified: return "The App Store couldn't verify this purchase."
        }
    }
}

/// StoreKit behind a seam, so the unlock rules can be tested without the App Store.
protocol IconPurchaseService: Sendable {
    /// The localized price, or nil when the App Store has no such product.
    func displayPrice() async -> String?
    func purchase() async throws -> IconPurchaseOutcome
    /// Whether this Apple Account owns the icons (and hasn't been refunded).
    func ownsCustomIcons() async -> Bool
    /// Asks the App Store to sync this account's purchases.
    func restore() async throws
    /// Calls `onChange` when a purchase or refund arrives outside `purchase()`, for
    /// example one approved through Ask to Buy or made on another device.
    func observeEntitlementChanges(_ onChange: @escaping @Sendable () async -> Void) -> Task<Void, Never>
}

struct StoreKitIconPurchaseService: IconPurchaseService {
    func displayPrice() async -> String? {
        try? await product()?.displayPrice
    }

    func purchase() async throws -> IconPurchaseOutcome {
        guard let product = try await product() else { throw IconPurchaseError.unavailable }
        switch try await product.purchase() {
        case let .success(verification):
            guard case let .verified(transaction) = verification else { throw IconPurchaseError.unverified }
            await transaction.finish()
            return .purchased
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    func ownsCustomIcons() async -> Bool {
        for await result in Transaction.currentEntitlements {
            if case let .verified(transaction) = result,
               transaction.productID == CustomIconsProduct.id,
               transaction.revocationDate == nil {
                return true
            }
        }
        return false
    }

    func restore() async throws {
        try await AppStore.sync()
    }

    func observeEntitlementChanges(_ onChange: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        Task.detached {
            for await result in Transaction.updates {
                if case let .verified(transaction) = result { await transaction.finish() }
                await onChange()
            }
        }
    }

    private func product() async throws -> Product? {
        try await Product.products(for: [CustomIconsProduct.id]).first
    }
}

/// Whether the custom icons are unlocked, their price, and the purchase in progress.
@MainActor
final class AppIconStore: ObservableObject {
    enum PurchaseState: Equatable {
        case idle
        case purchasing
        case restoring
        /// Waiting for approval, for example Ask to Buy.
        case pending
        case failed(String)
    }

    /// Set once, on the first launch of the version with the purchase: someone already
    /// using Lens or Black Camera then keeps both free (see `AppIconChoice.wasFreeBefore`).
    static let grandfatheredKey = "customIconsGrandfathered.v1"

    /// Whether this Apple Account owns the custom icons, which unlocks every icon.
    @Published private(set) var ownsPurchase = false
    @Published private(set) var price: String?
    @Published private(set) var purchaseState: PurchaseState = .idle
    let isGrandfathered: Bool

    private let service: any IconPurchaseService
    private var updatesTask: Task<Void, Never>?

    init(service: any IconPurchaseService, defaults: UserDefaults = .standard, currentIcon: AppIconChoice) {
        self.service = service
        if defaults.object(forKey: Self.grandfatheredKey) == nil {
            defaults.set(currentIcon != .primary, forKey: Self.grandfatheredKey)
        }
        isGrandfathered = defaults.bool(forKey: Self.grandfatheredKey)
        updatesTask = service.observeEntitlementChanges { [weak self] in
            await self?.refresh()
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    func isAvailable(_ icon: AppIconChoice) -> Bool {
        icon == .primary || ownsPurchase || (isGrandfathered && icon.wasFreeBefore)
    }

    /// Loads the price and whether this Apple Account owns the icons.
    func refresh() async {
        async let loadedPrice = service.displayPrice()
        async let owns = service.ownsCustomIcons()
        price = await loadedPrice
        ownsPurchase = await owns
        if ownsPurchase, purchaseState == .pending { purchaseState = .idle }
    }

    func purchase() async {
        guard purchaseState != .purchasing, purchaseState != .restoring else { return }
        purchaseState = .purchasing
        do {
            switch try await service.purchase() {
            case .purchased:
                ownsPurchase = true
                purchaseState = .idle
            case .pending:
                purchaseState = .pending
            case .cancelled:
                purchaseState = .idle
            }
        } catch {
            purchaseState = .failed(error.localizedDescription)
        }
    }

    func restore() async {
        guard purchaseState != .purchasing, purchaseState != .restoring else { return }
        purchaseState = .restoring
        do {
            try await service.restore()
            await refresh()
            purchaseState = ownsPurchase ? .idle : .failed("This Apple Account hasn't bought the custom icons.")
        } catch {
            purchaseState = .failed(error.localizedDescription)
        }
    }

    func dismissError() {
        if case .failed = purchaseState { purchaseState = .idle }
    }
}

/// UI-test fixture: a price, and a purchase that succeeds without the App Store.
actor DemoIconPurchaseService: IconPurchaseService {
    private var owned = false

    func displayPrice() async -> String? { "$0.99" }

    func purchase() async throws -> IconPurchaseOutcome {
        try await Task.sleep(for: .milliseconds(300))
        owned = true
        return .purchased
    }

    func ownsCustomIcons() async -> Bool { owned }

    func restore() async throws {}

    nonisolated func observeEntitlementChanges(_ onChange: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        Task {}
    }
}
