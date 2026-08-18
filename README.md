# GM1 Sync

[![Download GM1 Sync on the App Store](https://tools.applemediaservices.com/api/badges/download-on-the-app-store/black/en-us?size=250x83)](https://geo.itunes.apple.com/app/id6801485290)

GM1 Sync is an independent iPhone and Mac app for browsing, importing, and geotagging media from compatible Panasonic Wi-Fi cameras. It is an alternative to Panasonic's **Image App** for people who still use these cameras.

The Panasonic Lumix DMC-GM1S is the primary camera validated on real hardware. The GM1, GM5, and other Image App-era Panasonic Lumix cameras from roughly the 2010s may use a compatible protocol, but model and firmware support must be verified individually. See [COMPATIBILITY.md](COMPATIBILITY.md).

GM1 Sync is not affiliated with or endorsed by Panasonic. Panasonic, LUMIX, Image App, and the camera model names belong to their respective owners.

## Features

- Connect by scanning the camera's Wi-Fi QR code or entering its Wi-Fi name and password.
- Browse photos and videos stored on the camera.
- Preview photos and play camera-provided MP4 videos.
- Import JPEG, JPEG + RAW, RAW-only, and supported MP4 originals into Apple Photos on iPhone.
- Mark previously imported items by reconciling camera filenames with the Photos library.
- Download all new photos and videos in one action.
- Record an optional on-device location track and add a matched location during photo import.
- On Mac, join the camera Wi-Fi from the macOS menu bar, run the protocol probes, and copy downloaded originals to Downloads.
- Keep camera traffic local between the iPhone and the camera, without accounts, analytics, ads, or cloud uploads.

AVCHD items can appear in the gallery when advertised by the camera. The tested GM1S advertises an AVCHD `.TS` URL that its media server does not serve, so AVCHD playback and import are shown as unavailable rather than promised as supported.

## Connect a GM1S

On the camera choose:

```text
Wi-Fi → New Connection → Remote Shooting & View → Direct → Image App
```

Join the Wi-Fi network shown by the camera using GM1 Sync's QR scanner or manual Wi-Fi form. This one **Image App Direct** connection is sufficient for browsing previews and importing supported originals; do not switch to **Send Images Stored in the Camera**.

## Confirmed GM1S protocol

Real-device testing confirms that GM1 Sync can:

- reach the camera's local `cam.cgi` control endpoint;
- switch the camera into playback mode;
- enumerate SD-card items through UPnP `ContentDirectory:1`;
- load `CAM_TN` and `CAM_LRGTN` previews;
- download original JPEG and RAW resources advertised by the camera;
- import supported MP4 resources; and
- save supported originals to Apple Photos.

The protocol is unofficial and can vary by camera model and firmware.

## Geotagging

Location logging is optional and visible while active. During import, GM1 Sync reads the original JPEG's EXIF capture time and matches it to a nearby or interpolated point in the locally stored location track. A camera-clock adjustment can compensate when the camera clock differs from the iPhone clock.

Matches more than 15 minutes from a usable track point are rejected. The original camera file remains unchanged; on iPhone the matched `CLLocation` is supplied separately when the asset is created in Apple Photos. On Mac the match is shown for review while the original is copied unchanged to Downloads.

## Privacy

GM1 Sync has no accounts, advertising, analytics, tracking, or cloud service. Camera credentials are stored in the platform Keychain and are not written to diagnostics. Location tracks and camera diagnostics remain on the device or Mac. See [PRIVACY.md](PRIVACY.md) for details.

## Build and test

The project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
xcodegen generate
open LumixProbe.xcodeproj
```

Select your own Apple development team in Xcode before installing on a physical iPhone. If you are not signing for the published app, also replace the bundle identifiers with identifiers owned by your team. A physical device is required to validate Hotspot Configuration, camera networking, Photos import, and real-camera protocol behavior. Unit and simulator UI tests can run without a camera.

The generated project also contains a native `GM1SyncMac` target. Build it with:

```bash
xcodebuild -project LumixProbe.xcodeproj -scheme GM1SyncMac -sdk macosx build
```

On Mac, join the camera Wi-Fi from the macOS menu bar before launching GM1 Sync. The Mac app uses the same camera address and protocol probe as iPhone, but does not use iPhone-only QR scanning or hotspot configuration. The **Download first original JPEG** action copies the camera bytes to the Mac user's Downloads folder instead of importing them into Apple Photos. Location logging works while the Mac app is open; iPhone continues to support visible background location logging and direct Photos import.

## Protocol notes

Camera control uses local HTTP endpoints such as:

```text
GET http://192.168.54.1/cam.cgi?mode=getstate
GET http://192.168.54.1/cam.cgi?mode=camcmd&value=playmode
GET http://192.168.54.1/cam.cgi?mode=get_content_info
```

Media enumeration uses a UPnP `ContentDirectory:1` SOAP request. Returned DIDL-Lite items may expose multiple resources for one camera item. GM1 Sync groups them by item ID and resolves profiles according to their purpose:

| Purpose | Preferred profiles |
|---|---|
| Grid thumbnail | `CAM_TN`, then `CAM_LRGTN` |
| Detail preview | `CAM_LRGTN`, then `CAM_TN` |
| Original JPEG | `CAM_ORG`, then `CAM_RAW_JPG` |
| RAW companion | `CAM_RAW` |
| MP4 video | `CAM_MP4` and compatible MP4 resources |

Previews are cached in memory. Originals are downloaded on demand, handed to Photos unchanged, and removed from temporary app storage after the import attempt.

## Help and compatibility reports

- [Support and troubleshooting](SUPPORT.md)
- [Camera compatibility candidates](COMPATIBILITY.md)
- [Open a GitHub issue](https://github.com/seichris/lumix-panasonic-2010-era-image-sync-iphone-app/issues/new)

## Protocol references

The implementation draws on behavior independently implemented or reverse-engineered in:

- `gphoto/libgphoto2`, `camlibs/lumix/lumix.c`
- `peci1/lumix-link-desktop`
- Panasonic Image App documentation and support history
- Panasonic/Lumix UPnP device descriptions exposing `ContentDirectory:1`
