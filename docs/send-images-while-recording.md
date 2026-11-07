# Send Images While Recording

The camera's **Wi‑Fi → New Connection → Send Images While Recording → Smartphone** mode pushes each new JPEG to a phone as it is taken. Retro LUMIX Sync receives these photos in an explicit, foreground receiving session and saves each one to Apple Photos.

## How the camera finds the phone

In this mode the camera acts as a DLNA uploader. It looks for a UPnP MediaServer that advertises image upload, then works through these steps:

1. Read the server's device description (`/dms/ddd.xml`).
2. Ask which upload profiles it accepts (`X_GetDLNAUploadProfiles`).
3. Call `CreateObject` for each new JPEG.
4. POST the file, chunked, to the import URI that `CreateObject` returned.

Retro LUMIX Sync implements that server with the message shapes from [Shutterlink](https://github.com/KerbalNo15/Shutterlink), which its author tested on a GM1 and a G85. The GM1S has not been tested yet.

The receiver:

- accepts connections only from the camera's address;
- writes each upload to a temporary file while hashing it;
- accepts a file only when the body is complete, the JPEG ends with its end-of-image marker, and the camera's announced size, if any, matches;
- keeps the file on the iPhone until Photos has saved it, and only then reports it as saved;
- drops repeated deliveries of the same bytes (SHA-256).

The camera decides how large a JPEG it sends: choose **Size → Original** in its image settings. A received JPEG is treated as the card original only after a gallery import has compared it with the file on the card. If the two are byte-identical, the import records the original as imported without saving a second copy.

## Discovery and the multicast entitlement

Shutterlink announces the receiver with SSDP multicast `NOTIFY` messages to `239.255.255.250:1900` and listens for the camera's multicast searches.

On iOS, an app needs the [`com.apple.developer.networking.multicast`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast) entitlement to send or receive any IP multicast or broadcast. Apple grants it on request.

**The current provisioning profiles for `com.web3.gm1sync` do not include it.** I checked the App Store, Ad Hoc, and Team profiles installed on this Mac: they contain Hotspot Configuration and App Groups only.

Until Apple grants the entitlement, Retro LUMIX Sync sends the same `NOTIFY` messages and an `M-SEARCH` as **unicast to the camera's SSDP port** (`192.168.54.1:1900`). That needs no entitlement. The camera's SSDP stack listens on that port, but whether it accepts unicast announcements is **not yet verified on hardware**.

The app also tries multicast. When iOS refuses it, the receiving screen shows "Multicast: blocked", and receiving continues through the unicast path.

### Account-owner action (Apple Developer Program Account Holder)

1. Submit the request at <https://developer.apple.com/contact/request/networking-multicast> while signed in as the team's **Account Holder** (team `4H5PK8686H`).
2. Suggested answers:
   - **App:** Retro LUMIX Sync, bundle ID `com.web3.gm1sync` (iOS).
   - **Why multicast is needed:** Panasonic LUMIX cameras from about 2013–2019 (DMC‑GM1, GM1S, G85, and others) can push each photo to a smartphone as it is taken ("Send Images While Recording"). The camera finds the phone with UPnP/SSDP. The phone must announce a DLNA MediaServer by sending SSDP `NOTIFY` messages to `239.255.255.250:1900`, and must answer the camera's SSDP `M-SEARCH` on that group. The traffic stays on the camera's own Wi‑Fi network (the camera is the access point at 192.168.54.1). It starts only while the user has started a receiving session, and it stops when they stop it.
   - **Protocols and addresses:** SSDP over UDP to `239.255.255.250:1900` (send and receive), plus HTTP over TCP for the uploads.
3. After approval:
   1. In Certificates, Identifiers & Profiles, open the App ID `com.web3.gm1sync`, enable **Multicast Networking** under Additional Capabilities, and regenerate or refresh the development and distribution profiles.
   2. In `project.yml`, uncomment `com.apple.developer.networking.multicast: true` under the `GM1Sync` entitlements, then run `xcodegen generate`.

   The line stays commented until then because a build that requests an entitlement missing from its profile cannot be signed for a device.

## Foreground-only behavior

iOS suspends the app when it leaves the foreground or the iPhone locks, and the receiver cannot accept uploads while suspended. Receiving is therefore an explicit session on a full-screen page that keeps the screen awake.

When the app leaves the foreground, the session closes its sockets and shows **Paused**. It does not send `ssdp:byebye`, so the camera keeps its cached description. On return it reopens on the same port when possible and announces itself again.

The camera's behavior while the phone is away still needs hardware confirmation: does it retry the failed send, skip it, or stop the connection? A photo the camera could not send remains on the card and can be imported from the gallery later.

## Hardware acceptance (not yet run)

1. On the camera choose **MENU → Wi‑Fi → Wi‑Fi Function → New Connection → Send Images While Recording → Smartphone → Direct → Manual Connection**. On the iPhone, open Retro LUMIX Sync and choose **Receive photos while shooting → Start receiving**, then join the camera's network.
2. Confirm the camera lists "Retro LUMIX Sync". Note whether this happens with the unicast path alone, so before the entitlement is granted. Select it, set **Size → Original**, and press **Set**.
3. Take single shots and a burst. Each JPEG must appear as **Saved to Photos**.
4. Compare the received files with the SD-card originals:
   - In the gallery, import the same photos. The import must report them as already received (no duplicate in Photos) when the bytes match.
   - Also compare the SHA-256 of the files read from the card in a card reader with the files exported from Photos.
   - Repeat with a smaller transfer size and confirm those transfers are not treated as originals.
5. Interruptions:
   - Switch apps during a burst and lock the iPhone, then return. Record what the camera reports and what arrives.
   - Turn the camera's Wi‑Fi off and on.
   - Deny Photos access, then grant it and use **Try saving again**.
6. RAW+JPEG: confirm only the JPEG is sent.
