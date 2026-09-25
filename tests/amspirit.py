"""Shared driver for the PocketFever emulator tests (AmSpiriT-Lite, headless).

Boots the built PocketFever.dsk in ../tools/amspirit-lite, talks to its REST API
on 127.0.0.1:6128 and decodes its PNG screenshots. Stdlib only.

Lua timing (measured against game_loop_count, one main-loop pass per frame):
wait_frames(n) advances n+1 emulated frames. A sampling loop built on
wait_frames(1) therefore sees every other frame, and a hold of H frames is
wait_frames(H - 1).
"""
import json
import os
import pathlib
import re
import signal
import struct
import subprocess
import sys
import time
import urllib.request
import zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
EMU = ROOT.parent / "tools" / "amspirit-lite" / "run.sh"
API = "http://127.0.0.1:6128"
ENTITY_SIZE = 15          # sys/entity.h.s: cmps,x(2),y(2),vx(2),vy(2),old_x,old_y,id,color,cflags,facc
BALL_COUNT = 10


def config_value(name):
    text = (ROOT / "src" / "config.h.s").read_text()
    match = re.search(rf"^\s*{name}\s*=\s*(\d+)", text, re.M)
    if not match:
        sys.exit(f"{name} missing from src/config.h.s")
    return int(match.group(1))


def symbols(*names):
    noi = ROOT / "obj" / "PocketFever.noi"
    table = dict(re.findall(r"^DEF (\S+) 0x([0-9A-Fa-f]+)", noi.read_text(), re.M))
    return {name: int(table[name], 16) for name in names}


def get(path):
    with urllib.request.urlopen(API + path, timeout=5) as reply:
        return json.load(reply)


def post(path, body, content_type="application/json"):
    request = urllib.request.Request(API + path, data=body.encode(), method="POST",
                                     headers={"Content-Type": content_type})
    with urllib.request.urlopen(request, timeout=5) as reply:
        return json.load(reply)


def ram(address, length):
    return bytes.fromhex(get(f"/api/ram?addr={address}&len={length}")["hex"])


def wait_for(predicate, timeout, what):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if predicate():
                return
        except OSError:
            pass
        time.sleep(0.5)
    sys.exit(f"timed out waiting for {what}")


def boot():
    """Start the emulator, RUN the game, return once the ball pool is live."""
    try:
        get("/api/ping")
        sys.exit("something already listens on 127.0.0.1:6128; stop that emulator first")
    except OSError:
        pass
    pool = symbols("entity_count")["entity_count"]
    emulator = subprocess.Popen([str(EMU), "--web-server", str(ROOT / "PocketFever.dsk")],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                start_new_session=True)
    wait_for(lambda: get("/api/ping")["ok"], 30, "emulator API")
    time.sleep(2)  # ROM boot to the BASIC prompt
    post("/api/keytype", json.dumps({"text": 'run"pocketfe\n'}))
    # Pool header count/max_count/component_size: zero RAM until game_table_init
    # fills it, and a changed entity layout times out here instead of poking wrong bytes.
    header = bytes([BALL_COUNT, BALL_COUNT, ENTITY_SIZE])
    wait_for(lambda: ram(pool, 3) == header, 120, "game main loop")
    time.sleep(1)
    return emulator


def shutdown(emulator):
    try:
        post("/api/quit", "{}")
    except OSError:
        pass
    try:
        emulator.wait(10)
    except subprocess.TimeoutExpired:
        os.killpg(emulator.pid, signal.SIGKILL)  # run.sh wraps xvfb-run; take the group


def screenshot():
    """Current frame as (width, height, rows of (r, g, b)), border included."""
    with urllib.request.urlopen(API + "/api/screenshot?crop=1", timeout=10) as reply:
        data = reply.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        sys.exit("screenshot is not a PNG")
    pos, idat, width = 8, b"", 0
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        chunk = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, depth, colour, _, _, interlace = struct.unpack(">IIBBBBB", chunk)
            if depth != 8 or colour not in (2, 6) or interlace:
                sys.exit(f"unsupported PNG depth={depth} colour={colour} interlace={interlace}")
            channels = 3 if colour == 2 else 4
        elif kind == b"IDAT":
            idat += chunk
        pos += 12 + length
    raw, stride = zlib.decompress(idat), width * channels
    rows, previous = [], bytearray(stride)
    for y in range(height):
        start = y * (stride + 1)
        kind, line = raw[start], bytearray(raw[start + 1:start + 1 + stride])
        if kind > 4:
            sys.exit(f"corrupt PNG: filter type {kind} on row {y}")
        for i in range(stride):
            left = line[i - channels] if i >= channels else 0
            up, corner = previous[i], previous[i - channels] if i >= channels else 0
            if kind == 1:
                line[i] = (line[i] + left) & 255
            elif kind == 2:
                line[i] = (line[i] + up) & 255
            elif kind == 3:
                line[i] = (line[i] + (left + up) // 2) & 255
            elif kind == 4:
                p = left + up - corner
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - corner)
                line[i] = (line[i] + (left if pa <= pb and pa <= pc else up if pb <= pc else corner)) & 255
        rows.append([tuple(line[x:x + 3]) for x in range(0, stride, channels)])
        previous = line
    return width, height, rows
