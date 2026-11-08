# Custom app icons (In-App Purchase)

Blue Camera is the free app icon. **Lens**, **Black Camera**, and nine camera model icons are unlocked by one optional, one-time In-App Purchase that supports development:

- GM1S Orange
- GM1 Silver
- GM1 All Black
- GX85
- GX9
- G85 / G80
- FZ80 / FZ82
- FZ300
- FZ1000

The app sells nothing else and has no accounts.

## Product

| Field | Value |
|---|---|
| Type | Non-consumable |
| Product ID | `com.web3.gm1sync.customicons` |
| Reference name | Custom app icons |
| Price | USD 0.99 (Apple's price point closest to $1) |
| Display name (en-US) | Custom app icons |
| Description (en-US) | Unlock all app icons and support development. (App Store Connect allows 55 characters.) |
| Family Sharing | Off |

## How the app handles it

- `AppIconStore` (`LumixProbe/AppIconStore.swift`) loads the price, checks `Transaction.currentEntitlements`, buys with `Product.purchase()`, and listens to `Transaction.updates` for Ask to Buy approvals, purchases on other devices, and refunds. A refund locks the icons again.
- **App Icon** shows the price, **Unlock for $0.99**, and **Restore purchase**, which App Review requires for non-consumables. Tapping a locked icon also starts the purchase, then switches to that icon.
- **Already using a custom icon:** someone with Lens or Black Camera set when this version first runs keeps Lens and Black Camera free (`AppIconChoice.wasFreeBefore`). The app decides this once and stores it in `UserDefaults` (`customIconsGrandfathered.v1`). The camera model icons were never free, so everyone needs the purchase for them.
- The About note on the home screen names the price ("You can support development by unlocking the custom app icons for $0.99.") and thanks people who bought it.
- Without the product in App Store Connect the price is missing, the unlock button is disabled, and the screen says the App Store isn't offering the icons right now.

## Icon artwork

- **Source:** the owner's `Downloads/app icons` folder: nine 1254 × 1254 opaque PNGs.
- **Corners:** six of them (GX85, GX9, G85, FZ80, FZ300, FZ1000) had rounded corners with black outside, slightly rounder than the corners iOS cuts. Their corners were filled from the neighboring edge colors to give square, full-bleed artwork; iOS rounds icons itself.
- **Sizes:** each icon is a 1024 × 1024 PNG in its own `.appiconset`, with a 256 × 256 `…IconPreview` image for the picker. The alternate icon names are listed in `project.yml` (`ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`).
- **Release risk:** the camera model icons show the **LUMIX** logo, and FZ300 and FZ1000 also show **LEICA** on the lens. These are Panasonic's and Leica's trademarks. App Review may reject them under guideline 5.2.1 (protected third-party material), especially as a paid feature, and they conflict with the app's statement that it isn't affiliated with Panasonic. Logo-free versions of the same artwork would avoid this.

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
