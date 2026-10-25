#!/usr/bin/env python3
# fetch a board's unlock response from future motion, the way the official
# android app does, without the official app.
#
#   python3 tools/ow_activate.py ow292642 --challenge 098e56e366f5acaabc75876952677d0ccb012d23
#   python3 tools/ow_activate.py ow292642            # uses ~/.config/unowheel/handshakes.json
#
# stdlib only. the flow (see docs/protocol.md, "Fetching the response"):
#   1. register a firebase installation for future motion's android app
#   2. check in with gcm and register for push as that app, getting an fcm token
#   3. hold an mcs connection to mtalk.google.com so the push can reach us
#   4. post the challenge and the token to /boards/{id}/activation
#   5. the server answers with a push: {type: boardActivation, key: <40 hex>, owId}

import argparse, base64, json, os, socket, ssl, struct, sys, time, urllib.parse, urllib.request
from pathlib import Path

PACKAGE = "com.rideonewheel.onewheel"
CERT_SHA1 = "1233D799B5012097EB4D88010B0E0028F64CBB30"
API_KEY = "AIzaSyCn975YtjSbauFmaSziujB8w5j2jk1FGjI"
PROJECT = "onewheel-production"
APP_ID = "1:690240897008:android:4f5b4fdb4fe5f138"
SENDER = "690240897008"
ACTIVATION = "https://app-api.onewheel.com/api/v1/android/boards/{}/activation"
# cloudflare in front of app-api answers python's default user agent with error 1010
USER_AGENT = "Dalvik/2.1.0 (Linux; U; Android 14; Pixel 7 Build/AP2A.240805.005)"
STATE = Path.home() / ".config" / "unowheel" / "fcm.json"
CACHE = Path.home() / ".config" / "unowheel" / "handshakes.json"

def log(*a): print(*a, file=sys.stderr, flush=True)

# minimal protobuf, enough for checkin and mcs

def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F; n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n: return bytes(out)

def field(num, wire, payload):
    key = varint(num << 3 | wire)
    if wire == 0: return key + varint(payload)
    if wire == 1: return key + struct.pack("<Q", payload)
    return key + varint(len(payload)) + payload

def s(num, text): return field(num, 2, text.encode() if isinstance(text, str) else text)

def parse(buf):
    out, i = {}, 0
    while i < len(buf):
        key, i = read_varint(buf, i)
        num, wire = key >> 3, key & 7
        if wire == 0: val, i = read_varint(buf, i)
        elif wire == 1: val = struct.unpack_from("<Q", buf, i)[0]; i += 8
        elif wire == 5: val = struct.unpack_from("<I", buf, i)[0]; i += 4
        elif wire == 2:
            n, i = read_varint(buf, i); val = bytes(buf[i:i + n]); i += n
        else: raise ValueError(f"wire type {wire}")
        out.setdefault(num, []).append(val)
    return out

def read_varint(buf, i):
    n = shift = 0
    while True:
        b = buf[i]; i += 1
        n |= (b & 0x7F) << shift; shift += 7
        if not b & 0x80: return n, i

def http(url, data=None, headers=None):
    req = urllib.request.Request(url, data=data, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=20) as r: return r.status, r.read()
    except urllib.error.HTTPError as e: return e.code, e.read()

# 1. firebase installation

def new_fid():
    b = bytearray(os.urandom(17)); b[0] = 0x70 | (b[0] & 0x0F)
    return base64.urlsafe_b64encode(bytes(b)).decode()[:22]

ANDROID_HEADERS = {"X-Android-Package": PACKAGE, "X-Android-Cert": CERT_SHA1}

def install():
    body = json.dumps({"fid": new_fid(), "appId": APP_ID, "authVersion": "FIS_v2", "sdkVersion": "a:17.2.0"}).encode()
    code, resp = http(f"https://firebaseinstallations.googleapis.com/v1/projects/{PROJECT}/installations", body,
                      {"Content-Type": "application/json", "x-goog-api-key": API_KEY, **ANDROID_HEADERS})
    if code != 200: sys.exit(f"installation failed {code}: {resp.decode(errors='replace')}")
    j = json.loads(resp)
    return j["fid"], j["authToken"]["token"]

# 2. gcm checkin + register

def checkin():
    chrome = field(1, 0, 3) + s(2, "63.0.3234.0") + field(3, 0, 1)
    proto = field(12, 0, 3) + s(13, chrome)
    req = s(4, proto) + field(14, 0, 3) + field(22, 0, 0)
    code, resp = http("https://android.clients.google.com/checkin", req, {"Content-Type": "application/x-protobuf"})
    if code != 200: sys.exit(f"checkin failed {code}: {resp[:200]!r}")
    m = parse(resp)
    return m[7][0], m[8][0]

def register(android_id, security_token, fid, fis_token):
    form = urllib.parse.urlencode({
        "app": PACKAGE, "cert": CERT_SHA1.lower(), "device": str(android_id),
        "sender": SENDER, "X-subtype": SENDER, "X-scope": "*",
        "X-gmp_app_id": APP_ID, "X-appid": fid, "X-Goog-Firebase-Installations-Auth": fis_token,
        "X-cliv": "fcm-23.4.1", "app_ver": "268501", "gcm_ver": "241517038",
    }).encode()
    # a freshly checked-in device gets PHONE_REGISTRATION_ERROR for a second or so
    for attempt in range(6):
        code, resp = http("https://android.clients.google.com/c2dm/register3", form, {
            "Authorization": f"AidLogin {android_id}:{security_token}",
            "Content-Type": "application/x-www-form-urlencoded"})
        text = resp.decode(errors="replace")
        if code == 200 and text.startswith("token="): return text.split("=", 1)[1].strip()
        log(f"register attempt {attempt + 1}: {code} {text}")
        time.sleep(1 + attempt)
    sys.exit(f"register failed {code}: {text}")

def credentials(fresh):
    if not fresh:
        try: return json.loads(STATE.read_text())
        except (FileNotFoundError, json.JSONDecodeError): pass
    fid, fis = install(); log(f"firebase installation {fid}")
    aid, tok = checkin(); log(f"gcm checkin android id {aid}")
    token = register(aid, tok, fid, fis); log(f"fcm token {token[:24]}...")
    creds = {"android_id": aid, "security_token": tok, "fid": fid, "token": token}
    STATE.parent.mkdir(parents=True, exist_ok=True); STATE.write_text(json.dumps(creds, indent=2))
    return creds

# 3. mcs

class MCS:
    def __init__(self, aid, tok):
        ctx = ssl.create_default_context()
        self.sock = ctx.wrap_socket(socket.create_connection(("mtalk.google.com", 5228), 20), server_hostname="mtalk.google.com")
        self.sock.settimeout(1)
        self.buf = bytearray(); self.first = True; self.aid = aid
        login = (s(1, "chrome-63.0.3234.0") + s(2, "mcs.android.com") + s(3, str(aid)) + s(4, str(aid))
                 + s(5, str(tok)) + s(6, f"android-{aid:x}") + s(8, s(1, "new_vc") + s(2, "1"))
                 + field(12, 0, 0) + field(14, 0, 1) + field(16, 0, 2) + field(17, 0, 1))
        self.sock.sendall(bytes([41, 2]) + varint(len(login)) + login)

    def _fill(self, n, deadline):
        while len(self.buf) < n:
            if time.time() > deadline: return False
            try: chunk = self.sock.recv(65536)
            except (socket.timeout, TimeoutError): continue
            if not chunk: raise ConnectionError("mcs closed")
            self.buf += chunk
        return True

    def read(self, deadline):
        head = 2 if self.first else 1
        if not self._fill(head + 1, deadline): return None
        tag = self.buf[head - 1]
        i = head; size = shift = 0
        while True:
            if not self._fill(i + 1, deadline): return None
            b = self.buf[i]; i += 1; size |= (b & 0x7F) << shift; shift += 7
            if not b & 0x80: break
        if not self._fill(i + size, deadline): return None
        body = bytes(self.buf[i:i + size]); del self.buf[:i + size]; self.first = False
        return tag, parse(body)

    def send(self, tag, body): self.sock.sendall(bytes([tag]) + varint(len(body)) + body)

def login(aid, tok):
    # a device that only just checked in is sometimes refused with wrong_secret
    for attempt in range(5):
        if attempt: time.sleep(attempt)
        mcs = MCS(aid, tok)
        msg = mcs.read(time.time() + 15)
        if msg and msg[0] == 3 and 3 not in msg[1]:
            log("mcs logged in"); return mcs
        mcs.sock.close()
        log(f"mcs login attempt {attempt + 1}: {parse(msg[1][3][0]) if msg and 3 in msg[1] else 'no reply'}")
    sys.exit("mcs login kept failing")

def wait_for_push(mcs, want, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        msg = mcs.read(deadline)
        if msg is None: return None
        tag, m = msg
        if tag == 0:
            mcs.send(1, b"")
        elif tag == 8:
            data = {parse(kv)[1][0].decode(): parse(kv)[2][0].decode() for kv in m.get(7, [])}
            pid = m.get(9, [b""])[0].decode()
            if pid: mcs.send(7, field(2, 0, 1) + s(3, "ack") + s(7, field(1, 0, 12) + s(2, s(1, pid))))
            log(f"push from {m.get(3, [b'?'])[0].decode()}: {data}")
            if want(data): return data
    return None

def main(a):
    serial = a.name.lower().removeprefix("ow")
    challenge = a.challenge
    if not challenge:
        try: challenge = json.loads(CACHE.read_text())[serial]["challenges"][-1]["hex"]
        except (FileNotFoundError, KeyError, IndexError, json.JSONDecodeError):
            sys.exit("no challenge; pass --challenge or run tools/ow_unlock.py first")
    ch = bytes.fromhex(challenge.replace(" ", ""))
    if len(ch) != 20: sys.exit("challenge must be 20 bytes")
    key = ch[3:19].hex().upper()

    creds = credentials(a.fresh)
    mcs = login(creds["android_id"], creds["security_token"])

    # asking again on the same token recovers a push google dropped (see docs/protocol.md)
    body = json.dumps({"key": key, "token": creds["token"], "userId": 0}).encode()
    url = ACTIVATION.format(int(serial))
    deadline = time.time() + a.wait
    data = None
    while data is None and time.time() < deadline:
        log(f"POST {url} key={key}")
        code, resp = http(url, body, {"Content-Type": "application/json; charset=utf-8", "User-Agent": USER_AGENT})
        text = resp.decode(errors="replace")
        log(f"-> {code} {text[:300]}")
        rejected = "boardActivationFailed" in text
        if code != 200 and not rejected: sys.exit("server refused the request")
        want = lambda d: d.get("type") == "boardActivation" and d.get("owId") == str(int(serial))
        data = wait_for_push(mcs, want, min(3 if rejected else 10, deadline - time.time()))
    if not data: sys.exit(f"no boardActivation push within {a.wait}s")
    resp = bytes.fromhex(data["key"])
    ok = len(resp) == 20 and resp[:3] == ch[:3]
    print(resp.hex())
    log(f"response {'looks right' if ok else 'does not echo the challenge header'} (owId {data.get('owId')})")

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("name", nargs="?", default="ow292642")
    p.add_argument("--challenge", help="the board's 20-byte challenge, hex")
    p.add_argument("--wait", type=int, default=60)
    p.add_argument("--fresh", action="store_true", help="register a new fcm token instead of reusing ~/.config/unowheel/fcm.json")
    main(p.parse_args())
