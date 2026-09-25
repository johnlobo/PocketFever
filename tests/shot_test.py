#!/usr/bin/env python3
"""SPACE fires the cue ball in a random direction with a random power.

Boots PocketFever.dsk in AmSpiriT-Lite and presses SPACE on the emulated
keyboard (hardware matrix, the same path as a real key) several times. Each
shot is watched frame by frame from a Lua script until every ball stops.

Per shot:
  * some ball starts moving within 50 frames of the press (SPACE is held 3
    frames through the keyboard matrix); usually the cue, but a cue touching
    another ball hands its velocity over on the first frame;
  * its first velocity is within the shot limits (config.h.s SHOT_POWER_*
    times the largest direction step in src/game/shot_table.s);
  * no ball ever leaves the felt, and at rest no two balls overlap.
Across shots:
  * the directions are not all the same (the shot is random).
Also reported (not asserted, it depends on the random directions): how many
shots hit another ball and how many cushion bounces were seen.

Usage: python3 tests/shot_test.py [--keep-emulator] [--shots N]
"""
import argparse
import re
import sys
import time

from amspirit import (BALL_COUNT, ENTITY_SIZE, ROOT, boot, config_value, get,
                      post, shutdown, symbols)

LUA = r"""
local ARR, SZ, N = %(array)d, %(size)d, %(count)d
local XMAX, YMIN, YMAX, BW, BH = %(xmax)d, %(ymin)d, %(ymax)d, %(bw)d, %(bh)d
local MAXVX, MAXVY = %(maxvx)d, %(maxvy)d
local function s16(r, o) local v = r:byte(o) + 256 * r:byte(o + 1) return v >= 32768 and v - 65536 or v end
local function ball(r, s)
  local o = s * SZ
  return r:byte(o + 3), r:byte(o + 5), s16(r, o + 6), s16(r, o + 8)
end
local function all_still(r)
  for s = 0, N - 1 do local _, _, vx, vy = ball(r, s) if vx ~= 0 or vy ~= 0 then return false end end
  return true
end

for shot = 1, %(shots)d do
  local start = cpc.getRam(ARR, N * SZ)
  -- Hold SPACE (matrix row 5, bit 7, active low) for 3 frames: the game polls
  -- once per frame, and a real key press lasts longer than that anyway.
  -- "Fired" = any ball changed velocity or position: a cue touching a ball
  -- hands its whole velocity over on the first frame (Newton's cradle) and
  -- is still again before it can be seen moving.
  keyboard_write(255, 255, 255, 255, 255, 127, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255)
  local r, fired = nil, nil
  for f = 1, 50 do
    wait_frames(1)
    if f == 3 then
      keyboard_write(255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255)
    end
    r = cpc.getRam(ARR, N * SZ)
    for s = 0, N - 1 do
      local x0, y0 = ball(start, s)
      local x, y, bvx, bvy = ball(r, s)
      if bvx ~= 0 or bvy ~= 0 or x ~= x0 or y ~= y0 then fired = f break end
    end
    if fired then break end
  end
  if fired and fired < 3 then
    wait_frames(3 - fired)
    keyboard_write(255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255)
  end
  if not fired then
    print(string.format("SHOT %%d nofire", shot))
  else
    local vx, vy = 0, 0
    for s = 0, N - 1 do
      local _, _, bvx, bvy = ball(r, s)
      if bvx ~= 0 or bvy ~= 0 then vx, vy = bvx, bvy break end
    end
    local offlimits = (math.abs(vx) > MAXVX or math.abs(vy) > MAXVY) and 1 or 0
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
          -- A sign flip within 3 px of the cushion it was heading into. A hit
          -- from a ball resting there can look the same: report only, no gate.
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
    print(string.format("SHOT %%d fired=%%d vx=%%d vy=%%d offlimits=%%d still=%%s outside=%%s overlap=%%s bounces=%%d moved=%%d cue_x=%%d..%%d cue_y=%%d..%%d",
      shot, fired, vx, vy, offlimits, tostring(all_still(r)), outside == "" and "-" or outside,
      overlap == "" and "-" or overlap, bounces, others, minx, maxx, miny, maxy))
  end
end
print("DONE")
"""


def table_max():
    text = (ROOT / "src" / "game" / "shot_table.s").read_text()
    pairs = [tuple(int(v) for v in m) for m in re.findall(r"\.dw\s+(-?\d+),\s+(-?\d+)", text)]
    return max(abs(dx) for dx, _ in pairs), max(abs(dy) for _, dy in pairs)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--keep-emulator", action="store_true")
    parser.add_argument("--shots", type=int, default=4)
    args = parser.parse_args()

    step_x, step_y = table_max()
    top_power = config_value("SHOT_POWER_MIN") + config_value("SHOT_POWER_SPAN")
    array = symbols("entity_array")["entity_array"]
    emulator = boot()
    try:
        source = LUA % {
            "array": array, "size": ENTITY_SIZE, "count": BALL_COUNT,
            "xmax": config_value("TABLE_WIDTH_PX") - config_value("BALL_WIDTH_PX"),
            "ymin": config_value("TABLE_Y_PX"),
            "ymax": config_value("TABLE_Y_PX") + config_value("TABLE_HEIGHT_PX")
                    - config_value("BALL_HEIGHT_PX"),
            "bw": config_value("BALL_WIDTH_PX"), "bh": config_value("BALL_HEIGHT_PX"),
            "maxvx": step_x * top_power, "maxvy": step_y * top_power, "shots": args.shots,
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

    failures, directions, hits, bounces = [], set(), 0, 0
    for line in state["output"].splitlines():
        if not line.startswith("SHOT"):
            continue
        print(line)
        fields = dict(f.split("=", 1) for f in line.split()[2:])
        shot = line.split()[1]
        if line.endswith("nofire"):
            failures.append(f"shot {shot}: nothing moved after SPACE")
            continue
        directions.add((int(fields["vx"]) > 0, int(fields["vy"]) > 0,
                        abs(int(fields["vx"])) > abs(int(fields["vy"]))))
        if fields["offlimits"] != "0":
            failures.append(f"shot {shot}: first velocity beyond the shot limits")
        if fields["still"] != "true":
            failures.append(f"shot {shot}: balls still moving after 900 frames")
        if fields["outside"] != "-":
            failures.append(f"shot {shot}: {fields['outside']} left the felt")
        if fields["overlap"] != "-":
            failures.append(f"shot {shot}: overlapping at rest {fields['overlap']}")
        hits += int(fields["moved"]) > 0
        bounces += int(fields["bounces"])
    if len(directions) < 2 and args.shots >= 3:
        failures.append("every shot went the same way: direction is not random")
    for failure in failures:
        print("FAIL " + failure)
    print(f"shots that moved other balls: {hits}, cue cushion bounces seen: {bounces}")
    print("shot_test: " + ("FAIL" if failures else "PASS"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
