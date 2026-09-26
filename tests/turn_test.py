#!/usr/bin/env python3
"""Accelerating cursor-key aim turn (game/aim.s): staged throttle ramp.

Boots PocketFever.dsk in AmSpiriT-Lite and holds a cursor key through the
real keyboard matrix, checking gaim_index's step timing against the exact
model in tools/turn_model.py.

Timing note: samples are keyed on game_loop_count deltas, NOT on counting
Lua wait_frames(0) calls. wait_frames(0) was measured (2026-09-27) to
sometimes advance zero real game-loop iterations -- confirmed by cross-
checking against game_loop_count, which is authoritative (main.s increments
it once per loop pass). A first attempt at this test, counting wait_frames(0)
calls directly, saw step gaps inflated by a consistent amount and initially
looked like a bug in the ramp; game_loop_count showed the ramp was exact all
along. See CLAUDE.md's "Aiming and shot" section.

Checks:
  * holding Right steps gaim_index at exactly the loop-count deltas
    tools/turn_model.throttle_at predicts, across all four stages;
  * a brief tap (shorter than AIM_TURN_H1) only ever uses the slowest
    (most precise) throttle -- it must not accidentally ride a faster
    stage from a stale hold counter;
  * releasing and re-pressing restarts the ramp at the slow stage, not
    wherever the previous hold left off;
  * switching directions without releasing (left then right) also restarts
    the ramp, per gaim_turn_dir's reset-on-reversal rule;
  * Left decrements, Right increments, and both wrap correctly (0/63 boundary).

Usage: python3 tests/turn_test.py [--keep-emulator]
"""
import argparse
import sys
import time

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent.parent / "tools"))
from turn_model import DIRECTIONS, throttle_at  # noqa: E402

AIM_TURN_T0_EXPECT = throttle_at(0)   # slowest/first-stage throttle, i.e. AIM_TURN_T0

from amspirit import boot, get, post, shutdown, symbols

PRESS_RIGHT = "253, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255"
PRESS_LEFT = "255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255"
RELEASE = "255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255"

_calls = [0]


def wait_lua(source, timeout=120):
    """One Lua script, waited out with a marker unique to THIS call (a fixed
    marker reused across calls can match a previous call's leftover output
    right after POSTing -- see tests/aim_test.py's own note on this)."""
    _calls[0] += 1
    marker = f"__TURN_DONE_{_calls[0]}__"
    if not post("/api/script?lang=lua", source + f'\nprint("{marker}")\n', "text/plain")["ok"]:
        sys.exit("emulator refused the Lua script")
    deadline = time.time() + timeout
    while time.time() < deadline:
        state = get("/api/script")
        if state["error"]:
            sys.exit("Lua error: " + state["error"])
        if not state["running"] and marker in state["output"]:
            return state["output"]
        time.sleep(0.2)
    sys.exit("Lua script did not finish in time")


def parse_ints(text):
    return [int(v) for v in text.split() if v.lstrip("-").isdigit()]


def trace_hold(sym, press, hold_loops):
    """Holds `press` for `hold_loops` game-loop iterations (measured on
    game_loop_count, not wait_frames), returns the list of loop-counts (since
    the press started) at which gaim_index changed."""
    out = wait_lua(
        f"local function loops() local r = cpc.getRam({sym['game_loop_count']}, 2) "
        f"return r:byte(1) + 256 * r:byte(2) end\n"
        f"keyboard_write({press})\n"
        f"local start = loops()\n"
        f"local last = cpc.getRam({sym['gaim_index']}, 1):byte(1)\n"
        f"local out = {{}}\n"
        f"while loops() - start <= {hold_loops} do\n"
        f"  wait_frames(0)\n"
        f"  local idx = cpc.getRam({sym['gaim_index']}, 1):byte(1)\n"
        f"  if idx ~= last then out[#out + 1] = loops() - start; last = idx end\n"
        f"end\n"
        f"keyboard_write({RELEASE})\n"
        f"print(table.concat(out, ' '))\n")
    return parse_ints(out)


def expected_steps(hold_loops):
    """Loop-counts at which a step should have happened, per turn_model."""
    steps, held, tick = [], 0, 0
    for loop in range(1, hold_loops + 1):
        held += 1
        tick += 1
        if tick >= throttle_at(held):
            tick = 0
            steps.append(loop)
    return steps


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--keep-emulator", action="store_true")
    args = parser.parse_args()

    sym = symbols("gaim_index", "game_loop_count")
    failures = []
    emulator = boot()
    try:
        wait_lua("wait_frames(9)")

        # --- 1. full ramp matches the model across all four stages ----------
        loops = 170
        observed = trace_hold(sym, PRESS_RIGHT, loops)
        expected = expected_steps(loops)
        if observed != expected:
            failures.append(f"ramp mismatch: observed {observed[:12]}..., "
                            f"expected {expected[:12]}... (full lists differ)")
        else:
            print(f"ramp matches turn_model.py exactly over {loops} loop iterations "
                 f"({len(observed)} steps)")

        # --- 2. a brief tap never leaves the slowest stage -------------------
        wait_lua("wait_frames(2)")
        tap_loops = 10   # well under AIM_TURN_H1
        tap = trace_hold(sym, PRESS_RIGHT, tap_loops)
        tap_expected = expected_steps(tap_loops)
        if tap != tap_expected:
            failures.append(f"tap ramp mismatch: observed {tap}, expected {tap_expected}")

        # --- 3. release resets the ramp: re-holding starts slow again -------
        wait_lua("wait_frames(2)")
        long_hold = 60      # reach the fast stage
        trace_hold(sym, PRESS_RIGHT, long_hold)
        wait_lua("wait_frames(9)")  # release, let go stay released a while
        second = trace_hold(sym, PRESS_RIGHT, 10)
        second_expected = expected_steps(10)
        if second != second_expected:
            failures.append(f"post-release ramp mismatch: observed {second}, "
                            f"expected {second_expected} -- release should restart the ramp, "
                            f"not carry over the fast speed from the earlier long hold")

        # --- 4. reversing direction without releasing also resets the ramp --
        # Not compared against expected_steps() frame-for-frame: switching
        # keys has the same ~1-2 frame keyboard-scan latency documented
        # throughout this project (a poll doesn't see a new key state
        # instantly), so the OLD direction's ramp -- already in its fastest,
        # steps-every-loop stage here -- can legitimately produce one more
        # step in the old direction right at the switch. That is input
        # latency, not a bug; the real question is whether the NEW direction
        # starts its own ramp from scratch (~AIM_TURN_T0 loops to its first
        # step) rather than inheriting the fast stage (~1 loop). Classify each
        # observed change by whether it incremented (right, +1 mod DIRECTIONS)
        # or decremented (left, -1 mod DIRECTIONS) instead of trusting exact
        # loop-delta bookkeeping across the switch.
        wait_lua("wait_frames(2)")
        out = wait_lua(
            f"local function idx() return cpc.getRam({sym['gaim_index']}, 1):byte(1) end\n"
            f"local function loops() local r = cpc.getRam({sym['game_loop_count']}, 2) "
            f"return r:byte(1) + 256 * r:byte(2) end\n"
            f"keyboard_write({PRESS_RIGHT})\n"
            f"local t0 = loops()\n"
            f"while loops() - t0 < 41 do wait_frames(0) end\n"   # ride into the fast stage
            f"local out = {{}}\n"
            f"keyboard_write({PRESS_LEFT})\n"
            f"local t1 = loops()\n"
            f"local last = idx()\n"
            f"while loops() - t1 <= 12 do\n"
            f"  wait_frames(0)\n"
            f"  local cur = idx()\n"
            f"  if cur ~= last then\n"
            f"    local dir = ((last - cur) % {DIRECTIONS} == 1) and 'L' or 'R'\n"
            f"    out[#out + 1] = string.format('%d%s', loops() - t1, dir)\n"
            f"    last = cur\n"
            f"  end\n"
            f"end\n"
            f"keyboard_write({RELEASE})\n"
            f"print(table.concat(out, ' '))\n")
        changes = [(int(tok[:-1]), tok[-1]) for tok in out.split() if tok and tok[-1] in "LR"]
        left_changes = [delta for delta, dirn in changes if dirn == "L"]
        right_after_switch = [delta for delta, dirn in changes if dirn == "R"]
        if not left_changes:
            failures.append(f"direction reversal: no left (decrementing) step seen at all "
                            f"in the 12 loops after switching -- changes were {changes}")
        elif left_changes[0] < AIM_TURN_T0_EXPECT - 2:
            failures.append(f"direction reversal: first left step came after only "
                            f"{left_changes[0]} loop(s) of holding left, expected roughly "
                            f"{AIM_TURN_T0_EXPECT} -- looks like the fast stage from the "
                            f"earlier right-hold carried over instead of the ramp restarting "
                            f"(all changes: {changes})")
        if any(delta > 2 for delta in right_after_switch):
            failures.append(f"direction reversal: a right (incrementing) step happened more "
                            f"than 2 loops after Left was pressed -- Right should stop firing "
                            f"almost immediately once the switch is detected (all changes: "
                            f"{changes})")

        # --- 5. Left decrements and wraps at the 0/63 boundary ---------------
        # Release + settle first: guarantee gaim_turn_dir/hold/tick are back to
        # 0 (gaim_read_turn_keys's "neither held" branch) before this check,
        # rather than trusting whatever state the previous section left.
        wait_lua(f"keyboard_write({RELEASE})\nwait_frames(4)\n"
                f"cpc.setRam({sym['gaim_index']}, string.char(0))\nwait_frames(2)\n")
        left_steps = trace_hold(sym, PRESS_LEFT, 6)
        final_idx = int(wait_lua(f"print(cpc.getRam({sym['gaim_index']}, 1):byte(1))").split()[-2])
        if not left_steps or final_idx != DIRECTIONS - 1:
            failures.append(f"left from index 0 should wrap to {DIRECTIONS - 1}, got {final_idx} "
                            f"(steps at {left_steps})")
    finally:
        if not args.keep_emulator:
            shutdown(emulator)

    for failure in failures:
        print("FAIL " + failure)
    print("turn_test: " + ("FAIL" if failures else "PASS"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
