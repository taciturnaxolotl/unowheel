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
- **`31e`**, **`31c`**: see the diagnostic stream section below. **`320`** reads `0004`, **`31d`** and **`31f`** read 0, and none moved during the pad, tilt and wheel test.

## Status bits and the diagnostic stream

Measured on the 5208 Pint while pressing pads, tilting and spinning (`/tmp/owwatch.py`), then checked against the official app and other projects.

**`30f` status** is a bitmask in the high byte. ponewheel's `DeviceStatus` documents the layout and the official app tests the same bits (`b2.f`: `& 256`, `& 512`, `& 1024`):

| Bit (u16) | Meaning | Seen on 5208 |
| --- | --- | --- |
| `0x0100` | rider detected (engaged) | not while hand-pressing |
| `0x0200` | footpad zone 1 | yes, front press |
| `0x0400` | footpad zone 2 | yes, back press; `0x0600` both |
| `0x0800` | ICSU fault | |
| `0x1000` | ICSV fault | |
| `0x2000` | charging | yes, `30f` reads `2004` on the charger |
| `0x4000` | BMS/controller comms fault | |
| `0x8000` | broken capacitor | |

floatface (Garmin GT app) saw the same footpad behaviour but hadn't mapped the bits.

**`31c` is a multiplexed diagnostic stream, not just "last error code".** Each notification is `register << 8 | value`, and the board cycles through about 50 registers continuously (it also explains why ZWheel saw it "emitting a status bitmask"). The official app collects one full loop (`z1.c`) and decodes:

| Register | Meaning | ow292642 |
| --- | --- | --- |
| `f0`, `f1` | battery cycle count, high and low byte | `00 01` = 1 |
| `f2` | battery health % | `64` = 100 |
| `c0` | battery type: 1 A123 LiFePO4, 2 VTC6 15s2p, 3 HG2 15s2p, 4 Q30 15s2p, 5 VTC5A 15s1p, 6 VTC5D 15s1p, 7 30Q6 15s2p, 9 VTC6A 18s2p, 10 P42A 18s2p, 11 40T3 18s2p | `06` = VTC5D 15s1p |
| `d0`..`d3` | battery ID, big-endian u32 | `0x00139CD4` = 1285332 |
| `20` | bootloader version | `08` |
| everything else | sent verbatim as "Last Error codes" in support reports | `00`..`07`, `a3`, `b0`..`b9`, `ef`, `10`..`17`, `30`, `31`, `f3`, `40`..`48`, `50` |

**A full charge, measured** (ow292642 from 57%, logged every 12 s):

| Phase | What the board reports |
| --- | --- |
| Constant current, 57% to 88% | `304` steady at -184 to -198 W. Charge current about 3.1 A. Percentage climbs linearly at about 28 s per point. |
| Switch to constant voltage, ~88% | Power starts falling. The percentage jumps from 88% to 99% in under 30 s, then reads 100%. |
| Topping off, at "100%" | Power tapers from ~150 W to ~20 W over 30+ minutes while the board already says 100%. |

- **Charging counts as regen.** `314` (trip regen amp-hours) rises at the charge current, 0.18 mAh per unit. So `304` over the rate of `314` gives pack voltage: 59.6 V at 57%, rising to 63.5 V where constant voltage starts. That is 4.2 V per cell on the 15s pack. The same works while riding with `313`, so voltage is recoverable on firmware that reports 0 on `316`.
- **The percentage is a voltage-based estimate.** It snaps to 100% at the start of the taper. The 31 points from 57% to 88% took 0.26 Ah per 11 points, about 2.4 Ah per 100%, which fits the VTC5D 15s1p pack (2.8 Ah nominal).
- **`30f` also sets `0x0004` while charging.** Its meaning is unknown.
- **The battery cycle count (`31c` register `f1`) went from 1 to 2** across this charge.
- **`31d`, `31f` and `320`** stayed at `0000`, `0000` and `0004` throughout.

**`31e`** cycles `0100 → 0200 → 0301 → 0000` in lockstep with `31c`, one step per diagnostic register. It behaves like a frame counter for the stream. floatface labels it `custom_shaping`, but nothing here changed with pads, tilt or the wheel.

**Trip amp-hours scale:** floatface measured roughly 5.4 raw units per mAh on a GT. That agrees with OWCE's 0.00018 Ah per unit (5.6 per mAh), so `313`/`314` keep the old scaling.

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
