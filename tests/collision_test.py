#!/usr/bin/env python3
"""Regression tests for ball-ball separation in sys_collision_balls_bounce.

1. Separation must never push a ball off the felt.
2. Separation must use the axis with the smaller real overlap, whichever side
   of IX the other ball is on (the overlap used to be ix+size-iy, which is
   size+distance when IY sits left of / above IX, so it picked the wrong axis).

Boots the real PocketFever.dsk in AmSpiriT-Lite (headless, tools/amspirit-lite),
waits for the main loop, then drives the running game from a server-side Lua
script: it writes ball positions/velocities straight into the entity pool and
samples every ball every other frame (wait_frames(1) advances two) while the
game's own physics + collision run.

Two parts:
  * edge scenarios: two pre-overlapping balls pinned against each cushion, so
    sys_collision_balls_bounce has to nudge one of them into the wall. Before
    the fix this produced x=255 (then a teleport to the right cushion), x=157,
    y=67 (a ball living on the HUD's last line) and y=195.
  * stress rounds: seeded random positions (half of them on a cushion) and
    velocities, checked every other frame, to show the fix holds beyond the 4 cases.

Known limit: sampling is every other frame, not right after sys_collision_update.
On the old code the right/bottom cases (x=157, y=195) were clamped back by the
next physics pass, so a one-frame transient like that is caught only about
half the time. Left/top/teleport and the settle positions fail the old code
regardless of timing.

The boot waits for the pool header to read count=10, size=ENTITY_SIZE, so a
changed entity layout times out instead of poking the wrong bytes.

Pass = no ball ever outside x 0..TABLE_X_MAX, y TABLE_Y_PX..TABLE_Y_MAX, and
every edge scenario settles on its exact expected positions.

Usage: python3 tests/collision_test.py [--keep-emulator]
Needs a built game (make) and nothing else listening on 127.0.0.1:6128.
"""
import argparse
import re
import sys
import time

from amspirit import (BALL_COUNT, ENTITY_SIZE, boot, config_value, get, post,
                      shutdown, symbols)

STRESS_ROUNDS = 8
STRESS_FRAMES = 60


LUA = r"""
local ARR, SZ, N = %(array)d, %(size)d, %(count)d
local XMAX, YMIN, YMAX = %(xmax)d, %(ymin)d, %(ymax)d
local failures = 0

local function word(v) if v < 0 then v = v + 65536 end return v %% 256, v // 256 end
-- Also sets CF_PENDING (e_cflags = 2) and clears e_facc: placing a ball is a position change,
-- and collision only checks pairs with a changed ball.
local function place(slot, x, y, vx, vy, fx, fy)
  local vxl, vxh = word(vx)
  local vyl, vyh = word(vy)
  cpc.setRam(ARR + slot * SZ + 1, string.char(fx or 0, x, fy or 0, y, vxl, vxh, vyl, vyh))
  cpc.setRam(ARR + slot * SZ + 13, string.char(2, 0))   -- CF_PENDING, e_facc = 0
end
local function pos(r, slot) return r:byte(slot * SZ + 3), r:byte(slot * SZ + 5) end
local function fail(msg) failures = failures + 1 print("FAIL " .. msg) end

-- Every slot gets a position, so leftover rack balls never join a scenario.
local function run(name, balls, frames)
  wait_frames(1)
  for _, b in ipairs(balls) do place(b[1], b[2], b[3], b[4], b[5], b[6], b[7]) end
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

local function overlaps(r)
  local found = {}
  for a = 0, N - 2 do
    for b = a + 1, N - 1 do
      local ax, ay = pos(r, a)
      local bx, by = pos(r, b)
      if math.abs(ax - bx) < %(bw)d and math.abs(ay - by) < %(bh)d then
        found[#found + 1] = string.format("%%d(%%d,%%d)-%%d(%%d,%%d)", a, ax, ay, b, bx, by)
      end
    end
  end
  return table.concat(found, " ")
end
local function still(r)
  for s = 0, N - 1 do
    local o = s * SZ
    if r:byte(o + 6) + r:byte(o + 7) + r:byte(o + 8) + r:byte(o + 9) ~= 0 then return false end
  end
  return true
end
local function settle_and_check(name)
  for f = 1, 200 do
    local r = cpc.getRam(ARR, N * SZ)
    if still(r) then break end
    wait_frames(1)
  end
  -- Nudge-only settling can go on for ~11 frames after velocities hit zero:
  -- wait for 3 identical samples (every other frame, max ~80 frames) before
  -- judging overlap and jitter.
  local r, same = cpc.getRam(ARR, N * SZ), 0
  for f = 1, 40 do
    wait_frames(1)
    local now = cpc.getRam(ARR, N * SZ)
    if now == r then same = same + 1 else same = 0 end
    r = now
    if same >= 3 then break end
  end
  if not still(r) then fail(name .. ": balls still moving after ~400 frames") end
  local o = overlaps(r)
  if o ~= "" then fail(name .. ": balls at rest overlapping: " .. o) end
  wait_frames(10)
  if cpc.getRam(ARR, N * SZ):sub(1, -1) ~= r then
    local moved = cpc.getRam(ARR, N * SZ)
    for s = 0, N - 1 do
      local ax, ay = pos(r, s)
      local bx, by = pos(moved, s)
      if ax ~= bx or ay ~= by then
        fail(string.format("%%s: ball %%d jitters at rest (%%d,%%d) -> (%%d,%%d)", name, s, ax, ay, bx, by))
      end
    end
  end
end

local function expect(name, r, slot, x, y)
  local gx, gy = pos(r, slot)
  if gx ~= x or gy ~= y then
    fail(string.format("%%s: slot %%d settled at (%%d,%%d), expected (%%d,%%d)", name, slot, gx, gy, x, y))
  end
end

-- slot, x, y, vx, vy (8.8)[, x frac, y frac]. Pairs sit far apart; the lower slot is IX.
local edges = {
  {0, 0, 100, 0, 0}, {1, 2, 101, 0, 0},          -- left cushion: IX pinned at x=0
  {2, 153, 100, 0, 0}, {3, XMAX, 101, 0, 0},     -- right cushion: IY pinned at x=XMAX
  {4, 80, YMIN, 0, 0}, {5, 82, YMIN + 5, 0, 0},  -- top cushion: IX pinned at y=YMIN
  {6, 80, YMAX - 4, 0, 0}, {7, 81, YMAX, 0, 0},  -- bottom cushion: IY pinned at y=YMAX
  {8, 40, 130, 0, 0}, {9, 42, 131, 0, 0},        -- mid table: both move
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
  {0, 0, 100, 0, 0}, {1, 2, 97, 0, 256},
  {2, 150, 190, 0, 0}, {3, 100, 190, 0, 0}, {4, 60, 190, 0, 0}, {5, 20, 190, 0, 0},
  {6, 150, 150, 0, 0}, {7, 100, 150, 0, 0}, {8, 60, 150, 0, 0}, {9, 20, 150, 0, 0},
}, 20)
local tx = pos(r, 0)
if tx > 4 then fail("teleport: left-cushion ball ended at x=" .. tx) end

-- Overlap per axis is size - |distance|. Old code computed ix+size-iy, which
-- for IY left of / above IX is size+distance and flipped the chosen axis.
r = run("overlap axis", {
  {0, 10, 130, 0, 0}, {1, 7, 131, 0, 0},      -- IY left of IX: x overlap 1 < y 5, split on x
  {2, 60, 140, 0, 0}, {3, 62, 135, 0, 0},     -- IY above IX: y overlap 1 < x 2, split on y
  {4, 20, 190, 0, 0}, {5, 60, 190, 0, 0}, {6, 100, 190, 0, 0},
  {7, 140, 190, 0, 0}, {8, 20, 80, 0, 0}, {9, 140, 80, 0, 0},
}, 8)
expect("iy left", r, 0, 11, 130)     expect("iy left", r, 1, 6, 131)
expect("iy above", r, 2, 60, 141)    expect("iy above", r, 3, 62, 134)

-- Only pairs with a changed ball are checked: two moving balls must still
-- bounce off each other, and a moving ball must still hit a still one.
r = run("moving pairs", {
  {0, 40, 100, 256, 0}, {1, 60, 100, -256, 0},   -- head-on at 1 px/frame each
  {2, 40, 150, 0, 0}, {3, 52, 150, -256, 0},     -- moving ball into a still one
  {4, 20, 80, 0, 0}, {5, 60, 80, 0, 0}, {6, 100, 80, 0, 0},
  {7, 140, 80, 0, 0}, {8, 100, 190, 0, 0}, {9, 140, 190, 0, 0},
}, 40)
local ax, bx = pos(r, 0), pos(r, 1)
if ax > 45 or bx < 55 then
  fail(string.format("head-on: balls ended at x=%%d and x=%%d, expected them to bounce back", ax, bx))
end
local sx = pos(r, 2)
if sx > 37 then fail("moving into still: struck ball stayed at x=" .. sx) end

local parked = {{3, 20, 80, 0, 0}, {4, 60, 80, 0, 0}, {5, 100, 80, 0, 0}, {6, 140, 80, 0, 0},
                {7, 100, 190, 0, 0}, {8, 140, 190, 0, 0}, {9, 20, 190, 0, 0}}
local function with_parked(balls)
  local used = {}
  for _, b in ipairs(balls) do used[b[1]] = true end
  for _, b in ipairs(parked) do if not used[b[1]] then balls[#balls + 1] = b end end
  return balls
end

-- Cushion bounce (sys/physics.s): one ball heading into each cushion at
-- 2 px/frame must come back with the opposite velocity and stay on the felt.
local function vel(r, slot)
  local o = slot * SZ
  local function s16(lo, hi) local v = r:byte(o + lo) + 256 * r:byte(o + hi) return v >= 32768 and v - 65536 or v end
  return s16(6, 7), s16(8, 9)
end
r = run("cushions", with_parked({{0, 6, 120, -512, 0}, {1, XMAX - 6, 140, 512, 0},
                                 {2, 70, YMIN + 6, 0, -512}}), 12)
local vx0 = vel(r, 0)
local vx1 = vel(r, 1)
local _, vy2 = vel(r, 2)
if vx0 <= 0 then fail("left cushion: vx still " .. vx0) end
if vx1 >= 0 then fail("right cushion: vx still " .. vx1) end
if vy2 <= 0 then fail("top cushion: vy still " .. vy2) end
r = run("bottom cushion", with_parked({{0, 70, YMAX - 6, 0, 512}}), 12)
local _, vy0 = vel(r, 0)
if vy0 >= 0 then fail("bottom cushion: vy still " .. vy0) end

-- Critic repros against earlier designs; each must end at rest, apart, steady.
-- Ball struck mid-pass by one collider, then reached by the next.
run("struck mid-pass", with_parked({{0, 50, 100, 0, 0}, {1, 47, 100, 16, 0}, {2, 52, 100, -16, 0}}), 3)
settle_and_check("struck mid-pass")
-- Touching row (the rack is one): separating 2 from 0 pushes 0 into 1.
run("cradle", with_parked({{0, 50, 150, 0, 0}, {1, 46, 150, 0, 0}, {2, 54, 150, -16, 0}}), 3)
settle_and_check("cradle")
-- A moving ball handed v=0 by a swap before its own turn.
run("zeroed by swap", with_parked({{0, 51, 100, -384, 0}, {1, 56, 100, 0, 0},
                                   {2, 53, 93, 0, 264, 0, 128}, {3, 47, 100, 0, 0}}), 3)
settle_and_check("zeroed by swap")
-- A later ball pushed into an earlier one that already had its turn.
run("pushed back", with_parked({{0, 40, 100, 0, 16}, {1, 48, 100, -16, 0, 4, 0}, {2, 44, 100, 0, 0}}), 3)
settle_and_check("pushed back")
-- Fast ball into a pair near the top-right corner.
run("corner wedge", with_parked({{0, 155, YMIN, 0, 0}, {1, 153, YMIN + 10, 0, 0}, {2, 130, YMIN + 4, 816, 0}}), 30)
settle_and_check("corner wedge")
-- Ball squeezed between a cushion-pinned ball and another: must not ping-pong.
run("squeeze", with_parked({{0, 155, YMIN, 0, 0}, {1, 154, YMIN + 5, 0, 0}, {2, 153, YMIN + 11, 0, 0}}), 3)
settle_and_check("squeeze")

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
  settle_and_check("stress round " .. round)
end

print(string.format("DONE failures=%%d", failures))
"""


def run_lua(sym, seed, rounds, frames):
    source = LUA % {
        "array": sym["entity_array"], "size": ENTITY_SIZE, "count": BALL_COUNT,
        "xmax": config_value("TABLE_WIDTH_PX") - config_value("BALL_WIDTH_PX"),
        "ymin": config_value("TABLE_Y_PX"),
        "ymax": config_value("TABLE_Y_PX") + config_value("TABLE_HEIGHT_PX")
                - config_value("BALL_HEIGHT_PX"),
        "seed": seed, "rounds": rounds, "frames": frames,
        "bw": config_value("BALL_WIDTH_PX"), "bh": config_value("BALL_HEIGHT_PX"),
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

    sym = symbols("entity_array")
    emulator = boot()
    try:
        output = run_lua(sym, args.seed, STRESS_ROUNDS, STRESS_FRAMES)
    finally:
        if not args.keep_emulator:
            shutdown(emulator)
    print(output, end="")
    match = re.search(r"DONE failures=(\d+)", output)
    if not match or int(match.group(1)):
        print("collision_test: FAIL")
        return 1
    print("collision_test: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
