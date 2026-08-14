# GM1 Sync

GM1 Sync is an independent iPhone app for browsing, transferring, and geotagging photos from older Panasonic Wi-Fi cameras. The Panasonic DMC-GM1S is the primary validated camera; the GM1, GM5, and other Image App-era models remain candidates until tested on hardware. See [COMPATIBILITY.md](COMPATIBILITY.md).

## The one camera mode to use

On the GM1S choose:

```text
Wi-Fi → New Connection → Remote Shooting & View → Direct → Image App
```

Join the SSID shown by the camera from GM1 Sync's QR scanner, its manual network form, or iPhone Wi-Fi Settings.

That single Image App Direct network is enough for the intended workflow. With the camera in this connection mode, GM1 Sync can reach `cam.cgi`, switch the camera into playback state, enumerate the SD card, load previews, and download original JPEGs. Do not switch to **Send Images Stored in the Camera** or another Wi-Fi destination for browsing or transfer.

## Current app flow

1. The app checks for the camera at `192.168.54.1`.
2. If it is unreachable, it shows the exact camera steps plus QR and manual Wi-Fi joining.
3. Once connected, the app enters playback mode and opens the photo browser.
4. The newest 20 items load first; scrolling or **Load all photos** pages through the full card.
5. Lightweight `CAM_TN`/`CAM_LRGTN` resources populate a lazy grid and detail preview.
6. A single original or a selection can be imported sequentially into Apple Photos.
7. Each transfer has its own downloading, saving, saved, or failed state; one failure does not stop a batch.
8. Foreground refresh and Retry recover after camera sleep, battery replacement, app relaunch, or Wi-Fi reconnection.

Protocol diagnostics remain available under **Settings → Camera diagnostics**.

## Confirmed on DMC-GM1S

The initial hardware session established:

- Camera address `192.168.54.1`, firmware `D2.70`.
- `/cam.cgi?mode=getstate` works in Image App Direct mode.
- `get_content_info` and ContentDirectory browsing work in playback mode.
- Record mode reports busy for content info and does not support the browse workflow.
- The SD card reported 81 items.
- ContentDirectory advertised `CAM_TN`, `CAM_LRGTN`, `CAM_RAW_JPG`, and `CAM_RAW` resources.
- The legacy port-50001 server accepts the app's deliberately small HTTP/1.0 downloader.
- A 6,455,292-byte, 4592 × 3448 `CAM_RAW_JPG` original was downloaded completely, identified as a Panasonic DMC-GM1S JPEG, and saved to Photos.

This confirms that browsing and original transfer do not require two camera Wi-Fi modes. Remaining hardware acceptance checks are listed in [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md).

## Protocol shape

Camera control uses local HTTP endpoints such as:

```text
GET http://192.168.54.1/cam.cgi?mode=getstate
GET http://192.168.54.1/cam.cgi?mode=camcmd&value=playmode
GET http://192.168.54.1/cam.cgi?mode=get_content_info
```

Media enumeration uses a UPnP `ContentDirectory:1` SOAP request at:

```text
http://192.168.54.1:60606/Server0/CDS_control
```

The request uses `BrowseDirectChildren`, `ObjectID=0`, paging fields, and Panasonic's control-point marker:

```xml
<pana:X_FromCP>LumixLink2.0</pana:X_FromCP>
```

Returned DIDL-Lite items expose several resources for one camera item. GM1 Sync groups them by item ID and resolves profiles in this order:

| Purpose | Preferred profiles |
|---|---|
| Grid thumbnail | `CAM_TN`, then `CAM_LRGTN` |
| Detail preview | `CAM_LRGTN`, then `CAM_TN` |
| Original JPEG | `CAM_ORG`, then `CAM_RAW_JPG` |
| RAW companion | `CAM_RAW` |

Only previews are cached in memory. Originals are downloaded on demand, handed to Photos unchanged, and removed from temporary app storage after the import attempt.

## Geotagging

Location logging begins only when the user taps **Start location log**. The visible session can continue while the iPhone is locked. On import, GM1 Sync reads the original JPEG's EXIF capture time and matches it to a nearby or interpolated track point. A camera-clock adjustment can correct a camera that is ahead or behind the iPhone.

Matches more than 15 minutes from a usable track point are rejected. Apple Photos receives the original camera file as its unadjusted resource and the matched `CLLocation` as asset metadata; the JPEG bytes and camera SD card are not modified.

## QR handling

The scanner supports standard `WIFI:` QR payloads and URL payloads containing an SSID and password. Unsupported older Panasonic payloads are reported with a short SHA-256-derived reference and byte length; the payload and password are never logged. The app immediately offers manual SSID/password entry as a fallback.

The proprietary QR printed by the physical GM1S still needs one recorded scan before the project can claim native support for that exact payload format.

## Build and test

The project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
xcodegen generate
open LumixProbe.xcodeproj
```

The app, unit tests, and UI tests use the WEB3 development team `4H5PK8686H` and bundle ID `com.web3.gm1sync`.

Unit and simulator UI tests can run without a camera. The UI suite uses an explicit connected-gallery fixture for gallery navigation and skips only the end-to-end protocol test on Simulator. A physical iPhone is required for Hotspot Configuration, local-camera networking, Photos import, and the remaining hardware acceptance checks.

## Scope

The current browser imports original JPEGs. It identifies `CAM_RAW` companions but does not yet export or decode RAW files. Cloud sync, video transfer, background local-network import while iOS suspends the app, and continuous auto-import are outside this branch.

The protocol is unofficial and can vary by camera and firmware. Panasonic, LUMIX, and the model names belong to their owner; GM1 Sync is not affiliated with or endorsed by Panasonic.

## Protocol references

The implementation draws on behavior independently implemented or reverse-engineered in:

- `gphoto/libgphoto2`, `camlibs/lumix/lumix.c`
- `peci1/lumix-link-desktop`
- Panasonic Image App documentation for GM1S Wi-Fi and geotagging
- Panasonic/Lumix UPnP device descriptions exposing `ContentDirectory:1`
