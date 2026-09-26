#!/usr/bin/env python3
"""Friction runs along the direction of travel, bit-exact with the model.

Boots PocketFever.dsk in AmSpiriT-Lite. For each case one ball (slot 0) is
launched from mid-table with a velocity from src/game/shot_table.s; the other
nine are parked on the edges, out of its way. Once it stops, its 8.8 resting
position must equal tools/friction_model.settle() exactly: the model is the
spec of sys_physics_friction, and the same script shows why the old
per-axis friction bent every diagonal roll (python3 tools/friction_model.py).

Also checked per case: the resting point lies on the launch line (at most
3 screen degrees off), and e_facc is back to 0 once the ball stops.

Usage: python3 tests/physics_test.py [--keep-emulator]
"""
import argparse
import math
import re
import sys
import time

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent.parent / "tools"))
from friction_model import PIXEL_ASPECT, directions, settle  # noqa: E402

from amspirit import BALL_COUNT, ENTITY_SIZE, ROOT, boot, get, post, shutdown, symbols

START_X, START_Y = 80, 130
PARKED = [(0, 68), (40, 68), (120, 68), (156, 68), (0, 194), (40, 194), (120, 194), (156, 194), (156, 130)]

LUA = r"""
local ARR, SZ, N = %(array)d, %(size)d, %(count)d
local CASES = {%(cases)s}
local PARKED = {%(parked)s}
local function word(v) if v < 0 then v = v + 65536 end return v %% 256, v // 256 end
local function place(slot, x, y, vx, vy)
  local vxl, vxh = word(vx)
  local vyl, vyh = word(vy)
  cpc.setRam(ARR + slot * SZ + 1, string.char(0, x, 0, y, vxl, vxh, vyl, vyh))
  cpc.setRam(ARR + slot * SZ + 13, string.char(2, 0))   -- CF_PENDING, e_facc = 0
end
for i, c in ipairs(CASES) do
  wait_frames(1)
  for s, p in ipairs(PARKED) do place(s, p[1], p[2], 0, 0) end
  place(0, %(sx)d, %(sy)d, c[1], c[2])
  local r
  for f = 1, 400 do
    wait_frames(1)
    r = cpc.getRam(ARR, SZ)
    if r:byte(6) + r:byte(7) + r:byte(8) + r:byte(9) == 0 then break end
  end
  print(string.format("CASE %%d %%d %%d x=%%d y=%%d facc=%%d", i, c[1], c[2],
    r:byte(2) + 256 * r:byte(3), r:byte(4) + 256 * r:byte(5), r:byte(15)))
end
print("DONE")
"""


def friction():
    text = (ROOT / "src" / "sys" / "physics.s").read_text()
    return int(re.search(r"^PHYS_FRICTION\s*=\s*(\d+)", text, re.M).group(1))


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--keep-emulator", action="store_true")
    args = parser.parse_args()

    f = friction()
    table = directions()
    # ~22 directions spread evenly across the table, at two speeds (~1 and
    # ~1.25 lines/frame): long enough rolls to show any bend, short enough
    # to never reach a cushion. Stride scales with the table size (used to
    # be a flat every-3rd, fine for 64 directions but ~4x too many real-
    # hardware cases once DIRECTIONS grew to 256 for no real gain -- adjacent
    # directions in a finer table are closer together and don't add much
    # new information about friction's worst-case bend, which is about the
    # dx/dy relationship across the compass, not fine angular resolution).
    stride = max(1, len(table) // 22)
    cases = [(dx * m, dy * m) for dx, dy in table[::stride] for m in (4, 5)]
    array = symbols("entity_array")["entity_array"]
    emulator = boot()
    try:
        source = LUA % {
            "array": array, "size": ENTITY_SIZE, "count": BALL_COUNT,
            "cases": ", ".join(f"{{{vx}, {vy}}}" for vx, vy in cases),
            "parked": ", ".join(f"{{{x}, {y}}}" for x, y in PARKED),
            "sx": START_X, "sy": START_Y,
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

    failures, worst = [], 0.0
    for line in state["output"].splitlines():
        m = re.match(r"CASE (\d+) (-?\d+) (-?\d+) x=(\d+) y=(\d+) facc=(\d+)", line)
        if not m:
            continue
        case, vx, vy, x, y, facc = (int(v) for v in m.groups())
        ex, ey, _ = settle(vx, vy, f, START_X * 256, START_Y * 256)
        dx, dy = (x - START_X * 256) / 256, (y - START_Y * 256) / 256
        off = abs((math.degrees(math.atan2(dy, dx * PIXEL_ASPECT))
                   - math.degrees(math.atan2(vy, vx * PIXEL_ASPECT)) + 180) % 360 - 180)
        worst = max(worst, off)
        status = "ok"
        if (x, y) != (ex, ey):
            status = f"MODEL MISMATCH expected x={ex} y={ey}"
            failures.append(f"case {case} v=({vx},{vy}): rested at ({x},{y}), model says ({ex},{ey})")
        if off > 3:
            failures.append(f"case {case} v=({vx},{vy}): rest point {off:.1f} deg off the launch line")
        if facc:
            failures.append(f"case {case}: e_facc={facc} after stopping, expected 0")
        print(f"case {case:2} v=({vx:5},{vy:5}) rest=({x / 256:6.2f},{y / 256:6.2f}) "
              f"off-line {off:4.1f} deg  {status}")
    if not re.search(r"CASE \d+", state["output"]):
        failures.append("no cases ran")
    for failure in failures:
        print("FAIL " + failure)
    print(f"worst off-line angle: {worst:.1f} deg (friction {f})")
    print("physics_test: " + ("FAIL" if failures else "PASS"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
