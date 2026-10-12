#!/usr/bin/env python3
# onewheel ble unlock probe (macOS/linux, bleak)
#
#   pip install bleak
#   python3 tools/ow_unlock.py ow292642                 # probe, log challenge
#   python3 tools/ow_unlock.py ow292642 --token <40hex> # replay a captured response
#
# force-quit the official app and nrf connect first; the board takes one central.
#
# see docs/protocol.md for what each step is doing and where it came from.

import argparse, asyncio, hashlib, json, struct, sys, time
from pathlib import Path
from bleak import BleakClient, BleakScanner

def u(n): return f"e659f{n}-ea98-11e3-ac10-0800200c9a66"

RIDE_MODE = u("302")
BATTERY   = u("303")
RPM       = u("30b")
TEMP      = u("310")
FW_REV    = u("311")
HW_REV    = u("318")
UART_RX   = u("3fe")  # board -> phone (notify)
UART_TX   = u("3ff")  # phone -> board (write)

GEMINI_KEY = bytes.fromhex("D9255F0F23354E19BA739CCDC4A91765")
HEADER = b"CRX"
CACHE = Path.home() / ".config" / "unowheel" / "handshakes.json"

def be16(b): return struct.unpack(">H", bytes(b[:2]))[0]

def xor_all(bs):
    c = 0
    for b in bs: c ^= b
    return c

def board_type(hw):
    if 3000 <= hw < 4000: return "plus/xr (gemini era)"
    if 4000 <= hw < 5000: return "xr"
    if 5000 <= hw < 6000: return "pint"
    if 6000 <= hw < 7000: return "gt"
    if 7000 <= hw < 8000: return "pint x"
    return "unknown"

def gemini_response(ch: bytes) -> bytes:
    out = bytearray(HEADER) + hashlib.md5(ch[3:19] + GEMINI_KEY).digest()
    out.append(xor_all(out))
    return bytes(out)

def load_cache():
    try: return json.loads(CACHE.read_text())
    except (FileNotFoundError, json.JSONDecodeError): return {}

def save_cache(c):
    CACHE.parent.mkdir(parents=True, exist_ok=True)
    CACHE.write_text(json.dumps(c, indent=2))

class Challenge:
    def __init__(self):
        self.buf = bytearray()
        self.done = asyncio.Event()

    def feed(self, _, data: bytearray):
        print(f"  uart rx ({len(data)}): {data.hex(' ')}")
        self.buf.extend(data)
        i = self.buf.find(HEADER)
        if i >= 0 and len(self.buf) - i >= 20:
            del self.buf[:i]
            self.done.set()
        elif len(self.buf) >= 20 and xor_all(self.buf[:19]) == self.buf[19]:
            self.done.set()

async def read_stats(c, label):
    vals = {}
    for name, uuid in (("ride_mode", RIDE_MODE), ("battery", BATTERY), ("rpm", RPM), ("temp", TEMP)):
        try: vals[name] = be16(await c.read_gatt_char(uuid))
        except Exception as e: vals[name] = f"err:{e}"
    print(f"{label}: " + "  ".join(f"{k}={v}" for k, v in vals.items()))
    return vals

async def main(args):
    print(f"scanning for {args.name}...")
    dev = await BleakScanner.find_device_by_name(args.name, timeout=15)
    if not dev: sys.exit("not found")
    serial = args.name.lower().removeprefix("ow")

    async with BleakClient(dev) as c:
        fw_raw = await c.read_gatt_char(FW_REV)
        hw_raw = await c.read_gatt_char(HW_REV)
        fw, hw = be16(fw_raw), be16(hw_raw)
        print(f"fw={fw} ({fw_raw.hex()})  hw={hw} ({hw_raw.hex()})  type={board_type(hw)}")

        before = await read_stats(c, "pre-unlock")
        if isinstance(before["ride_mode"], int) and before["ride_mode"] > 0:
            print("ride_mode > 0: board already looks unlocked (owce treats this as 'jumpstarted')")

        ch = Challenge()
        await c.start_notify(UART_RX, ch.feed)
        print("writing fw rev back to itself to trigger challenge...")
        await c.write_gatt_char(FW_REV, fw_raw, response=True)
        try:
            await asyncio.wait_for(ch.done.wait(), 5)
        except asyncio.TimeoutError:
            await c.stop_notify(UART_RX)
            print(f"no CRX challenge in 5s. raw uart buffer: {ch.buf.hex(' ') or '(empty)'}")
            sys.exit("trigger or framing changed on this firmware")
        await c.stop_notify(UART_RX)

        challenge = bytes(ch.buf[:20])
        chk_ok = xor_all(challenge[:19]) == challenge[19]
        framing = "CRX" if challenge[:3] == HEADER else "headerless (hydrus)"
        print(f"challenge: {challenge.hex(' ')}  (framing {framing}, xor check {'ok' if chk_ok else 'MISMATCH'})")

        cache = load_cache()
        entry = cache.setdefault(serial, {"fw": fw, "hw": hw, "challenges": [], "responses": {}})
        seen = [x["hex"] for x in entry["challenges"]]
        nonce = challenge[:19].hex()
        print(f"challenge seen before on this board: {any(s.startswith(nonce) for s in seen)} ({len(seen)} logged)")
        entry["challenges"].append({"hex": challenge.hex(), "at": time.strftime("%Y-%m-%dT%H:%M:%S")})
        entry["fw"], entry["hw"] = fw, hw

        if args.token:
            resp = bytes.fromhex(args.token.replace(" ", ""))
            entry["responses"][nonce] = resp.hex()
            source = "--token"
        elif nonce in entry["responses"]:
            resp = bytes.fromhex(entry["responses"][nonce])
            source = "cache"
        elif fw < 4141 or args.force_gemini:
            resp = gemini_response(challenge)
            source = "gemini md5 (static key)"
        else:
            resp = None
        save_cache(cache)

        if resp is None:
            print("\nfw >= 4141 uses a per-board response from the vendor server; no local key.")
            print("capture the official app's 20-byte write to e659f3ff for this challenge and pass it with --token.")
            print(f"logged to {CACHE}")
            return

        if len(resp) != 20 or resp[:3] != challenge[:3]:
            print(f"warning: response doesn't echo the challenge's first 3 bytes: {resp.hex(' ')}")
        print(f"response ({source}): {resp.hex(' ')}")
        await c.write_gatt_char(UART_TX, resp, response=True)
        await asyncio.sleep(1)

        after = await read_stats(c, "post-unlock")
        changed = [k for k in before if before[k] != after[k]]
        print(f"changed after unlock: {changed or 'nothing (yet)'}")

        def on_stat(label):
            return lambda _, d: print(f"{time.strftime('%X')} {label}={be16(d)}")
        for label, uuid in (("battery%", BATTERY), ("rpm", RPM), ("temp_raw", TEMP), ("ride_mode", RIDE_MODE)):
            await c.start_notify(uuid, on_stat(label))

        keep = {"fw": (FW_REV, fw_raw, 10.0), "rpm": (RPM, b"\x01\x01", 1.5), "none": (None, None, 5.0)}[args.keepalive]
        uuid, payload, every = keep
        print(f"watching {args.watch}s, keepalive={args.keepalive} every {every}s (spin the wheel / tilt it)...")
        t0 = time.time()
        while time.time() - t0 < args.watch:
            await asyncio.sleep(every)
            if uuid: await c.write_gatt_char(uuid, payload, response=True)
            bat = be16(await c.read_gatt_char(BATTERY))
            print(f"{time.strftime('%X')} +{time.time()-t0:.0f}s battery={bat}")

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("name", nargs="?", default="ow292642")
    p.add_argument("--token", help="20-byte response hex captured from the official app")
    p.add_argument("--force-gemini", action="store_true", help="try the static md5 key even on fw >= 4141")
    p.add_argument("--watch", type=int, default=90)
    p.add_argument("--keepalive", choices=("fw", "rpm", "none"), default="rpm",
                   help="fw: write fw rev every 10s (gemini style). rpm: write 01 01 to 30b every 1.5s (official app on 5208)")
    asyncio.run(main(p.parse_args()))
