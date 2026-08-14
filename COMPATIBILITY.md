# GM1 Sync camera candidates

GM1 Sync is being validated on GM-family hardware first. The wider list below is a research and testing queue, not a claim of confirmed support.

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

These are included for completeness because Panasonic still lists them with Image App. GM1 Sync does not assume that they expose the legacy protocol.

| Camera | Approximate era | Current confidence |
|---|---:|---|
| Panasonic DC-TZ99 / ZS99 | 2025 | Later, unverified candidate |
| Panasonic DC-TZ300 / ZS300 | 2026 | Later, unverified candidate |

## Confirmation standard

A camera should only move from candidate to confirmed after a real-device run records:

1. Reported camera model and firmware.
2. Successful `getstate` or a documented media-server-only path.
3. Successful ContentDirectory browse.
4. An advertised original JPEG resource.
5. A complete original download.
6. Whether browsing and downloading work in record and playback modes.

Source: [Panasonic Image App applicable models and support history](https://av.jpn.support.panasonic.com/support/global/cs/soft/image_app/).

Panasonic, LUMIX, and the camera model names belong to their respective owner. GM1 Sync is independent software and is not affiliated with or endorsed by Panasonic.
