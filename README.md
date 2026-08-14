# GM1 Sync

Experimental iOS client for transferring and eventually geotagging photos from older Panasonic Wi-Fi cameras. The immediate goal is to validate the camera's local HTTP + UPnP/DLNA protocol on real GM-family hardware before building the full photo-transfer/geotagging experience.

The app starts with the GM1, GM1S, and GM5, but Panasonic reused Image App across many system and compact cameras from roughly 2013 onward. See [COMPATIBILITY.md](COMPATIBILITY.md) for the complete candidate list, regional model names, approximate model eras, and confidence tiers. Every model other than the active hardware test target remains unverified until it passes the capability probe.

## What we know

The GM1S has Wi-Fi but no Bluetooth or GPS. Panasonic Image App connects locally to the camera; cloud access is not required for remote control or media browsing.

On this Lumix protocol family the camera normally acts as a Wi-Fi AP and is commonly reachable at `192.168.54.1`. Camera control is plain HTTP through `/cam.cgi`. Open-source implementations use commands such as:

```text
GET http://192.168.54.1/cam.cgi?mode=getstate
GET http://192.168.54.1/cam.cgi?mode=camcmd&value=recmode
GET http://192.168.54.1/cam.cgi?mode=camcmd&value=playmode
GET http://192.168.54.1/cam.cgi?mode=get_content_info
```

`get_content_info` can return values including `current_position`, `total_content_number`, and `content_number`. libgphoto2 uses `content_number` as its count of available camera media.

Media enumeration uses a UPnP `ContentDirectory:1` SOAP request to:

```text
http://192.168.54.1:60606/Server0/CDS_control
```

The working libgphoto2 Lumix implementation sends `BrowseDirectChildren`, `ObjectID=0`, paging fields, and Panasonic's extra control-point marker:

```xml
<pana:X_FromCP>LumixLink2.0</pana:X_FromCP>
```

Returned DIDL-Lite media items can expose multiple HTTP resources for the same asset, identified by Panasonic DLNA profile names such as original JPEG (`CAM_ORG`), thumbnail (`CAM_TN`), larger preview (`CAM_LRGTN`), RAW-related resources (`CAM_RAW`, `CAM_RAW_JPG`), and movies. Original/preview resources are direct HTTP URLs, commonly served on port `50001`.

The important unknown is camera state. Existing clients switch the camera to `playmode` before media enumeration. We need to determine on the GM1S whether `get_content_info` and/or ContentDirectory browsing works while still in record mode. That decides whether physical-shutter auto-import can be seamless or whether transfer temporarily requires playback mode.

## Target product flow

The intended app is:

1. Connect iPhone to GM1S Wi-Fi.
2. Discover/probe the camera.
3. Authorize if the camera requires Panasonic's access-control handshake.
4. Enumerate media through ContentDirectory.
5. Show camera thumbnails.
6. Download the untouched original JPEG (and RAW when exposed).
7. Save the file into Apple Photos without decoding/re-encoding it.
8. Log iPhone GPS positions with Core Location.
9. Match imported image capture time against the GPS track and assign a `CLLocation` to the Photos asset while preserving original camera bytes.
10. Let iCloud Photos perform its normal sync once the iPhone has Internet access again.

A later Auto Import mode should detect a changed content count/new media ID and import new photos while the app remains connected in the foreground. Continuous arbitrary local-network polling in the iOS background should not be assumed; background Core Location is a separate supported use case.

## What this first app tests

The current GM1 Sync build combines the diagnostic camera controls with an initial end-to-end geotagging flow. It performs these tests separately and keeps the raw responses visible:

- Probe `192.168.54.1` with `getstate`.
- Request camera access using the known `req_acc` shape.
- Show raw camera state.
- Call `get_content_info` in the current state.
- Switch to record mode, then call `get_content_info`.
- Switch to playback mode, then call `get_content_info`.
- Browse the final five ContentDirectory records.
- Parse DIDL-Lite resource URLs and Panasonic profile identifiers.
- Download one advertised `CAM_ORG` JPEG to the app's temporary directory.
- Record and persist a precise iPhone location track during an explicit, visible session, including while the phone is locked.
- Parse the downloaded JPEG's EXIF capture time and match it to a nearby or interpolated track point.
- Preview the proposed location and match confidence before import.
- Add the untouched original file to Apple Photos with asset-level capture time and location metadata.

Location logging starts only when the user taps **Start location log** and stops explicitly. The active blue location indicator remains visible while the app receives updates in the background. A camera-clock adjustment can correct a camera that is ahead or behind the iPhone. Matches more than 15 minutes from a usable track point are rejected rather than silently assigning a dubious geotag.

This should answer the major GM1S-specific unknowns in one test session.

## Running

The project definition uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) so the repository can keep a small readable project configuration instead of a hand-edited `.pbxproj`.

```bash
brew install xcodegen
xcodegen generate
open LumixProbe.xcodeproj
```

Build to a physical iPhone. The Simulator cannot reproduce the camera Wi-Fi environment usefully.

On the GM1S, enable its smartphone Wi-Fi connection and join that network from the iPhone before pressing **Run full probe**. The first release intentionally does not automate joining the SSID; that keeps the protocol test independent of Hotspot Configuration entitlements.

The app requests Local Network and Photos permissions. Plain HTTP is allowed only for local networking via ATS configuration.

Location permission is requested only when geotag logging is started. The iOS Location Updates background mode keeps an active logging session running while the iPhone is locked; it is not used when the logger is stopped.

## Expected test procedure

1. Put an SD card in the GM1S with at least five JPEG photos; also include a RAW+JPEG capture if possible.
2. Enable the camera's smartphone Wi-Fi mode.
3. Join its Wi-Fi from iPhone Settings.
4. Launch GM1 Sync and tap **Probe getstate**.
5. If the camera displays an authorization prompt, approve it.
6. Tap **Run full probe**.
7. Copy the complete on-screen log into an issue or commit it under `captures/` (remove anything sensitive first).
8. Use **Download first original** to fetch a `CAM_ORG` URL.
9. For byte-fidelity validation, copy the matching SD-card JPEG to a computer and compare SHA-256 hashes with the Wi-Fi-downloaded file.

## Current uncertainties to resolve on GM1S hardware

- Exact first-connection/access-control behavior on GM1S.
- Whether arbitrary client names work in `req_acc` or a Panasonic-compatible identity is required.
- Whether `get_content_info` succeeds in record mode.
- Whether ContentDirectory `Browse` succeeds in record mode.
- Whether the camera must remain in playback mode during the full HTTP download.
- Whether a newly captured image becomes visible immediately, after a delay, or only after mode change.
- Whether GM1S exposes `.RW2` using `CAM_RAW` / `CAM_RAW_JPG`.
- Whether `CAM_ORG` is byte-for-byte identical to the SD-card JPEG.
- Whether physical shooting can continue while a connected client polls state.

## Protocol references

The current implementation is based on behavior independently implemented/reverse-engineered in:

- libgphoto2 Lumix Wi-Fi backend: `gphoto/libgphoto2`, `camlibs/lumix/lumix.c`
- `peci1/lumix-link-desktop` (GM1 listed as tested / mostly compatible)
- Panasonic Image App documentation for GM1S Wi-Fi and geotagging behavior
- Panasonic/Lumix UPnP device descriptions showing `ContentDirectory:1` and `CDS_control`

The protocol is unofficial and Panasonic may vary behavior between models/firmware versions. This project therefore treats all responses as data to inspect rather than assuming newer Lumix behavior is identical to GM1S.

## Next milestone

Once the probe results are known, replace the diagnostic UI with three production modules:

- **Camera browser/importer:** thumbnails, original JPEG/RAW transfer, deduplication, Apple Photos import.
- **Auto Import:** foreground new-media detection and transfer using the least disruptive state transition proven by the GM1S test.
- **Geotag logger:** Core Location track recording, camera-clock calibration, timestamp interpolation, and Photos `CLLocation` assignment without modifying the downloaded original file bytes.
