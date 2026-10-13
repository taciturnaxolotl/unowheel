<p align="center"><img src="docs/images/icon.png" width="128" alt="UnoWheel icon: a Onewheel in profile" /></p>

# unowheel

An iOS app for the Onewheel. It unlocks the board over Bluetooth on its own, shows live ride data, and puts your battery on the home screen, the lock screen and the Dynamic Island.

The canonical repo for this is hosted on tangled over at [`https://tangled.org/dunkirk.sh/unowheel`](https://tangled.org/dunkirk.sh/unowheel)

## Layout

| Path | What it is |
| --- | --- |
| `OnewheelKit/` | Swift package with the protocol: GATT map, telemetry decoding, the handshake, and a PacketLogger `.pklg` reader. No UI. |
| `ios/` | The app and its widget extension. `project.yml` is the source of truth; the Xcode project is generated from it. |
| `tools/icon.swift` | Draws the app icon (light, dark and tinted). Run `swift tools/icon.swift` from the repo root. |
| `tools/ow_unlock.py` | Python and bleak probe for poking a board from a Mac. |
| `docs/protocol.md` | Protocol notes: what was measured, what was decompiled, and what is still unknown. |

## Building

```sh
cd OnewheelKit && swift test          # protocol tests, including the real capture if it's in ~/Downloads
cd ios && xcodegen generate           # after editing project.yml
open ios/UnoWheel.xcodeproj           # run on a real phone; the simulator has no Bluetooth
```

## Unlocking a board

Boards on firmware 4141 and up, which includes every Pint, only accept a response that Future Motion's server issues once per board. The board's challenge never changes, so you only need that response once:

1. Record the official app connecting to the board, using the iOS Bluetooth logging profile and PacketLogger.
2. In UnoWheel, connect to the board and choose **Import PacketLogger capture**. Or paste the 40 hex characters yourself.
3. UnoWheel keeps the response in the Keychain and unlocks the board by itself from then on.

Why not sign in with a Future Motion account and fetch the response directly? The official app sends the challenge to Future Motion's servers, and the answer comes back as a Firebase push notification sent to Future Motion's own Firebase project. A third-party app can't receive those pushes, so the one-time capture is the dependable route. See `docs/protocol.md`.

## Riding

- **Auto-connect:** UnoWheel asks iOS to connect to your last board whenever it's in range. The request never expires, so switching the board on with your phone in your pocket is enough. Turn it off from the board screen's menu. Disconnecting by hand pauses it until you pick a board again.
- **Range:** "x mi left" on the dashboard, the widgets and the lock screen. It starts from Future Motion's rated range, then learns how many watt-hours per mile you use (power x time over distance, regen counted at a quarter) and estimates from the energy left in the pack. What it has learned is kept per board.

## Widgets

- **Board battery:** small and medium home screen widgets, plus circular, rectangular and inline lock screen widgets. They show the last values the app saw, including range.
- **Ride Live Activity:** on the lock screen and in the Dynamic Island. Shows ride state (riding, regen, stopped), speed, battery bar, range, ride time, trip, top speed and mode. iOS only lets apps start Live Activities from the foreground, so after a background auto-connect it appears next time you open UnoWheel.

The app and the widgets share data through the `group.sh.dunkirk.unowheel` App Group.

<p align="center">
    <img src="https://raw.githubusercontent.com/taciturnaxolotl/carriage/main/.github/images/line-break.svg" />
</p>

<p align="center">
    <i><code>&copy; 2026-present <a href="https://dunkirk.sh">Kieran Klukas</a></code></i>
</p>

<p align="center">
    <a href="https://tangled.org/dunkirk.sh/unowheel/blob/main/LICENSE.md"><img src="https://img.shields.io/static/v1.svg?style=for-the-badge&label=License&message=MIT&logoColor=d9e0ee&colorA=363a4f&colorB=b7bdf8"/></a>
</p>
