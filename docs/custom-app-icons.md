# Custom app icons (In-App Purchase)

Blue Camera is the free app icon. **Lens** and **Black Camera** are unlocked by one optional, one-time In-App Purchase that supports development. The app sells nothing else and has no accounts.

## Product

| Field | Value |
|---|---|
| Type | Non-consumable |
| Product ID | `com.web3.gm1sync.customicons` |
| Reference name | Custom app icons |
| Price | USD 0.99 (Apple's price point closest to $1) |
| Display name (en-US) | Custom app icons |
| Description (en-US) | Unlock the Lens and Black Camera app icons and support development. |
| Family Sharing | Off |

## How the app handles it

- `AppIconStore` (`LumixProbe/AppIconStore.swift`) loads the price, checks `Transaction.currentEntitlements`, buys with `Product.purchase()`, and listens to `Transaction.updates` for Ask to Buy approvals, purchases on other devices, and refunds. A refund locks the icons again.
- **App Icon** shows the price, **Unlock for $0.99**, and **Restore purchase**, which App Review requires for non-consumables. Tapping a locked icon also starts the purchase, then switches to that icon.
- **Already using a custom icon:** someone with Lens or Black Camera set when this version first runs keeps every custom icon free. The app decides this once and stores it in `UserDefaults` (`customIconsGrandfathered.v1`).
- The About note on the home screen names the price ("You can support development by unlocking the custom app icons for $0.99.") and thanks people who bought it.
- Without the product in App Store Connect the price is missing, the unlock button is disabled, and the screen says the App Store isn't offering the icons right now.

## App Store Connect setup (Account Holder or Admin)

1. **Agreements, Tax, and Banking:** accept the Paid Applications agreement and add bank and tax details. Without it, no In-App Purchase can be sold.
2. **Apps → Retro LUMIX Sync → Monetization → In-App Purchases → +:** create the product with the values above, add the localization, set the price, and add a review screenshot of the **App Icon** screen.
3. **Submission:** a first In-App Purchase must be submitted together with an app version. Add it under **In-App Purchases and Subscriptions** on the 1.1.0 version page before **Add for Review**.
4. **Optional:** enroll in the App Store Small Business Program, so Apple's commission is 15% instead of 30%.

## Testing

- **Simulator:**
  - `xcodebuild` and `simctl` launches use no StoreKit configuration, so the product is missing and the icons stay locked.
  - **Run** from Xcode uses `StoreKit/RetroLUMIXSync.storekit`, which the `GM1Sync` scheme's run action references, for local purchases without an account.
  - The launch argument `-UITestIconPurchase` uses a demo store with a $0.99 price and an instant purchase. `testCustomIconsUnlockWithAPurchase` uses it.
- **Unit tests:** `AppIconStoreTests` covers buying, cancelling, Ask to Buy, failures, restoring, refunds, and keeping icons free for people already using them, with a fake App Store. Apple's `SKTestSession` didn't apply the local configuration under `xcodebuild` on the iOS 27.2 simulator (StoreKit still asked the real App Store), so there is no automated test against StoreKit itself.
- **Device:** once the product exists, TestFlight builds buy it in the sandbox for free. Check buying, **Restore purchase** after deleting and reinstalling the app, and a refund (Settings → App Store → Sandbox Account → Manage) before release.
