#!/usr/bin/env python3
# download a board's firmware from future motion. needs a onewheel account:
#
#   OW_EMAIL=you@example.com OW_PASSWORD=... python3 tools/ow_firmware.py ow292642 --fw 5208 --hw 5314 --bl 8
#
# fwBlUpdate rejects anonymous requests with access_forbidden; activation and
# state don't. verified 2026-10-25. see docs/protocol.md, "Firmware updates".

import argparse, base64, gzip, hashlib, json, os, sys, time
from pathlib import Path

UA = "Dalvik/2.1.0 (Linux; U; Android 14; Pixel 7 Build/AP2A.240805.005)"
BASE = "https://app-api.onewheel.com/api/v1/android"

sys.path.insert(0, str(Path(__file__).parent))
from ow_activate import http  # noqa: E402

def authed(url, email, password, body=None):
    h = {"User-Agent": UA, "Accept-Encoding": "gzip, deflate",
         "Authorization": "Basic " + base64.b64encode(f"{email}:{password}".encode()).decode()}
    if body is not None: h["Content-Type"] = "application/json; charset=utf-8"
    code, resp = http(url, body, h)
    try: resp = gzip.decompress(resp)
    except OSError: pass
    return code, json.loads(resp) if resp else {}

def main(a):
    email = os.environ.get("OW_EMAIL"); password = os.environ.get("OW_PASSWORD")
    if not email or not password: sys.exit("set OW_EMAIL and OW_PASSWORD")
    serial = int(a.name.lower().removeprefix("ow"))

    code, me = authed(f"{BASE}/users/own", email, password)
    print(f"login: {code}", file=sys.stderr)
    if code != 200: sys.exit(str(me)[:300])

    body = json.dumps({"owType": a.type, "owUuid": "00:00:00:00:00:00", "userId": (me.get("data") or {}).get("entry", {}).get("id", 0),
                       "blVersion": a.bl, "fwVersion": a.fw, "hwVersion": a.hw, "appVersion": "Android 2.6.85"}).encode()
    code, meta = authed(f"{BASE}/boards/{serial}/fwBlUpdate", email, password, body)
    print(f"fwBlUpdate: {code}", file=sys.stderr)
    if code != 200: sys.exit(str(meta)[:300])
    data = meta.get("data") or {}
    print(json.dumps({k: {kk: (f"<{len(vv)} base64 chars>" if kk == "base64" else vv) for kk, vv in v.items()}
                       for k, v in data.items() if isinstance(v, dict)}, indent=2), file=sys.stderr)

    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    for kind in ("bootloader", "firmware"):
        entry = data.get(kind)
        if not entry: print(f"no {kind} offered", file=sys.stderr); continue
        blob = base64.b64decode(entry["base64"])
        checksum = entry["checksum"]
        if len(checksum) == 33: checksum = checksum[1:]
        if hashlib.md5(blob).hexdigest() != checksum.lower(): sys.exit(f"{kind} md5 mismatch")
        path = out / f"{serial}_{kind}_{entry['version']}.bin"
        path.write_bytes(blob)
        print(f"{kind} v{entry['version']} ({'mandatory' if entry.get('mandatory') else 'optional'}) -> {path} ({len(blob)} bytes)", file=sys.stderr)

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("name", nargs="?", default="ow292642")
    p.add_argument("--type", default="pint")
    p.add_argument("--fw", type=int, default=5208)
    p.add_argument("--hw", type=int, default=5314)
    p.add_argument("--bl", type=int, default=8)
    p.add_argument("--out", default="/tmp/owfw")
    main(p.parse_args())
