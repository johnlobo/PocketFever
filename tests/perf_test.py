#!/usr/bin/env python3
"""Performance budget: the main loop must run once per frame (steady 50 Hz).

Boots PocketFever.dsk in AmSpiriT-Lite and, from a server-side Lua script,
reads game_loop_count (incremented once per main-loop iteration) before and
after a fixed number of emulated frames. loops/frames = 1.00 means every frame
got its own iteration; 0.50 means the loop is running at 25 Hz.

Scenarios:
  rest    the opening rack, nothing moving
  break   cue ball driven into the rack at 3 px/frame, the collision-heavy case
  chaos   all 10 balls moving in seeded random directions (up to 3 px/frame)

Budget: loops/frames >= 0.98 in every scenario (one frame of slack for where
the measurement window starts inside a loop iteration).

Usage: python3 tests/perf_test.py [--keep-emulator]
"""
import argparse
import re
import sys
import time

from amspirit import BALL_COUNT, ENTITY_SIZE, boot, get, post, shutdown, symbols

BUDGET = 0.98

LUA = r"""
local ARR, SZ, N, COUNTER = %(array)d, %(size)d, %(count)d, %(counter)d
local function word(v) if v < 0 then v = v + 65536 end return v %% 256, v // 256 end
local function place(slot, x, y, vx, vy)
  local vxl, vxh = word(vx)
  local vyl, vyh = word(vy)
  cpc.setRam(ARR + slot * SZ + 1, string.char(0, x, 0, y, vxl, vxh, vyl, vyh))
end
local function loops() local r = cpc.getRam(COUNTER, 2) return r:byte(1) + 256 * r:byte(2) end
local function measure(name, frames)
  local before = loops()
  wait_frames(frames)
  local done = (loops() - before) %% 65536
  print(string.format("RESULT %%s %%d %%d", name, done, frames))
end

local rack = {}
local r = cpc.getRam(ARR, N * SZ)
for s = 0, N - 1 do rack[s] = {r:byte(s * SZ + 3), r:byte(s * SZ + 5)} end

wait_frames(2)
measure("rest", 150)

-- Slot 0 is the cue ball (game/table.s); drive it straight at the rack apex.
wait_frames(1)
for s = 0, N - 1 do place(s, rack[s][1], rack[s][2], 0, 0) end
place(0, 70, rack[1][2], -768, 0)
measure("break", 60)

local seed = 2024
local function rand(n) seed = (seed * 1103515245 + 12345) %% 2147483648 return seed %% n end
wait_frames(1)
for s = 0, N - 1 do place(s, rack[s][1], rack[s][2], rand(1537) - 768, rand(1537) - 768) end
measure("chaos", 60)
print("DONE")
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--keep-emulator", action="store_true")
    args = parser.parse_args()

    sym = symbols("entity_array", "game_loop_count")
    emulator = boot()
    try:
        source = LUA % {"array": sym["entity_array"], "size": ENTITY_SIZE,
                        "count": BALL_COUNT, "counter": sym["game_loop_count"]}
        if not post("/api/script?lang=lua", source, "text/plain")["ok"]:
            sys.exit("emulator refused the Lua script")
        deadline = time.time() + 300
        while time.time() < deadline:
            state = get("/api/script")
            if state["error"]:
                sys.exit("Lua error: " + state["error"])
            if not state["running"] and "DONE" in state["output"]:
                break
            time.sleep(1)
        else:
            sys.exit("Lua script did not finish in 5 minutes")
    finally:
        if not args.keep_emulator:
            shutdown(emulator)

    failed = False
    for name, done, frames in re.findall(r"RESULT (\w+) (\d+) (\d+)", state["output"]):
        ratio = int(done) / int(frames)
        verdict = "ok" if ratio >= BUDGET else "OVER BUDGET"
        failed |= ratio < BUDGET
        print(f"{name:6} {done:>4} loops / {frames} frames = {ratio:.2f} "
              f"({50 * ratio:.1f} Hz)  {verdict}")
    print("perf_test: " + ("FAIL" if failed else "PASS"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
