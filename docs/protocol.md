# Onewheel BLE protocol notes

Working notes for the Pint on firmware 5208 ("Hydrus"). Each claim says where it came from. "Verified" means checked against source code; "unverified" means nobody here has seen it on 5208 yet.

## GATT layout

Service `e659f300-ea98-11e3-ac10-0800200c9a66`. Every characteristic is `e659fXXX-ea98-11e3-ac10-0800200c9a66`. Values are big-endian `u16` unless noted. (Source: kariudo/onewheel-bluetooth, OWCE.)

| XXX | Name | Notes |
| --- | --- | --- |
| 301 | serial number | |
| 302 | ride mode | `> 0` means the board is already unlocked (OWCE "jumpstart" check) |
| 303 | battery % | |
| 30b | rpm | |
| 310 | temperature | |
| 311 | firmware revision | read; also written back to itself as the trigger and keepalive |
| 318 | hardware revision | 3xxx Plus, 4xxx XR, 5xxx Pint, 6xxx GT, 7xxx Pint X |
| 3fe | UART read | notify, board to phone |
| 3ff | UART write | write, phone to board |

## Handshake

1. Subscribe to `3fe`.
2. Write the firmware revision bytes back to `311`.
3. The board sends 20 bytes over `3fe`, maybe split over several notifications:
   `43 52 58` ("CRX") + 16 byte nonce + 1 check byte (XOR of the first 19 bytes).
4. The phone writes 20 bytes to `3ff` in the same shape: `CRX` + 16 bytes + XOR check.
5. Write `311` to itself every 15 s, or the board locks again.

Verified against ponewheel `BluetoothUtilImpl.java`, OWCE `OWBoard.cs`, and onewheel-bluetooth `readdata.py`.

## The response, by firmware

- **fw 4034 to 4140 (Gemini).** Response body is `md5(nonce || D9255F0F23354E19BA739CCDC4A91765)`. Static key, computed locally. Verified.
- **fw 4141 and up (Pint, XR 4210 hardware).** No local key. The official app sends the nonce to Future Motion and writes back whatever it gets. OWCE called it like this, then removed the code in April 2023 (commit `2377ac9`, "Removed code to fetch token"):

  ```
  GET https://app.onewheel.com/wp-json/fm/v2/activation/{serial}?owType=pint&apiKey={nonce hex}
  -> {"key": "<40 hex chars, the full 20 byte response>"}
  ```

  `{serial}` is the BLE name without the `ow` prefix. Whether this endpoint still exists or what auth it needs now is unverified.
- **fw 4155 and up on XR.** OWCE warns that "some features" are locked down, without saying which.
- **fw 5208 (Hydrus).** Measured on ow292642 (Pint, hw 5314):
  - Writing `311` to itself still triggers the challenge, arriving as 20 bytes over 11 notifications of 1 to 3 bytes each.
  - There is no `CRX` header. The frame is 19 opaque bytes plus an XOR check byte, and the check still holds:
    `09 8e 56 e3 66 f5 ac aa bc 75 87 69 52 67 7d 0c cb 01 2d 23`
  - The challenge is the same on every connection, on repeated triggers within one connection, and across a power cycle. It is a fixed per-board value, not a nonce.
  - While locked, ride mode, battery, rpm, temperature and voltage all read 0.
  - The Gemini MD5 key does not unlock it. Five variants were rejected silently: no UART reply, and the stats stayed 0.
  - rewheel's handshake patch stops at Pint 5050.
  - Official app capture (`onewheel.pklg`, iOS PacketLogger):
    - About 2.9 s after connecting, the app writes the response to `3ff` as a write request (with response), without triggering a challenge first. It presumably caches the response:
      `09 8e 56 04 11 2b 0b db 29 44 e7 24 28 df 97 3c 25 ca 71 53`
    - The shape matches the challenge: the first 3 bytes echo the challenge's first 3 (the old `CRX` slot is now board-specific), then 16 bytes, then an XOR check of the first 19.
    - Ride mode reads 6 straight after, and the stats are live (battery 93).
    - The app then writes `01 01` to `30b` every 1.5 s. No write to `311` was seen after the unlock.
  - Replay, verified from a Mac with bleak:
    - Writing the captured response to `3ff`, with no challenge trigger first, unlocks the board: ride mode 5, battery 93, live pitch, roll and temperatures.
    - With no keepalive, the board locks again between 11 and 16 s after the unlock.
    - Writing `01 01` to `30b` every 1.5 s keeps it unlocked (tested for 45 s).
    - The old keepalive also still works: writing `311` to itself every 15 s (tested for 45 s). 15 s is close to the timeout, so use a shorter interval.

## How the official Android app does it

Decompiled `com.rideonewheel.onewheel` 2.6.85 with jadx. The handshake lives in `OnewheelService.onCharacteristicChanged`.

- The app buffers notifications from `3fe` until it has 20 bytes.
- **fw < 4141:** it computes `bytes[0:3] + md5(bytes[3:19] + password) + xor` locally. `password` comes from the native method `MainActivity.getChallengeResponsePassword`, which lives in an obfuscated `libnative-lib.so`. This is the Gemini path, and the password is the `D925...` key.
- **fw >= 4141 (all Pints, including Hydrus):** nothing is computed on the phone.
  1. The app takes `bytes[3:19]`, encodes it as base16, and sends it to the URL from `getLeaderboardStatsUrl(serial)`. The body is `AppStats{key: <nonce hex>, token: <Firebase Cloud Messaging token>, userId}`. The request is deliberately named "stats" and tagged `app_stats`.
  2. The server answers asynchronously with a Firebase Cloud Messaging (FCM) push whose payload holds an `appStats` field: the 20-byte response as hex.
  3. The app saves the response in its Room database against the board, broadcasts `ACTION_APP_STATS`, writes it to `3ff`, and starts polling.
  4. On later connections it writes the saved response straight away, without triggering a challenge. That matches the iOS capture.
- The board-specific secret therefore lives only on Future Motion's server and in the board's firmware. The app cannot derive it, so neither can we from the APK. Deriving it offline needs a firmware dump and a look at the board's check routine, for example with rewheel's STM32 dump procedure.
- There is a separate RSA flow on `31f` (`RsaException.BoardRsaSeedRetrievalFailed`, `ServerRsaKeyRetrievalFailed`, `BoardRsaUnlockFailed`). It belongs to the owner-portal "lock board" commands, not the connect handshake.

## Telemetry changes on newer firmware

The official app switches decoding when `q3.c.h(fw, hw)` is true: Pint >= 5056, Pint X >= 5076, XR >= 4153, GT >= 6000, and always on GT-S, XR Classic and Antic. Measured on the 5208 Pint:

- **`31b` (cell voltages) is silent.** No notifications in 15 s with notify enabled, and reads return `0000`. The official app only subscribes to `31b` on older firmware, so it doesn't show cells on these boards either.
- **`312` (current) reads 0.** The app ignores it.
- **`304` now carries signed motor power in watts.** It used to be the "battery low 5%" flag. Idle it flickers between `0000` and `0003`; the app treats values beyond +/-10 W as real load and negative values as regen.
- **`31e`** notifies constantly with small values (`0200`, `0301`, `0000`, `0100`), probably a status or step counter. Unknown.
- **`31c`** reads `4700`, **`320`** reads `0004`, **`31d`** and **`31f`** read 0. Unknown.

## Ride modes and names

Ride mode is the value of `302`. Values by board, from the official app's table (`o3.a.T`):

| Board | Modes |
| --- | --- |
| Pint, Pint X | Redwood 5, Pacific 6, Elevated 7, Skyline 8 (Pint X adds an "X" suffix) |
| GT, GT-S | Bay 3, Roam 4, Flow 5, Highline 6, Elevated 7, Apex 8 |
| XR Classic | Sequoia 3, Cruz 4, Mission 5, Session 6, Elevated 7, Delirium 8 |
| Plus, XR | Sequoia 4, Cruz 5, Mission 6, Elevated 7, Delirium 8, Custom 9 |
| V1 | Classic 1, Extreme 2, Elevated 3 |

The board's nickname is not stored on the board. Renaming it in the official app writes nothing over BLE (the rename capture has no such write, and the app never touches `3fd`). The board still advertises `ow292642`, and the nickname lives in the official app and your Future Motion account. UnoWheel keeps its own nickname per board.

## Replay

The challenge is fixed per board and the board accepts the same response every time, so one captured response unlocks it indefinitely. No server is involved after that first capture. `tools/ow_unlock.py` caches responses in `~/.config/unowheel/handshakes.json`, keyed by challenge.

## Capturing the official app's response

On iOS: install the Bluetooth logging profile from Apple's developer site, then use PacketLogger (Additional Tools for Xcode) to capture live from the phone while the official app connects. Look for the 20-byte ATT write request to `3ff` a few seconds after connecting. Pass those bytes as `--token`.

## Open questions for 5208

- How does the board check the response? The app has no local derivation (see above), so only a firmware dump can answer this.
- What do the `01 01` writes to `30b` mean beyond keeping the board unlocked?
- Do the unexplored characteristics `31d` through `320` carry new Hydrus data? The app subscribes to some of them.
