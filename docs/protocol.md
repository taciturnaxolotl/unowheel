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
  1. The app takes `bytes[3:19]`, encodes it as upper-case base16, and POSTs it to the URL from the native `getLeaderboardStatsUrl`. Despite the name, that URL is `https://app-api.onewheel.com/api/v1/android/boards/{id}/activation`, where `{id}` is the BLE name without `ow` as a number. The body is `AppStats{key: <nonce hex>, token: <Firebase Cloud Messaging token>, userId}` (`userId` 0 when signed out). There is no auth header (`c2/n4.java`, `C0185a(false, ...)`). The request is tagged `app_stats`.
  2. The HTTP reply is only `action_success`. The response itself comes as an FCM data push to that token: `{type: "boardActivation", key: "<40 hex>", owId: "<id>"}` (`MyFirebaseMessagingService`).
  3. The app saves the response in its Room database against the board, broadcasts `ACTION_APP_STATS`, writes it to `3ff`, and starts polling.
  4. On later connections it writes the saved response straight away, without triggering a challenge. That matches the iOS capture.
- The board-specific secret lives only on Future Motion's server and in the board's firmware. The app cannot derive it, but it can ask for it, and so can we. See "Fetching the response" below.
- There is a separate RSA flow ending in a read of `31f` (`RsaException.BoardRsaSeedRetrievalFailed`, `ServerRsaKeyRetrievalFailed`, `BoardRsaUnlockFailed`). It unlocks firmware updates, not the connect handshake; see "Firmware updates".

### Native URL table

`libnative-lib.so` doesn't obfuscate much. Each `MainActivity.get*Url` JNI function compares the app's signing-certificate SHA-1 (`EjPXmbUBIJfrTYgBCw4AKPZMuzA=`, base64) and returns a base64 literal. Decoded, the ones that matter here:

| JNI method | URL / value |
| --- | --- |
| `getLeaderboardStatsUrl` | `POST /api/v1/android/boards/%d/activation` (unlock response) |
| `getOtaKeyUrl` | `POST /api/v1/android/boards/%d/otaKey` |
| `getMetaData` | `POST /api/v1/android/boards/%d/fwBlUpdate` (firmware + bootloader metadata) |
| `getMetaData2` | `POST /api/v1/android/boards/%d/customFirmware` |
| `getDiagnosticsUrl` | `POST /api/v1/android/boards/%d/firmwareUpdateState` |
| `getBoardStateUrl` | `/api/v1/android/boards/%d/state` |
| `getChallengeResponsePassword` | `D9255F0F23354E19BA739CCDC4A91765` (Gemini) |
| `getHashForOnlinePlatform` | `raVGua7je0nthATze8vQraVGua7je0nthETze8vQ` (`hash` field of stats uploads) |

All on `https://app-api.onewheel.com`. Cloudflare sits in front and answers unusual user agents (Python's, for one) with `403 error code: 1010`; an Android `Dalvik/2.1.0 (...)` user agent goes through.

## Fetching the response

Verified 2026-10-25 against ow292642: this returned `098e5604112b0bdb2944e72428df973c25ca7153`, byte for byte the response captured from the official app. `tools/ow_activate.py` does it from a Mac, `Activation.fetchResponse` in OnewheelKit does it on the phone, and UnoWheel now does it by itself when it meets a board with no saved code.

The only hard part is receiving the push. We register for FCM as Future Motion's Android app, using values from the APK (`google_api_key`, `google_app_id`, `gcm_defaultSenderId` 690240897008, project `onewheel-production`, package `com.rideonewheel.onewheel`, signing cert SHA-1 `1233D799B5012097EB4D88010B0E0028F64CBB30`):

1. **Firebase installation.** `POST firebaseinstallations.googleapis.com/v1/projects/onewheel-production/installations` with `x-goog-api-key`, `X-Android-Package` and `X-Android-Cert`, body `{fid, appId, authVersion: "FIS_v2", sdkVersion}`. The FID is 17 random bytes with the top nibble `0111`, base64url, 22 characters. Returns the FID and an auth token. The API key is restricted to Android apps, and those two headers are all the restriction checks.
2. **GCM checkin.** `POST android.clients.google.com/checkin`, protobuf `AndroidCheckinRequest` (a Chrome-browser device type works). Returns `android_id` and `security_token` (fixed64).
3. **Register.** `POST android.clients.google.com/c2dm/register3`, header `Authorization: AidLogin {android_id}:{security_token}`, form `app`, `cert`, `device`, `sender`, `X-subtype` (both the sender ID), `X-scope=*`, `X-gmp_app_id`, `X-appid` (the FID), `X-Goog-Firebase-Installations-Auth`. A device that only just checked in gets `Error=PHONE_REGISTRATION_ERROR` for about a second; retry. Returns `token=<FID>:APA91...`.
4. **MCS.** TLS to `mtalk.google.com:5228`, send version byte 41, tag 2 and a `LoginRequest` (`user`/`resource` = android ID, `auth_token` = security token, `device_id` = `android-<hex id>`, `auth_service` 2). Answer heartbeat pings (tag 0) with acks (tag 1). Data messages arrive as tag 8 `DataMessageStanza` with `app_data` key/value pairs; ack each `persistent_id` with an `IqStanza` selective ack (extension 12).
5. **Ask.** POST the activation request above with that token, then wait. The push took a few seconds.

The push identity can be reused for later boards, so steps 1 to 3 only happen once. No Future Motion account is involved.

**Timing, measured.** The push's `sent` field shows Future Motion sends within 0.2 to 0.3 s of the POST, every time. Any delay is on Google's side, and it depends on how old the token is:

- **Token a few minutes old:** 10 out of 10 pushes arrived within 0.5 s.
- **Token registered seconds ago:** about a quarter of pushes never arrived, and a few were held about 8 s.
- **Other effects of a seconds-old token:**
  - The POST itself can fail with `403 boardActivationFailed` for a few seconds.
  - The MCS login can be refused with `wrong_secret`.

All of these clear up on retry. POSTing again on the same token recovers a dropped push, and the duplicate answer does no harm. So both clients retry the login, re-ask every 10 s, and wait 3 s after a `boardActivationFailed`; the app also registers its push identity at launch, so it's old by the time a board needs it. Client heartbeats made no difference.

## Telemetry changes on newer firmware

The official app switches decoding when `q3.c.h(fw, hw)` is true: Pint >= 5056, Pint X >= 5076, XR >= 4153, GT >= 6000, and always on GT-S, XR Classic and Antic. Measured on the 5208 Pint:

- **`31b` (cell voltages) is silent.** No notifications in 15 s with notify enabled, and reads return `0000`. The official app only subscribes to `31b` on older firmware, so it doesn't show cells on these boards either.
- **`312` (current) reads 0.** The app ignores it.
- **`304` now carries signed motor power in watts.** It used to be the "battery low 5%" flag. Idle it flickers between `0000` and `0003`; the app treats values beyond +/-10 W as real load and negative values as regen.
- **`31e`**, **`31c`**: see the diagnostic stream section below. **`320`** reads `0004`, **`31d`** and **`31f`** read 0, and none moved during the pad, tilt and wheel test.

## Status bits and the diagnostic stream

Measured on the 5208 Pint while pressing pads, tilting and spinning (`/tmp/owwatch.py`), then checked against the official app and other projects.

**`30f` status**: the high byte is a bitmask and the low byte is the current error code (the official app decodes `bArr[1]` with `b2.m`). ponewheel's `DeviceStatus` documents the layout and the official app tests the same bits (`b2.f`: `& 256`, `& 512`, `& 1024`):

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

Error codes in the low byte, with the official app's meaning: 1 BMS low battery, 2 voltage low, 3 voltage high, 4 fall detected (powered on while not level; seen as `2004` while charging on its side), 5 pickup detected, 6 overcurrent, 7 over temperature, 8 battery temperature (old), 9 bad accelerometer, 10 bad current sensor, 11 bad hall sensors, 12 bad motor, 13 and 14 overcurrent, 15 rider detect zone pressed at startup (throttle on Antic), 16 communications, 17 battery temperature, 18 motor temperature, 19 controller over voltage, 20 disabled, 21 charger connected, 22 BMS serial mismatch (new battery), 23 incompatible hardware, 25 new controller. ponewheel lists 1 to 15 with the same meanings.

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
- **`30f` read `2004` while charging:** the charging flag plus error 4, because the board was on its side.
- **The battery cycle count (`31c` register `f1`) went from 1 to 2** across this charge.
- **`31d`, `31f` and `320`** stayed at `0000`, `0000` and `0004` throughout.

**`31e`** cycles `0100 → 0200 → 0301 → 0000` in lockstep with `31c`, one step per diagnostic register. It behaves like a frame counter for the stream. floatface labels it `custom_shaping`, but nothing here changed with pads, tilt or the wheel.

**Trip amp-hours scale:** floatface measured roughly 5.4 raw units per mAh on a GT. That agrees with OWCE's 0.00018 Ah per unit (5.6 per mAh), so `313`/`314` keep the old scaling.

## Ride modes and names

Ride mode is the value of `302`. Values by board, from the official app's table (`o3.a.T`):

| Board | Modes |
| --- | --- |
| Pint, Pint X | Redwood 5, Pacific 6, Elevated 7, Skyline 8 (Pint X adds an "X" suffix). Redwood caps at 12 mph, the rest at 16 (Pint) or 18 (Pint X) |
| GT, GT-S | Bay 3, Roam 4, Flow 5, Highline 6, Elevated 7, Apex 8. Bay 12 mph, Roam 18, the rest 20 (GT) or 25 (GT-S) |
| XR Classic | Sequoia 3, Cruz 4, Mission 5, Session 6, Elevated 7, Delirium 8 |
| Plus, XR | Sequoia 4, Cruz 5, Mission 6, Elevated 7, Delirium 8, Custom 9. Sequoia 12 mph, Cruz 15, the rest 19 |
| V1 | Classic 1, Extreme 2, Elevated 3. Classic 12 mph, the rest 15 |

Per-mode speed limits are from TrailWheel's preset table (trailwheel.com/onewheel-riding-modes); XR Classic is assumed to match the XR.

The board's nickname is not stored on the board. Renaming it in the official app writes nothing over BLE (the rename capture has no such write, and the app never touches `3fd`). The board still advertises `ow292642`, and the nickname lives in the official app and your Future Motion account. UnoWheel keeps its own nickname per board.

## Firmware updates

Static reading of the official Android app 2.6.85 only. Nothing here has been run against a board, and getting it wrong can leave a board in its bootloader. Class and line references are to the jadx output.

### Getting the image

`POST /api/v1/android/boards/{id}/fwBlUpdate` (native `getMetaData`), body `BoardFirmwareRequest{owType, owUuid (BLE address), userId, blVersion, fwVersion, hwVersion, appVersion}`. The reply's `data` holds:

- `firmware{version, base64, checksum, mandatory}` and/or `bootloader{version, base64, checksum, mandatory}`;
- `board{hwVersion}`, which replaces the local value when the board is stuck in its bootloader.

A 33-character checksum means "persist this image": drop the first character, and the app saves the image in prefs for retry. The checksum is the lower-case MD5 of the base64-decoded image. The app doesn't decrypt, decompress or strip anything; the board checks a signature itself (error `0xFFF5`). An XR on bootloader 9 uses `customFirmware` instead (`{fwVersion, firmware, md5}`).

**Preconditions** (`v2/e.java`):

- Pint, Pint X, GT, GT-S, XR Classic and Antic need speed 0. Under 80% battery they must be charging; at or above 80% they must not be.
- Older boards must be charging and stopped.
- A board already in its bootloader is always allowed.

### Bootloader revision

`31c` read directly gives `0x20NN`, where NN is the bootloader version. That is the same register `20` seen in the diagnostic stream.

### Unlocking OTA (newer boards)

Needed when the firmware is a normal version and the board is one of:

- Pint or Pint X on fw >= 5097 (so the 5208 Pint needs it);
- GT on fw >= 6166;
- any GT-S, XR Classic or Antic.

Plus, XR and V1 skip this step.

1. Enable notify on `3fe`, then write `u16be(fw + 2)` to `311`. For the 5208 Pint that is `14 5a`. Writing `fw` itself asks for the connect challenge; `fw + 2` asks for the OTA seed.
2. The board sends 36 bytes on `3fe`: `46 43 58` ("FCX") + 32 bytes + an XOR byte over the first 35.
3. POST `OtaCommandRequest{key: <all 72 hex chars, upper case>, token: <FCM token>, owType, hwVersion, blVersion, fwVersion, fwTarget: <new fw version>}` to `/boards/{id}/otaKey`.
4. The answer is a push `{type: "otaKey", key: <hex>}`. It comes the same way as `boardActivation`, so `Activation`'s push code can receive it.
5. Write the decoded key to `3ff` in 20-byte chunks. Wait 4 s, then read `31f`; a u16 above 0 means unlocked, anything else is a failure (the app calls it `BoardRsaUnlockFailed`). Wait 1 s more.

### Entering the bootloader

Write `4f 6e 65 ff 46 57 55 ff` ("One\xFFFWU\xFF") to `3ff`, then read `311` after every write.

- **Two-step boards** (Pint and Pint X on bootloader >= 8; GT, GT-S, XR Classic and Antic on bootloader >= 3): first FWU, wait for `311` = `0xFFF4`, send FWU again, then wait for `0xFFF0`.
- **GT family on older bootloaders:** FWU, wait 4 s, FWU again.
- **Everything else:** one FWU, then wait for `0xFFF0`.

### Transfer

All writes go to `3ff`, write-with-response, one at a time, about 60 ms after each write callback. The app doesn't change the MTU or the connection priority.

1. **Header (20 bytes):** `u32be(image length)` + the raw 16-byte MD5 of the image.
2. **Image:** in 20-byte slices. The last slice is short and not padded. There are no per-chunk sequence numbers, CRCs or acks beyond the GATT write response.
3. **Watchdog:** each write has a 30 s watchdog. If it fires, or the link drops, the update is fatal; there is no resume.
4. **Order:** if both images are offered, the bootloader goes first.
   - After the bootloader, poll `31c` until it shows the new version (up to 200 reads), then start again from the unlock with the firmware.
   - After the firmware, poll `311` until it reads the new version (up to 200 reads of `0`).

### Error codes

`311` during and after an update:

| Value | Meaning |
| --- | --- |
| `0xFFF0` | ready for data |
| `0xFFF1` | corrupt upload or MD5 mismatch |
| `0xFFF2` | length error |
| `0xFFF3` | download timeout on the board |
| `0xFFF4` | corrupted (also the two-step handshake state) |
| `0xFFF5` | bad signature |
| `0xFFF6` | final check failed |
| `0` or `0xFFFF` | empty or corrupt firmware |

A board that connects showing `0xFFF0` or above, or `0` on non-GT boards, is sitting in its bootloader and needs reflashing.

### Still unknown

- How the server turns the seed into the key. Presumably an RSA signature; the app's errors call it `RsaException`.
- What the board checks before setting `31f`.

### Getting the firmware image is blocked, 2026-10-25

`fwBlUpdate`, `customFirmware`, `otaKey` and the owner-portal board commands all answer `403 access_forbidden` (FM's own application response, not Cloudflare), while `activation`, `state` and `report` work from the same machine. Tried and ruled out: anonymous vs. logged-in account (the account works, the board is registered to it), the app's fallback credentials, correct `userId`, every `owType`/`fw`/`hw` combination, user agent, Python vs. Apple's TLS stack, gzip, the stats `hash` token, Firebase headers, and bogus board IDs (same error, so the denial happens before the board lookup). Either the endpoint is gated on something not visible in the request, or firmware distribution is closed server-side right now; the version endpoint calls 2.6.67 current while 2.6.85 is on APK mirrors, so a migration is plausible. Retrying later, or from a different network, are the cheapest next probes. `tools/ow_firmware.py` is ready: it logs in with a Onewheel account (`OW_EMAIL`/`OW_PASSWORD`), downloads and verifies the images, and saves them.

## Replay

The challenge is fixed per board and the board accepts the same response every time, so one captured response unlocks it indefinitely. No server is involved after that first capture. `tools/ow_unlock.py` caches responses in `~/.config/unowheel/handshakes.json`, keyed by challenge.

## Capturing the official app's response

On iOS: install the Bluetooth logging profile from Apple's developer site, then use PacketLogger (Additional Tools for Xcode) to capture live from the phone while the official app connects. Look for the 20-byte ATT write request to `3ff` a few seconds after connecting. Pass those bytes as `--token`.

## Open questions for 5208

- How does the board check the response? The app has no local derivation (see above), so only a firmware dump can answer this.
- What do the `01 01` writes to `30b` mean beyond keeping the board unlocked?
- Do the unexplored characteristics `31d` through `320` carry new Hydrus data? The app subscribes to some of them.
