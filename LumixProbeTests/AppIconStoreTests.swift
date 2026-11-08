import Foundation
import XCTest
@testable import GM1Sync

@MainActor
final class AppIconStoreTests: XCTestCase {
    private let cameraModelIcons: [AppIconChoice] = [.gm1sOrange, .gm1Silver, .gm1AllBlack, .gx85, .gx9, .g85, .fz80, .fz300, .fz1000]

    func testBlueCameraIsFreeAndCustomIconsWaitForThePurchase() async {
        let store = AppIconStore(service: FakeIconPurchaseService(), defaults: freshDefaults(), currentIcon: .primary)
        await store.refresh()
        XCTAssertTrue(store.isAvailable(.primary))
        XCTAssertFalse(store.isAvailable(.lens))
        XCTAssertFalse(store.isAvailable(.blackCamera))
        XCTAssertTrue(cameraModelIcons.allSatisfy { !store.isAvailable($0) })
        XCTAssertEqual(store.price, "$0.99")
        XCTAssertFalse(store.isGrandfathered)
    }

    func testAPurchaseUnlocksEveryIcon() async {
        let store = AppIconStore(service: FakeIconPurchaseService(outcome: .success(.purchased)),
                                 defaults: freshDefaults(), currentIcon: .primary)
        await store.purchase()
        XCTAssertTrue(store.ownsPurchase)
        XCTAssertTrue(AppIconChoice.allCases.allSatisfy(store.isAvailable))
        XCTAssertEqual(store.purchaseState, .idle)
    }

    func testCancellingKeepsTheIconsLocked() async {
        let store = AppIconStore(service: FakeIconPurchaseService(outcome: .success(.cancelled)),
                                 defaults: freshDefaults(), currentIcon: .primary)
        await store.purchase()
        XCTAssertFalse(store.ownsPurchase)
        XCTAssertFalse(store.isAvailable(.gx85))
        XCTAssertEqual(store.purchaseState, .idle)
    }

    func testAskToBuyWaitsAndUnlocksWhenApproved() async {
        let service = FakeIconPurchaseService(outcome: .success(.pending))
        let store = AppIconStore(service: service, defaults: freshDefaults(), currentIcon: .primary)
        await store.purchase()
        XCTAssertEqual(store.purchaseState, .pending)
        XCTAssertFalse(store.ownsPurchase)

        await service.grant()
        XCTAssertTrue(store.ownsPurchase, "An approved purchase arrives as a transaction update")
        XCTAssertEqual(store.purchaseState, .idle)
    }

    func testAFailedPurchaseIsReportedAndCanBeDismissed() async {
        let store = AppIconStore(service: FakeIconPurchaseService(outcome: .failure(IconPurchaseError.unavailable)),
                                 defaults: freshDefaults(), currentIcon: .primary)
        await store.purchase()
        XCTAssertEqual(store.purchaseState, .failed(IconPurchaseError.unavailable.localizedDescription))
        XCTAssertFalse(store.ownsPurchase)
        store.dismissError()
        XCTAssertEqual(store.purchaseState, .idle)
    }

    func testRestoreUnlocksWhenTheAccountOwnsTheIcons() async {
        let service = FakeIconPurchaseService(ownsAfterRestore: true)
        let store = AppIconStore(service: service, defaults: freshDefaults(), currentIcon: .primary)
        await store.refresh()
        XCTAssertFalse(store.ownsPurchase)
        await store.restore()
        XCTAssertTrue(store.ownsPurchase)
        XCTAssertTrue(store.isAvailable(.fz1000))
        XCTAssertEqual(store.purchaseState, .idle)
    }

    func testRestoreWithoutAPurchaseSaysSo() async {
        let store = AppIconStore(service: FakeIconPurchaseService(), defaults: freshDefaults(), currentIcon: .primary)
        await store.restore()
        XCTAssertEqual(store.purchaseState, .failed("This Apple Account hasn't bought the custom icons."))
    }

    func testARefundLocksTheIconsAgain() async {
        let service = FakeIconPurchaseService()
        let store = AppIconStore(service: service, defaults: freshDefaults(), currentIcon: .primary)
        await service.grant()
        XCTAssertTrue(store.isAvailable(.gx9))
        await service.revoke()
        XCTAssertFalse(store.ownsPurchase)
        XCTAssertFalse(store.isAvailable(.gx9))
    }

    func testSomeoneAlreadyUsingLensOrBlackCameraKeepsBothFree() async {
        let defaults = freshDefaults()
        let store = AppIconStore(service: FakeIconPurchaseService(), defaults: defaults, currentIcon: .blackCamera)
        await store.refresh()
        XCTAssertTrue(store.isGrandfathered)
        XCTAssertTrue(store.isAvailable(.lens))
        XCTAssertTrue(store.isAvailable(.blackCamera))
        XCTAssertTrue(cameraModelIcons.allSatisfy { !store.isAvailable($0) }, "The camera model icons were never free")
        XCTAssertFalse(store.ownsPurchase)

        let later = AppIconStore(service: FakeIconPurchaseService(), defaults: defaults, currentIcon: .primary)
        XCTAssertTrue(later.isAvailable(.lens), "Decided once: switching back to Blue Camera keeps Lens and Black Camera free")
    }

    func testSomeoneKeepingFreeIconsCanStillBuyTheCameraModels() async {
        let store = AppIconStore(service: FakeIconPurchaseService(outcome: .success(.purchased)),
                                 defaults: freshDefaults(), currentIcon: .lens)
        XCTAssertFalse(store.isAvailable(.gm1sOrange))
        await store.purchase()
        XCTAssertTrue(store.isAvailable(.gm1sOrange))
    }

    func testANewInstallIsNotGrandfatheredLater() {
        let defaults = freshDefaults()
        _ = AppIconStore(service: FakeIconPurchaseService(), defaults: defaults, currentIcon: .primary)
        let later = AppIconStore(service: FakeIconPurchaseService(), defaults: defaults, currentIcon: .blackCamera)
        XCTAssertFalse(later.isGrandfathered)
        XCTAssertFalse(later.isAvailable(.blackCamera))
    }

    private func freshDefaults() -> UserDefaults {
        let name = "AppIconStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
}

/// An App Store stand-in. `grant()` and `revoke()` deliver a transaction update, as an
/// approved Ask to Buy request, a purchase on another device, or a refund would.
private final class FakeIconPurchaseService: IconPurchaseService, @unchecked Sendable {
    private let lock = NSLock()
    private let outcome: Result<IconPurchaseOutcome, Error>
    private let ownsAfterRestore: Bool
    private var owned = false
    private var onChange: (@Sendable () async -> Void)?

    init(outcome: Result<IconPurchaseOutcome, Error> = .success(.cancelled), ownsAfterRestore: Bool = false) {
        self.outcome = outcome
        self.ownsAfterRestore = ownsAfterRestore
    }

    func displayPrice() async -> String? { "$0.99" }

    func purchase() async throws -> IconPurchaseOutcome {
        let result = try outcome.get()
        if result == .purchased { lock.withLock { owned = true } }
        return result
    }

    func ownsCustomIcons() async -> Bool { lock.withLock { owned } }

    func restore() async throws {
        if ownsAfterRestore { lock.withLock { owned = true } }
    }

    func observeEntitlementChanges(_ onChange: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        lock.withLock { self.onChange = onChange }
        return Task {}
    }

    func grant() async {
        let handler = lock.withLock { () -> (@Sendable () async -> Void)? in
            owned = true
            return onChange
        }
        await handler?()
    }

    func revoke() async {
        let handler = lock.withLock { () -> (@Sendable () async -> Void)? in
            owned = false
            return onChange
        }
        await handler?()
    }
}
