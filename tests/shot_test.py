#!/usr/bin/env python3
"""Hold SPACE to charge, release to fire the cue ball in the aimed direction.

Boots PocketFever.dsk in AmSpiriT-Lite, pokes gaim_index (game/aim.s's public
aim state) to a chosen direction before each shot -- the same byte the real
cursor-key aiming (game_aim_update) writes -- then presses SPACE on the
emulated keyboard (hardware matrix, the same path as a real key), holding it
for a different number of frames per shot. Each shot is then watched every
other frame (wait_frames(1) advances two) from a Lua script until every ball
stops.

Per shot:
  * nothing moves while SPACE is held, and some ball starts moving within
    50 samples (~100 frames) of the release (usually the cue; a cue touching
    another ball hands its velocity over on the first frame);
  * the fired velocity matches shot_directions[index] * power exactly, or
    that value after 1-2 frames of sys_physics_friction: direction is no
    longer random, so it must match one of those precisely, not just "in
    range". power = MIN on the first held frame, +1 every SHOT_CHARGE_STEP
    frames, capped at MIN+SPAN. The 1-2 frame slack is because "fired" is
    detected by polling every OTHER real frame (tests/amspirit.py's
    wait_frames(1) gotcha), so friction can run once or twice before the
    very first sample that shows movement.
  * no ball ever leaves the felt, and at rest no two balls overlap.
Also reported: how many shots hit another ball and how many cushion bounces
were seen.

Usage: python3 tests/shot_test.py [--keep-emulator]
"""
import argparse
import re
import sys
import time

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent.parent / "tools"))
from aim_model import directions  # noqa: E402
from friction_model import along_direction  # noqa: E402

from amspirit import ROOT, BALL_COUNT, ENTITY_SIZE, boot, config_value, get, post, shutdown, symbols


def phys_friction():
    text = (ROOT / "src" / "sys" / "physics.s").read_text()
    return int(re.search(r"^PHYS_FRICTION\s*=\s*(\d+)", text, re.M).group(1))

# (hold frames, aim angle in degrees): covers a short/long/mid charge and
# spreads across quadrants, including 0 deg (pure +x) and 270 deg (pure -y).
# Angles, not raw table indices: the index for a given angle depends on how
# many directions shot_table.s has (32 when this was written, 256 now).
CASES_DEG = [(3, 0), (27, 90), (60, 180), (3, 270), (27, 225), (60, 56.25)]

LUA = r"""
local ARR, SZ, N, AIMIDX = %(array)d, %(size)d, %(count)d, %(aimidx)d
local XMAX, YMIN, YMAX, BW, BH = %(xmax)d, %(ymin)d, %(ymax)d, %(bw)d, %(bh)d
local function s16(r, o) local v = r:byte(o) + 256 * r:byte(o + 1) return v >= 32768 and v - 65536 or v end
local function ball(r, s)
  local o = s * SZ
  return r:byte(o + 3), r:byte(o + 5), s16(r, o + 6), s16(r, o + 8)
end
local function all_still(r)
  for s = 0, N - 1 do local _, _, vx, vy = ball(r, s) if vx ~= 0 or vy ~= 0 then return false end end
  return true
end

local CASES = {%(cases)s}
local PRESS = {255, 255, 255, 255, 255, 127, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255}
local RELEASE = {255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255}
local function moved_since(start, r)
  for s = 0, N - 1 do
    local x0, y0 = ball(start, s)
    local x, y, bvx, bvy = ball(r, s)
    if bvx ~= 0 or bvy ~= 0 or x ~= x0 or y ~= y0 then return true end
  end
  return false
end

-- Every shot resets the full rack (positions + zero velocity + CF_PENDING)
-- first: without this, shot N fires into wherever shots 1..N-1 left the
-- other balls, and a stray nearby ball can collide within the first couple
-- of frames, swapping velocities before the "fired" sample is even taken --
-- confirmed by hand (shot 6 in the original sequence read (350,844), which
-- matches no possible friction-only step of its expected (352,848)).
local rack = {}
do
  local r = cpc.getRam(ARR, N * SZ)
  for s = 0, N - 1 do rack[s] = {r:byte(s * SZ + 3), r:byte(s * SZ + 5)} end
end
local function reset_rack()
  for s = 0, N - 1 do
    cpc.setRam(ARR + s * SZ + 1, string.char(0, rack[s][1], 0, rack[s][2], 0, 0, 0, 0))
    cpc.setRam(ARR + s * SZ + 13, string.char(2, 0))   -- CF_PENDING, e_facc = 0
  end
  wait_frames(1)
end

for shot, case in ipairs(CASES) do
  local hold, index = case[1], case[2]
  reset_rack()
  cpc.setRam(AIMIDX, string.char(index))
  local start = cpc.getRam(ARR, N * SZ)
  -- Hold SPACE (matrix row 5, bit 7, active low) for HOLD frames: nothing may
  -- move while charging. "Fired" = any ball changed after release.
  -- wait_frames(n) advances n+1 frames, so this holds for exactly HOLD frames.
  keyboard_write(table.unpack(PRESS))
  wait_frames(hold - 1)
  local early = moved_since(start, cpc.getRam(ARR, N * SZ)) and 1 or 0
  keyboard_write(table.unpack(RELEASE))
  local r, fired = nil, nil
  for f = 1, 50 do
    wait_frames(1)
    r = cpc.getRam(ARR, N * SZ)
    if moved_since(start, r) then fired = f break end
  end
  if not fired then
    print(string.format("SHOT %%d hold=%%d index=%%d early=%%d nofire", shot, hold, index, early))
  else
    local vx, vy = 0, 0
    for s = 0, N - 1 do
      local _, _, bvx, bvy = ball(r, s)
      if bvx ~= 0 or bvy ~= 0 then vx, vy = bvx, bvy break end
    end
    local outside, bounces, others = "", 0, 0
    local x0, y0 = ball(r, 0)
    local minx, maxx, miny, maxy = x0, x0, y0, y0
    local last = r
    for f = 1, 900 do
      if all_still(r) then break end
      wait_frames(1)
      r = cpc.getRam(ARR, N * SZ)
      for s = 0, N - 1 do
        local x, y, nvx, nvy = ball(r, s)
        if outside == "" and (x > XMAX or y < YMIN or y > YMAX) then
          outside = string.format("ball%%d@%%d,%%d", s, x, y)
        end
        local _, _, ovx, ovy = ball(last, s)
        if s == 0 then
          minx, maxx = math.min(minx, x), math.max(maxx, x)
          miny, maxy = math.min(miny, y), math.max(maxy, y)
          if ovx * nvx < 0 and (ovx < 0 and x <= 3 or ovx > 0 and x >= XMAX - 3) then bounces = bounces + 1 end
          if ovy * nvy < 0 and (ovy < 0 and y <= YMIN + 3 or ovy > 0 and y >= YMAX - 3) then bounces = bounces + 1 end
        end
      end
      last = r
    end
    for s = 1, N - 1 do
      local x0, y0 = ball(start, s)
      local x1, y1 = ball(r, s)
      if x0 ~= x1 or y0 ~= y1 then others = others + 1 end
    end
    local same = 0
    for f = 1, 40 do
      wait_frames(1)
      local now = cpc.getRam(ARR, N * SZ)
      if now == r then same = same + 1 else same = 0 end
      r = now
      if same >= 3 then break end
    end
    local overlap = ""
    for a = 0, N - 2 do for b = a + 1, N - 1 do
      local ax, ay = ball(r, a)
      local bx, by = ball(r, b)
      if math.abs(ax - bx) < BW and math.abs(ay - by) < BH then overlap = overlap .. a .. "-" .. b .. " " end
    end end
    print(string.format("SHOT %%d hold=%%d index=%%d early=%%d fired=%%d vx=%%d vy=%%d outside=%%s overlap=%%s bounces=%%d moved=%%d cue_x=%%d..%%d cue_y=%%d..%%d",
      shot, hold, index, early, fired, vx, vy, outside == "" and "-" or outside,
      overlap == "" and "-" or overlap, bounces, others, minx, maxx, miny, maxy))
  end
end
print("DONE")
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--keep-emulator", action="store_true")
    args = parser.parse_args()

    low = config_value("SHOT_POWER_MIN")
    span, step = config_value("SHOT_POWER_SPAN"), config_value("SHOT_CHARGE_STEP")
    table = directions()
    cases = [(hold, round(angle / 360 * len(table)) % len(table)) for hold, angle in CASES_DEG]
    sym = symbols("entity_array", "gaim_index")
    emulator = boot()
    try:
        source = LUA % {
            "array": sym["entity_array"], "size": ENTITY_SIZE, "count": BALL_COUNT,
            "aimidx": sym["gaim_index"],
            "xmax": config_value("TABLE_WIDTH_PX") - config_value("BALL_WIDTH_PX"),
            "ymin": config_value("TABLE_Y_PX"),
            "ymax": config_value("TABLE_Y_PX") + config_value("TABLE_HEIGHT_PX")
                    - config_value("BALL_HEIGHT_PX"),
            "bw": config_value("BALL_WIDTH_PX"), "bh": config_value("BALL_HEIGHT_PX"),
            "cases": ", ".join(f"{{{hold}, {index}}}" for hold, index in cases),
        }
        if not post("/api/script?lang=lua", source, "text/plain")["ok"]:
            sys.exit("emulator refused the Lua script")
        deadline = time.time() + 900
        while time.time() < deadline:
            state = get("/api/script")
            if state["error"]:
                sys.exit("Lua error: " + state["error"])
            if not state["running"] and "DONE" in state["output"]:
                break
            time.sleep(1)
        else:
            sys.exit("Lua script did not finish in 15 minutes")
    finally:
        if not args.keep_emulator:
            shutdown(emulator)

    failures, hits, bounces = [], 0, 0
    for line in state["output"].splitlines():
        if not line.startswith("SHOT"):
            continue
        print(line)
        fields = dict(f.split("=", 1) for f in line.split()[2:] if "=" in f)
        shot, hold, index = line.split()[1], int(fields["hold"]), int(fields["index"])
        if fields["early"] != "0":
            failures.append(f"shot {shot}: balls moved while SPACE was still held")
        if line.endswith("nofire"):
            failures.append(f"shot {shot}: nothing moved after SPACE was released")
            continue
        power = low + min(span, (hold - 1) // step)
        dx, dy = table[index]
        vx, vy = int(fields["vx"]), int(fields["vy"])
        # "Fired" is detected by polling every other real frame (wait_frames(1)
        # advances 2, see tests/amspirit.py), so by the sample the directional
        # friction (sys_physics_friction) may already have run once or twice.
        # Accept the raw fired value or either of those exact steps -- not a
        # tolerance band, the bit-exact friction model tests/physics_test.py
        # already validated against the real Z80 code.
        candidates = [(dx * power, dy * power)]
        fx, fy, acc = dx * power, dy * power, 0
        friction = along_direction(phys_friction())
        for _ in range(2):
            fx, fy, acc = friction(fx, fy, acc)
            candidates.append((fx, fy))
        if (vx, vy) not in candidates:
            failures.append(f"shot {shot}: index {index} hold {hold} (power {power}) fired "
                            f"({vx},{vy}), expected one of {candidates} (raw, or after 1-2 "
                            f"frames of friction)")
        if fields["outside"] != "-":
            failures.append(f"shot {shot}: {fields['outside']} left the felt")
        if fields["overlap"] != "-":
            failures.append(f"shot {shot}: overlapping at rest {fields['overlap']}")
        hits += int(fields["moved"]) > 0
        bounces += int(fields["bounces"])
    for failure in failures:
        print("FAIL " + failure)
    print(f"shots that moved other balls: {hits}, cue cushion bounces seen: {bounces}")
    print("shot_test: " + ("FAIL" if failures else "PASS"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
