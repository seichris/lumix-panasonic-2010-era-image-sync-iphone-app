# GM1 Sync Camera Browser Implementation Plan

## Outcome

Turn the proven Lumix GM1S connection and transfer diagnostics into the app's primary photo-import workflow. A user should connect once using the camera's Image App network, browse every photo on the card, inspect a preview, and save one or many originals to the iPhone without switching the camera to another Wi-Fi mode.

## Proven foundation

- Camera setup: `Wi-Fi -> New Connection -> Remote Shooting & View -> Direct -> Image App`.
- The iPhone can remain on that one network for state checks, playback-mode browsing, thumbnails, previews, and original JPEG downloads.
- The camera exposes 81 content items through UPnP ContentDirectory in playback mode.
- `CAM_TN`, `CAM_LRGTN`, `CAM_RAW_JPG`, and `CAM_RAW` resources are advertised.
- The GM1S media server requires the app's HTTP/1.0-compatible downloader on port 50001.
- A full 4592 x 3448 original JPEG has already been downloaded, verified, and saved to Photos.

## Product flow

1. If the camera is unreachable, show the short camera setup guide, QR scanner, and manual Wi-Fi fallback.
2. Once reachable, place the camera in playback mode and open the photo browser.
3. Load the newest page first and continue until all advertised content is available.
4. Show lightweight thumbnails in a lazy grid with stable ordering and identity.
5. Open a photo detail screen with a larger preview, metadata, geotag status, and Save to Photos action.
6. Allow selecting multiple photos and importing them sequentially with visible progress and per-item results.
7. Recover cleanly after camera sleep, battery replacement, app relaunch, or Wi-Fi reconnection.

## Architecture

### Camera domain model

- Introduce a stable `LumixPhoto` value keyed by the camera item ID.
- Group the DIDL resources for each item instead of exposing a flat resource list.
- Resolve media profiles by purpose:
  - thumbnail: `CAM_TN`, then `CAM_LRGTN`
  - preview: `CAM_LRGTN`, then `CAM_TN`
  - original JPEG: `CAM_ORG`, then `CAM_RAW_JPG`
  - RAW companion: `CAM_RAW`
- Keep pagination metadata (`start`, returned count, total count) separate from display state.

### Client layer

- Add a browse API that returns grouped photos and total count.
- Expose the proven legacy media downloader for thumbnails, previews, and originals.
- Keep camera mode recovery in one operation: request playback mode, tolerate the camera's short busy period, then browse.
- Preserve bounded retries for transient camera errors and surface actionable failures to the UI.

### Gallery state

- Add a focused main-actor gallery store with explicit idle, loading, loaded, empty, and failed states.
- Load in pages, deduplicate by item ID, and preserve deterministic camera order.
- Cache only lightweight thumbnail/preview data in memory; never preload originals.
- Cancel obsolete loads when the view disappears or a refresh supersedes them.
- Track selection, individual imports, batch progress, successful item IDs, and item-specific failures.

### SwiftUI

- Make the connected experience a `NavigationStack` photo browser instead of a diagnostics list.
- Use `LazyVGrid` for thumbnails and trigger the next page near the end of the current page.
- Use `ContentUnavailableView` for disconnected, empty, and recoverable error states.
- Provide a detail destination with preview, original download/save, and geotag preview.
- Keep protocol diagnostics available behind a secondary diagnostics screen.
- Keep deterministic previews for disconnected, loading, populated, empty, and error states.

### QR and connection fallback

- Continue accepting standards-compliant `WIFI:` QR codes and supported URL payloads.
- Never log or display a scanned Wi-Fi password after parsing.
- When an older Panasonic QR payload cannot be decoded, preserve a redacted payload fingerprint for diagnostics and immediately offer manual SSID/password entry plus the iOS Wi-Fi Settings shortcut.
- Treat scanning the physical GM1S QR as a hardware acceptance gate; do not claim proprietary payload support without that test.

## Implementation phases

1. Add grouped photo models and pagination APIs with unit tests.
2. Add the gallery store, media cache, recovery, selection, and sequential import pipeline with mocked-camera tests.
3. Build the grid, detail, import progress, connection fallback, and diagnostics navigation.
4. Add QR failure diagnostics and manual Wi-Fi entry.
5. Update documentation to make the single Image App mode the canonical workflow.
6. Run host tests, simulator UI tests, device build/install/launch checks, and live-camera validation where hardware is available.

## Acceptance gates

### Automated

- Pagination loads every item, deduplicates overlapping pages, and stops at the server total.
- Resource selection chooses thumbnail, preview, original JPEG, and RAW profiles in the documented order.
- A ten-item sequential import continues after a single-item failure and reports accurate progress/results.
- Refresh/reconnect replaces stale state without duplicate photos or orphaned tasks.
- QR tests cover standard Wi-Fi payloads, supported URL payloads, malformed input, and redacted unsupported-payload reporting.
- The app and unit/UI test targets build successfully with the WEB3 team configuration.

### Physical iPhone and GM1S

- The installed app is signed by WEB3 team `4H5PK8686H` and launches on the connected iPhone.
- The app hides connection setup when `192.168.54.1` is reachable and returns to recovery UI when it is not.
- All 81 current card items can be paged into the browser using only Image App Direct mode.
- Thumbnails render, a detail preview opens, and an original saves to Photos.
- Ten consecutive originals download without switching Wi-Fi modes; failures are isolated and retryable.
- Sleep/wake, battery replacement, app relaunch, and Wi-Fi reconnect each recover through Retry or automatic foreground refresh.
- The physical camera QR code is scanned once; its actual payload format and connection result are recorded without exposing the password.

## Scope boundary

This branch does not add cloud sync, background importing while iOS suspends the app, video transfer, or RAW decoding. RAW resources may be identified for future export, while this workflow imports original JPEGs into Photos.
