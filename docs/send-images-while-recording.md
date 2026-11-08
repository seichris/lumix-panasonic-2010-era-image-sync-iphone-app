# Send Images While Recording

The camera's **Wi‑Fi → New Connection → Send Images While Recording → Smartphone** mode pushes each new JPEG to a phone as it is taken. Retro LUMIX Sync receives these photos in an explicit, foreground receiving session and saves each one to Apple Photos.

## How the camera finds the phone

In this mode the camera acts as a DLNA uploader. It looks for a UPnP MediaServer that advertises image upload, then works through these steps:

1. Read the server's device description (`/dms/ddd.xml`).
2. Ask which upload profiles it accepts (`X_GetDLNAUploadProfiles`).
3. Call `CreateObject` for each new JPEG.
4. POST the file, chunked, to the import URI that `CreateObject` returned.

Retro LUMIX Sync implements that server with the message shapes from [Shutterlink](https://github.com/KerbalNo15/Shutterlink), which its author tested on a GM1 and a G85. It has been verified on a DMC-GM1S (see [Hardware results](#hardware-results-dmc-gm1s)).

The receiver:

- accepts connections only from the camera's address;
- writes each upload to a temporary file while hashing it;
- accepts a file only when the body is complete, the JPEG ends with its end-of-image marker, and the camera's announced size, if any, matches;
- keeps the file on the iPhone until Photos has saved it, and only then reports it as saved;
- drops repeated deliveries of the same bytes (SHA-256).

The camera decides how large a JPEG it sends: choose **Size → Original** in its send settings. A received JPEG is treated as the card original only after a gallery import has compared it with the file on the card. If the two are byte-identical, the import records the original as imported without saving a second copy.

### The exchange a GM1S uses

Recorded on 2026-11-08 with a DMC-GM1S (firmware 2.70) and an iPhone 16 Pro Max on iOS 27.2:

1. Once the iPhone has joined the camera's network, the camera sends an SSDP `M-SEARCH` to the multicast group `239.255.255.250:1900` with `ST: urn:schemas-upnp-org:device:MediaServer:1` and `MX: 5`. The app answers it with a unicast search response.
2. Within about 15 ms the camera reads `/dms/ddd.xml`. Its request carries `Accept-Language: ja` and `X-Panasonic-Registration: RE1DLUdNMVM=`, which is Base64 for `DMC-GM1S`.
3. The camera lists "Retro LUMIX Sync". After it is selected, the camera calls `X_GetDLNAUploadProfiles` and offers `JPEG_SM`, `JPEG_MED`, `JPEG_LRG`, `PANASONIC.COM_PN=MPO`, `AVC_MP4_BL_L31_HD_AAC`, and `AVC_MP4_MP_HD_1080i_AAC`. The app answers `JPEG_LRG`, and the camera shows its send settings (Size, File Format, Delete Location Data).
4. For each photo the camera calls `CreateObject`. The DIDL-Lite item's title is the card file name without its extension plus a four-digit counter for the connection: `P1290930.JPG` arrives as `P12909300001`. The `res` element gives the size and resolution, and `dc:date` is the camera's local time when it starts sending.
5. It then POSTs the JPEG with `Transfer-Encoding: chunked`, `Expect: 100-continue`, `transferMode.dlna.org: Background`, and `X-DLNAUploadExt2: 0`. Photos are sent one at a time; the next `CreateObject` follows about 1.5 s after an upload ends. A 6 MB original took 7 s (about 0.8 MB/s).

**Size → M** sent 3232 × 2424 JPEGs of about 2.9 MB. **Size → Original** sent the full 4592 × 3448 JPEG (5,959,680 bytes for the photo tested).

The access request Shutterlink sends (`mode=accctrl&type=req_acc`) is not needed on a GM1S. In its remote mode the camera answers `err_non_support`, and while it is sending images it accepts no connections on port 80 at all. The app still sends the request for cameras that answer it, and shows the result only when the camera accepts it or asks for approval.

## Discovery and the multicast entitlement

iOS documents the [`com.apple.developer.networking.multicast`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast) entitlement as required to send or receive IP multicast or broadcast. Apple grants it on request, and the provisioning profiles for `com.web3.gm1sync` do not include it.

What happened on the GM1S without it, on iOS 27.2 with a development-signed build:

- **Sending multicast is refused.** Every `NOTIFY` to `239.255.255.250:1900` fails with "No route to host". The receiving screen shows "Multicast sending: blocked by iOS".
- **The camera's multicast search still reached the app.** The receiver binds port 1900 and joins the SSDP group; the camera's `M-SEARCH` (and earlier its own `NOTIFY` messages) arrived there.
- **The answer needs no entitlement.** The search response goes to the camera's address and port as unicast. That is how the camera found Retro LUMIX Sync in every successful run.

The app also sends its `NOTIFY` messages and an `M-SEARCH` straight to the camera's SSDP port (`192.168.54.1:1900`) as unicast. There is no sign that the camera uses them: in its remote mode it answered the search with its own media server but never read the app's description, and while sending it did not answer them. Whether they prompt the camera's own search is unproven; they are cheap, so they stay.

Because Apple documents the entitlement for receiving too, check a TestFlight build with the camera before relying on this in a release. Requesting the entitlement remains a safeguard.

### Requesting the entitlement (Apple Developer Program Account Holder)

1. Submit the request at <https://developer.apple.com/contact/request/networking-multicast> while signed in as the team's **Account Holder** (team `4H5PK8686H`).
2. Suggested answers:
   - **App:** Retro LUMIX Sync, bundle ID `com.web3.gm1sync` (iOS).
   - **Why multicast is needed:** Panasonic LUMIX cameras from about 2013–2019 (DMC‑GM1, GM1S, G85, and others) can push each photo to a smartphone as it is taken ("Send Images While Recording"). The camera finds the phone with UPnP/SSDP: it sends an SSDP `M-SEARCH` to `239.255.255.250:1900`, and the phone must receive it and answer. The phone also announces its DLNA MediaServer with SSDP `NOTIFY` messages to that group. The traffic stays on the camera's own Wi‑Fi network (the camera is the access point at 192.168.54.1). It starts only while the user has started a receiving session, and it stops when they stop it.
   - **Protocols and addresses:** SSDP over UDP to `239.255.255.250:1900` (send and receive), plus HTTP over TCP for the uploads.
3. After approval:
   1. In Certificates, Identifiers & Profiles, open the App ID `com.web3.gm1sync`, enable **Multicast Networking** under Additional Capabilities, and regenerate or refresh the development and distribution profiles.
   2. In `project.yml`, uncomment `com.apple.developer.networking.multicast: true` under the `GM1Sync` entitlements, then run `xcodegen generate`.

   The line stays commented until then because a build that requests an entitlement missing from its profile cannot be signed for a device.

## Joining the camera's network

The camera searches for the app shortly after the iPhone joins its network. Joining from Settings sends Retro LUMIX Sync to the background, where it cannot answer.

In the first GM1S run, the camera showed **Connection failed**: it never searched after the app returned, and its network was gone within a minute of the iPhone joining. The second run, with the same steps, worked: the camera searched 6 s after the app came back. So: start receiving, join the network, and return to the app straight away. If the camera shows **Connection failed**, start its connection again while the receiving screen is open.

## Foreground-only behavior

iOS suspends the app when it leaves the foreground or the iPhone locks, and the receiver cannot accept uploads while suspended. Receiving is therefore an explicit session on a full-screen page that keeps the screen awake.

When the app leaves the foreground, the session closes its sockets and shows **Paused**. It does not send `ssdp:byebye`, so the camera keeps its cached description. On return it reopens on the same port when possible and announces itself again.

What the GM1S does while the app is away:

- **No photo taken:** the connection survives. After 1.5 minutes in the background, receiving resumed on the same port, and the next photo arrived.
- **A photo taken:** the camera cannot deliver it, ends the send connection, and shows **Connection error**. It does not retry when the app returns, and the photo stays on the card only. Start the camera's connection again, for example with **Wi‑Fi Function → Select a destination from History**, and import the missed photo from the gallery.

After returning, the receiving screen points this out until the camera sends again. When the camera turns its Wi‑Fi off, the session notices that the iPhone has left the network, waits for it, and announces itself again (with a new address, if the iPhone gets one).

## Hardware results (DMC-GM1S)

Verified on 2026-11-08 with a DMC-GM1S (firmware 2.70) and an iPhone 16 Pro Max on iOS 27.2:

- The camera found and listed Retro LUMIX Sync without the multicast entitlement.
- Four photos arrived and were saved to Photos: three at Size M and one at Size Original, each checked against its announced size and end-of-image marker first.
- Leaving the app without taking a photo kept the connection; a photo taken while the app was away ended it with **Connection error**.

Still to check:

1. Compare a Size → Original transfer with the card's file: import it from the gallery and confirm it is recorded without a second copy in Photos, and that M-size transfers are not treated as originals.
2. A burst at Size Original.
3. Lock the iPhone during a session, and turn the camera's Wi‑Fi off and on (the session should wait for the network and announce itself again).
4. Deny Photos access, then grant it and use **Try saving again**.
5. RAW+JPEG: confirm only the JPEG is sent.
6. A TestFlight build: confirm the camera's search still reaches the app without the multicast entitlement.
