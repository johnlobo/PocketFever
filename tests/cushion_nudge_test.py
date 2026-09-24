#!/usr/bin/env python3
"""Regression test: ball-ball separation must never push a ball off the felt.

Boots the real PocketFever.dsk in AmSpiriT-Lite (headless, tools/amspirit-lite),
waits for the main loop, then drives the running game from a server-side Lua
script: it writes ball positions/velocities straight into the entity pool and
samples every ball once per frame while the game's own physics + collision run.

Two parts:
  * edge scenarios: two pre-overlapping balls pinned against each cushion, so
    sys_collision_balls_bounce has to nudge one of them into the wall. Before
    the fix this produced x=255 (then a teleport to the right cushion), x=157,
    y=67 (a ball living on the HUD's last line) and y=195.
  * stress rounds: seeded random positions (half of them on a cushion) and
    velocities, checked every frame, to show the fix holds beyond the 4 cases.

Known limit: sampling is once per frame, not right after sys_collision_update.
On the old code the right/bottom cases (x=157, y=195) were clamped back by the
next physics pass, so they are caught only while the game loop finishes inside
one frame. Left/top/teleport and the settle positions fail the old code
regardless of timing.

The boot waits for the pool header to read count=10, size=ENTITY_SIZE, so a
changed entity layout times out instead of poking the wrong bytes.

Pass = no ball ever outside x 0..TABLE_X_MAX, y TABLE_Y_PX..TABLE_Y_MAX, and
every edge scenario settles on its exact expected positions.

Usage: python3 tests/cushion_nudge_test.py [--keep-emulator]
Needs a built game (make) and nothing else listening on 127.0.0.1:6128.
"""
import argparse
import json
import os
import pathlib
import re
import signal
import subprocess
import sys
import time
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
EMU = ROOT.parent / "tools" / "amspirit-lite" / "run.sh"
API = "http://127.0.0.1:6128"
ENTITY_SIZE = 13          # sys/entity.h.s: cmps,x(2),y(2),vx(2),vy(2),old_x,old_y,id,color
STRESS_ROUNDS = 8
STRESS_FRAMES = 60


def config_value(name):
    text = (ROOT / "src" / "config.h.s").read_text()
    match = re.search(rf"^\s*{name}\s*=\s*(\d+)", text, re.M)
    if not match:
        sys.exit(f"{name} missing from src/config.h.s")
    return int(match.group(1))


def symbols():
    noi = ROOT / "obj" / "PocketFever.noi"
    table = dict(re.findall(r"^DEF (\S+) 0x([0-9A-Fa-f]+)", noi.read_text(), re.M))
    return {name: int(table[name], 16) for name in
            ("entity_count", "entity_array")}


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


def boot(sym):
    try:
        get("/api/ping")
        sys.exit("something already listens on 127.0.0.1:6128; stop that emulator first")
    except OSError:
        pass
    emulator = subprocess.Popen([str(EMU), "--web-server", str(ROOT / "PocketFever.dsk")],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                start_new_session=True)
    wait_for(lambda: get("/api/ping")["ok"], 30, "emulator API")
    time.sleep(2)  # ROM boot to the BASIC prompt
    post("/api/keytype", json.dumps({"text": 'run"pocketfe\n'}))
    # Pool header count/max_count/component_size: zero RAM until game_table_init fills it.
    header = bytes([10, 10, ENTITY_SIZE])
    wait_for(lambda: ram(sym["entity_count"], 3) == header, 120, "game main loop")
    time.sleep(1)
    return emulator


LUA = r"""
local ARR, SZ, N = %(array)d, %(size)d, %(count)d
local XMAX, YMIN, YMAX = %(xmax)d, %(ymin)d, %(ymax)d
local failures = 0

local function word(v) if v < 0 then v = v + 65536 end return v %% 256, v // 256 end
local function place(slot, x, y, vx, vy)
  local vxl, vxh = word(vx)
  local vyl, vyh = word(vy)
  cpc.setRam(ARR + slot * SZ + 1, string.char(0, x, 0, y, vxl, vxh, vyl, vyh))
end
local function pos(r, slot) return r:byte(slot * SZ + 3), r:byte(slot * SZ + 5) end
local function fail(msg) failures = failures + 1 print("FAIL " .. msg) end

-- Every slot gets a position, so leftover rack balls never join a scenario.
local function run(name, balls, frames)
  wait_frames(1)
  for _, b in ipairs(balls) do place(b[1], b[2], b[3], b[4], b[5]) end
  local first
  for f = 1, frames do
    wait_frames(1)
    local r = cpc.getRam(ARR, N * SZ)
    for s = 0, N - 1 do
      local x, y = pos(r, s)
      if not first and (x > XMAX or y < YMIN or y > YMAX) then
        first = string.format("frame %%d slot %%d at x=%%d y=%%d", f, s, x, y)
      end
    end
  end
  if first then fail(name .. ": off the felt, " .. first) end
  return cpc.getRam(ARR, N * SZ)
end

local function expect(name, r, slot, x, y)
  local gx, gy = pos(r, slot)
  if gx ~= x or gy ~= y then
    fail(string.format("%%s: slot %%d settled at (%%d,%%d), expected (%%d,%%d)", name, slot, gx, gy, x, y))
  end
end

-- slot, x, y, vx, vy (8.8). Pairs sit far apart; the lower slot is IX in the collision pass.
local edges = {
  {0, 0, 100, 0, 0}, {1, 2, 101, 0, 0},          -- left cushion: IX pinned at x=0
  {2, 153, 100, 0, 0}, {3, XMAX, 101, 0, 0},     -- right cushion: IY pinned at x=XMAX
  {4, 80, YMIN, 0, 0}, {5, 82, YMIN + 5, 0, 0},  -- top cushion: IX pinned at y=YMIN
  {6, 80, YMAX - 4, 0, 0}, {7, 81, YMAX, 0, 0},  -- bottom cushion: IY pinned at y=YMAX
  {8, 40, 130, 0, 0}, {9, 42, 131, 0, 0},        -- mid table: both move (unchanged behaviour)
}
local r = run("edges", edges, 12)
expect("left", r, 0, 0, 100)         expect("left", r, 1, 4, 101)
expect("right", r, 2, 152, 100)      expect("right", r, 3, XMAX, 101)
expect("top", r, 4, 80, YMIN)        expect("top", r, 5, 82, YMIN + 6)
expect("bottom", r, 6, 80, YMAX - 6) expect("bottom", r, 7, 81, YMAX)
expect("mid", r, 8, 39, 130)         expect("mid", r, 9, 43, 131)

-- Left-cushion ball hit by a ball moving straight down: swap hands it vx=0,
-- which is exactly what turned x=255 into a teleport to the right cushion.
r = run("teleport", {
  {0, 0, 100, 0, 0}, {1, 2, 95, 0, 256},
  {2, 150, 190, 0, 0}, {3, 100, 190, 0, 0}, {4, 60, 190, 0, 0}, {5, 20, 190, 0, 0},
  {6, 150, 150, 0, 0}, {7, 100, 150, 0, 0}, {8, 60, 150, 0, 0}, {9, 20, 150, 0, 0},
}, 20)
local tx = pos(r, 0)
if tx > 4 then fail("teleport: left-cushion ball ended at x=" .. tx) end

local seed = %(seed)d
local function rand(n) seed = (seed * 1103515245 + 12345) %% 2147483648 return seed %% n end
for round = 1, %(rounds)d do
  local balls = {}
  for s = 0, N - 1 do
    local x, y = rand(XMAX + 1), YMIN + rand(YMAX - YMIN + 1)
    local wall = rand(8)
    if wall == 0 then x = 0 elseif wall == 1 then x = XMAX
    elseif wall == 2 then y = YMIN elseif wall == 3 then y = YMAX end
    balls[#balls + 1] = {s, x, y, rand(1537) - 768, rand(1537) - 768}
  end
  run("stress round " .. round, balls, %(frames)d)
end

print(string.format("DONE failures=%%d", failures))
"""


def run_lua(sym, seed, rounds, frames):
    source = LUA % {
        "array": sym["entity_array"], "size": ENTITY_SIZE, "count": 10,
        "xmax": config_value("TABLE_WIDTH_PX") - config_value("BALL_WIDTH_PX"),
        "ymin": config_value("TABLE_Y_PX"),
        "ymax": config_value("TABLE_Y_PX") + config_value("TABLE_HEIGHT_PX")
                - config_value("BALL_HEIGHT_PX"),
        "seed": seed, "rounds": rounds, "frames": frames,
    }
    if not post("/api/script?lang=lua", source, "text/plain")["ok"]:
        sys.exit("emulator refused the Lua script")
    deadline = time.time() + 600
    # POST returns before the script starts, so running=false alone means nothing yet.
    while time.time() < deadline:
        state = get("/api/script")
        if state["error"]:
            sys.exit("Lua error: " + state["error"])
        if not state["running"] and "DONE failures=" in state["output"]:
            return state["output"]
        time.sleep(1)
    sys.exit("Lua script did not finish in 10 minutes")


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--keep-emulator", action="store_true")
    parser.add_argument("--seed", type=int, default=1984)
    args = parser.parse_args()

    sym = symbols()
    emulator = boot(sym)
    try:
        output = run_lua(sym, args.seed, STRESS_ROUNDS, STRESS_FRAMES)
    finally:
        if not args.keep_emulator:
            try:
                post("/api/quit", "{}")
            except OSError:
                pass
            try:
                emulator.wait(10)
            except subprocess.TimeoutExpired:
                os.killpg(emulator.pid, signal.SIGKILL)  # run.sh wraps xvfb-run; take the group
    print(output, end="")
    match = re.search(r"DONE failures=(\d+)", output)
    if not match or int(match.group(1)):
        print("cushion_nudge_test: FAIL")
        return 1
    print("cushion_nudge_test: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
