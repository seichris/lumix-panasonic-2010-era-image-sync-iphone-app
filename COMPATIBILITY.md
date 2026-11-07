# Retro LUMIX Sync camera candidates

Retro LUMIX Sync is being validated on GM-family hardware first. The wider list below is a research and testing queue, not a claim of confirmed support.

Panasonic lists these system and compact cameras in its Image App ecosystem. That makes them plausible candidates for the same broad local Wi-Fi, `cam.cgi`, UPnP ContentDirectory, and HTTP media-resource architecture, but authentication and individual commands can vary by firmware and model.

The dates are approximate model-introduction eras derived from Panasonic's Image App support history. They are not exact manufacturing start/end dates.

## GM family: approximately 2013–2014

| Camera | Approximate era | Current confidence |
|---|---:|---|
| Panasonic DMC-GM1 | 2013 | Closest candidate |
| Panasonic DMC-GM1S | 2014 | Primary test target |
| Panasonic DMC-GM5 | 2014 | Closest candidate |

## Early system cameras: approximately 2013–2015

| Camera | Approximate era | Current confidence |
|---|---:|---|
| Panasonic DMC-GF6 | 2013 | Strong candidate |
| Panasonic DMC-G6 | 2013 | Strong candidate |
| Panasonic DMC-GX7 | 2013 | Strong candidate |
| Panasonic DMC-GH4 | 2014 | Strong candidate |
| Panasonic DMC-GF7 | 2015 | Strong candidate |
| Panasonic DMC-G7 / G70 | 2015 | Strong candidate |
| Panasonic DMC-GX8 | 2015 | Strong candidate |

## Mature system cameras: approximately 2016–2019

| Camera | Approximate era | Current confidence |
|---|---:|---|
| Panasonic DMC-GF8 | 2016 | Image App candidate |
| Panasonic DMC-GX80 / GX85 | 2016 | Image App candidate |
| Panasonic DMC-G80 / G81 / G85 | 2016 | Image App candidate |
| Panasonic DC-GF9 / GX800 / GX850 | 2017 | Image App candidate |
| Panasonic DC-GH5 | 2017 | Image App candidate |
| Panasonic DC-G9 | 2017 | Image App candidate |
| Panasonic DC-GH5S | 2018 | Image App candidate |
| Panasonic DC-GF10 | 2018 | Image App candidate |
| Panasonic DC-GX9 | 2018 | Image App candidate |
| Panasonic DC-G90 / G91 / G95 / G95D | 2019 onward | Later, unverified candidate |

## Early compact cameras: approximately 2013–2015

| Camera | Approximate era | Current confidence |
|---|---:|---|
| Panasonic DMC-FT5 / TS5 | 2013 | Image App candidate |
| Panasonic DMC-TZ40 / TZ41 / TZ37 / ZS30 / ZS27 | 2013 | Image App candidate |
| Panasonic DMC-SZ9 | 2013 | Image App candidate |
| Panasonic DMC-LF1 | 2013 | Strong candidate |
| Panasonic DMC-TZ60 / TZ61 / ZS40 / SZ8 | 2014 | Image App candidate |
| Panasonic DMC-TZ55 / TZ56 / ZS35 | 2014 | Image App candidate |
| Panasonic DMC-FZ1000 | 2014 | Strong candidate |
| Panasonic DMC-LX100 | 2014 | Strong candidate |
| Panasonic DMC-TZ70 / TZ71 / ZS50 | 2015 | Image App candidate |
| Panasonic DMC-TZ57 / TZ58 / ZS45 | 2015 | Image App candidate |
| Panasonic DMC-SZ10 | 2015 | Image App candidate |
| Panasonic DMC-FT6 / TS6 | 2015 | Image App candidate |
| Panasonic DMC-FZ300 / FZ330 | 2015 | Image App candidate |

## Later compact cameras: approximately 2016–2019

| Camera | Approximate era | Current confidence |
|---|---:|---|
| Panasonic DMC-TZ100 / TZ101 / TZ110 / ZS100 / ZS110 | 2016 | Image App candidate |
| Panasonic DMC-TZ80 / TZ81 / ZS60 | 2016 | Image App candidate |
| Panasonic DMC-FZ2000 / FZ2500 | 2016 | Image App candidate |
| Panasonic DMC-LX9 / LX10 / LX15 | 2016 | Image App candidate |
| Panasonic DC-FZ80 / FZ82 | 2017 | Image App candidate |
| Panasonic DC-TZ90 / TZ91 / TZ92 / TZ93 / ZS70 | 2017 | Image App candidate |
| Panasonic DC-TZ200 / TZ200D / TZ202 / TZ202D / TZ220 / TZ220D / ZS200 / ZS200D / ZS220 / ZS220D | 2018 | Later, unverified candidate |
| Panasonic DC-FT7 / TS7 | 2018 | Later, unverified candidate |
| Panasonic DC-LX100M2 | 2018 | Later, unverified candidate |
| Panasonic DC-FZ1000M2 / FZ10002 | 2019 | Later, unverified candidate |
| Panasonic DC-TZ95 / TZ95D / TZ96 / TZ96D / TZ97 / ZS80 / ZS80D | 2019 onward | Later, unverified candidate |

## Recent Image App compact cameras: approximately 2025–2026

These are included for completeness because Panasonic still lists them with Image App. Retro LUMIX Sync does not assume that they expose the legacy protocol.

| Camera | Approximate era | Current confidence |
|---|---:|---|
| Panasonic DC-TZ99 / ZS99 | 2025 | Later, unverified candidate |
| Panasonic DC-TZ300 / ZS300 | 2026 | Later, unverified candidate |

## Remote shooting validation

Remote shooting is built from the Image App protocol as documented by libgphoto2, lumix-link-desktop, and GX80 captures, and is covered by unit tests, a scripted camera, and the simulator. It was then checked on a DMC-GM1S (firmware 2.70, protocol 1.4, menu set 2.0) with a 15 mm f/1.7 lens and an iPhone 16 Pro Max, joined through Image App → Direct.

| Behavior | Status |
|---|---|
| `req_acc` reply and any approval prompt on the camera | GM1S answers `err_non_support`; no prompt appears |
| Record-mode switch and UDP live view (header layout, AF frames, readout) | Works on GM1S: 17–24 KB frames with a 149-byte header extension carrying the AF frame and exposure |
| Remote shutter and card-write confirmation | Works on GM1S |
| Touch AF and touch shutter | Work on GM1S |
| Video start/stop and the elapsed time | Works on GM1S (`rec` and `progress_time` in `getstate`) |
| `getinfo&type=allmenu`/`curmenu` availability | Both available on GM1S |
| ISO, exposure compensation (`menu_item_id_exposure2`), white balance | Work on GM1S |
| Shutter and aperture chosen by the camera (P) | GM1S `getsetting` reports the stored S/M value; the app shows the live readout instead |
| Focus mode | Read-only on GM1S: not in its remote menu |
| Background and return-to-gallery transitions | Work on GM1S |
| HTTP 503 right after the app relaunches | GM1S answered 503 for about 10 seconds (once for over a minute); remote shooting waits for it |
| Burst while holding the shutter | Not available this way on GM1S: it answered `ok` to Burst L (`setsetting drivemode=burst`, `value2=l`) but stayed in single shot, so a held shutter took one frame. The app now says when a camera keeps its old value. Other burst speeds, and burst set on the camera body, are untested. |
| Physical shutter use and playback button while connected | Work on GM1S: a photo taken with the camera's shutter lowers the remaining count without an app command and live view keeps running. The playback button switches the camera to playback (`cammode` `play`); the app pauses and restarts live view when the camera returns to recording |
| AF area and peaking | Work on GM1S (1-Area and peaking Low applied and read back) |
| Manual-focus feedback | Partly checked on GM1S: with the lens set to MF the camera reports `mf` and answers `camctrl focus` steps with a position (`ok,139,1024`), but the position did not change, so focus movement is unverified. Touch shutter in MF captures without an AF point |
| Aperture and shutter in A/S/M | Work on GM1S: each mode is recognized from `curmenu`, and aperture (`focal`) and shutter (`shtrspeed`) values are accepted and read back. In M, `getinfo&type=lens` reports `16384/256` (Bulb) as the slowest shutter speed; the app keeps the timed speeds down to 60 s and does not offer Bulb |
| Reconnect after the camera's Wi‑Fi drops | Needs GM1S validation |
| Power zoom | Needs validation with a power-zoom lens |

## Location writing and clock validation

Location writing follows Panasonic's documented GM1S workflow and the command sequence recovered from Image App. Besides a scripted camera, it was run on a DMC-GM1S (firmware 2.70) on 7 November 2026, with the photos read back from the card afterwards. On a physical camera, use a disposable or backed-up SD card when trying it for the first time:

| Behavior | Status |
|---|---|
| Capability report (`geotag_add_enable` or protocol 1.3+) | GM1S firmware 2.70 reports protocol 1.4 and does not list `geotag_add_enable` |
| Capture times of the card's photos | The GM1S media list has none; the app reads them from the originals' EXIF before a write |
| `getsetting&type=clock` | GM1S answers `err_non_support`: its clock cannot be read over Wi‑Fi |
| `setsetting&type=clock` | Works on GM1S with UTC fields plus the standard offset: a photo taken 38 s later carried the iPhone's local time to the second (the camera had been 22 s fast) |
| `%2B` versus raw `+` in clock values | GM1S accepts `%2B` in both `setsetting` and `notify` |
| Daylight-saving handling of both clock commands | Needs validation in a time zone with daylight saving |
| Track upload accepted (`startsenddata`, multipart `senddata`) | Works on GM1S: `startsenddata` answers `<method>once</method>` and a `bufsize` of 9600008; the multipart POST is accepted |
| Progress | GM1S reports `prepare` → `exec` → `finish` within about 3 s |
| Abort and interruption | Needs GM1S validation |
| GPS written into JPEGs inside the period; none outside it; existing GPS kept | Verified on GM1S by reading the originals back with a separate EXIF parser. Photos inside the period gained GPS from a track sample taken shortly before each photo; photos before and after the period gained none; a second write left existing GPS byte-identical |
| GPS date field | GM1S writes `GPSDateStamp` as 11 bytes ending in `0x02` instead of a terminating zero |
| Many photo reads in a row | Reads that took the first 512 KiB of an original and then dropped the connection: after about 150 in 20 minutes the GM1S answered HTTP 404 for every original, then stopped answering until it was switched off and on. With `Range: bytes=0-524287` the GM1S answers `206 Partial Content` and ends each transfer itself; after a restart it served 200 such reads in a row and kept answering. The app now asks for the range, reads as few photos as it can, and stops after two failed reads |
| RAW and RAW+JPEG files | Unverified; not claimed |

## Send Images While Recording validation

The receiver follows Shutterlink's GM1/G85-tested exchange and has been verified with unit tests, a loopback TCP test, and a scripted camera in the simulator. On a physical DMC-GM1S it still needs:

| Behavior | Status |
|---|---|
| Camera discovers the phone through unicast SSDP alone (no multicast entitlement) | Needs GM1S validation |
| Camera discovers the phone through multicast | Needs the multicast entitlement, then GM1S validation |
| Description, upload-profile, `CreateObject`, and chunked upload exchange | Needs GM1S validation |
| Size → Original transfers byte-identical to the card's JPEG | Needs GM1S validation |
| Smaller transfer sizes are not treated as originals | Needs GM1S validation |
| Burst, app switch, iPhone lock, and camera Wi-Fi interruptions | Needs GM1S validation |

## Confirmation standard

A camera should only move from candidate to confirmed after a real-device run records:

1. Reported camera model and firmware.
2. Successful `getstate` or a documented media-server-only path.
3. Successful ContentDirectory browse.
4. An advertised original JPEG resource.
5. A complete original download.
6. Whether browsing and downloading work in record and playback modes.

Source: [Panasonic Image App applicable models and support history](https://av.jpn.support.panasonic.com/support/global/cs/soft/image_app/).

Panasonic, LUMIX, and the camera model names belong to their respective owner. Retro LUMIX Sync is independent software and is not affiliated with or endorsed by Panasonic.
