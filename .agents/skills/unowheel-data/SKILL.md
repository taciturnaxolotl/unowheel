---
name: unowheel-data
description: Pull ride, charge and board data off Kieran's iPhone from the UnoWheel app and analyse it with OnewheelKit. Use whenever working in the unowheel repo and the task involves real ride data, e.g. "pull the rides", "pull new rides", "look at tonight's ride", "why does this ride look weird", checking pushback, range, efficiency, GPS cleanup, charge sessions, or verifying a change against recorded rides, even if the user doesn't say "pull".
---

# Getting data out of UnoWheel

The app stores everything in its own container on the phone. Pull it with
`devicectl`, then read it through OnewheelKit so you see what the app shows,
not the raw files.

## 1. Pull

```bash
.agents/skills/unowheel-data/scripts/pull.sh            # into /tmp/unowheel-pull
.agents/skills/unowheel-data/scripts/pull.sh /tmp/rides-before-fix
```

It finds the paired iPhone (set `UNOWHEEL_DEVICE` to a name or UDID to pick
one), retries the copy (devicectl drops connections now and then), and prints
ride and charge counts. The phone can be locked; it must be paired and reachable.

Each pull replaces the destination, so pull into a new folder when you want to
compare before and after.

## 2. Summarise

```bash
cd .agents/skills/unowheel-data/scripts/ridestats
swift run -q ridestats /tmp/unowheel-pull                       # every ride
swift run -q ridestats /tmp/unowheel-pull --since 2026-10-25    # recent only
swift run -q ridestats /tmp/unowheel-pull --ride 07C641C1       # one ride
```

One line per ride, cleaned with `cleanedRoute()`: distance, top and average
speed, moving time, GPS fixes before and after cleanup, route quality, pack
Wh/km, start pack and air temperature, pushback speed, title. Then the learned
usual ride and efficiency model per board, then charge sessions.

It depends on the repo's `OnewheelKit` by path, so kit changes show up on the
next run. That makes it the quickest way to check a cleanup or stats change
against real rides: pull, run, edit the kit, run again.

For anything it doesn't print, edit `main.swift` or write a short Python
script over the JSON. Prefer the kit for anything the app computes (distance,
speed, pushback, cleanup), so your numbers match the app.

## What's in a pull

```
/tmp/unowheel-pull/
  rides/<UUID>.json      one raw ride each
  charges/<UUID>.json    one charge session each
  prefs.plist            UserDefaults: cached telemetry ("telemetry.<board>"),
                         learned range ("range.<board>"), settings
```

**Ride files hold raw data.** The app cleans on load: it zeroes readings while
the board is off the pad or lifted, drops bad GPS fixes, and sets
`routeQuality`. Raw files will disagree with the app on top speed, distance and
the map. That is expected; use the kit to see the app's view.

**Times are seconds since 2001-01-01** (Swift's default `Date` encoding). Add
`978307200` for a Unix timestamp. Rides are in Eastern time.

Ride top level: `id`, `board` (the board's name, currently `onewheel`),
`points`, `odometerKm`, `startPlace`, `endPlace`, `customTitle`, `weather`
(`temperatureC`, `windKPH`, `precipitationMM`, `humidityPercent`).

Each point is about one second. Every field but `time` and `speedKPH` is
optional, and older rides lack the newer ones:

| Field | Meaning |
|---|---|
| `latitude`, `longitude`, `altitude` | GPS fix, absent when there was none fresh |
| `accuracyM` | fix accuracy; present without a position means the fix was over 20 m and not used |
| `speedKPH` | from wheel rpm; spins freely when the board is lifted |
| `batteryPercent`, `volts`, `batteryTempC` | pack state; `volts` is estimated on firmware 5208 |
| `watts` | motor power, negative is regen; spiky, see below |
| `usedAh`, `regenAh` | board's own charge counters since the ride began |
| `motorTempC`, `controllerTempC` | temperatures |
| `pitch` | degrees, **nose up reads negative**; use `noseUp` in the kit |
| `status` | raw `30f` word: rider and footpad bits, charging, error code |
| `rideMode` | 8 is Skyline on a Pint |
| `climbM` | barometer height since the ride began |

Charge files: `samples` of `date`, `percent`, `watts`, `volts`, `batteryTempC`.

## Things that will trip you up

- **Power spikes are fake.** `watts` and speed arrive on separate clocks, so
  single samples pair a spike with the wrong moment. Use the kit's `peakWatts`
  (3-sample average) or the amp-hour counters, never the raw maximum.
- **GPS gaps have two causes.** Sparse, wandering fixes are indoors (Wi-Fi).
  No fixes at all while moving fast is iOS not delivering them. `accuracyM`
  without a position tells a weak signal apart from no fixes.
- **Pushback is about 22 km/h** in Skyline on this Pint, from the nose lifting.
  `safetyHeadroom` was always 0 and has been removed.
- **New fields only appear on rides recorded after the build that adds them**
  shipped to the phone. Check which rides have a field before drawing
  conclusions.

## Putting a new build on the phone

Recording changes need a build on the phone before the next ride:

```bash
cd ios && xcodebuild -project UnoWheel.xcodeproj -scheme UnoWheel -configuration Debug \
  -destination 'platform=iOS,name=Briony' -derivedDataPath /tmp/unowheel-dd -allowProvisioningUpdates build
xcrun devicectl device install app --device Briony /tmp/unowheel-dd/Build/Products/Debug-iphoneos/UnoWheel.app
```

## Looking at a ride in the app without the phone

Copy pulled ride files into a simulator and open one directly:

```bash
SIM=<booted simulator UDID>
C=$(xcrun simctl get_app_container $SIM sh.dunkirk.unowheel data)
mkdir -p "$C/Library/Application Support/rides" && cp /tmp/unowheel-pull/rides/*.json "$C/Library/Application Support/rides/"
xcrun simctl launch $SIM sh.dunkirk.unowheel -demo -open-rides -openRide 07C641C1
```

`-demo` fakes a connected board named `ow292642`, and the ride list only shows
rides for the connected board, so set `"board": "ow292642"` in the copied files
first. `-openRide` takes an ID prefix and only works in debug builds.
