#!/usr/bin/env python3
"""Accelerating cursor-key aim turn (game/aim.s): staged throttle ramp.

Boots PocketFever.dsk in AmSpiriT-Lite and holds a cursor key through the
real keyboard matrix, checking gaim_index's step timing against the exact
model in tools/turn_model.py.

Timing note, twice over:
  * samples are keyed on game_loop_count deltas, NOT on counting Lua
    wait_frames(0) calls -- wait_frames(0) does not reliably advance exactly
    one real game-loop iteration per call (confirmed against game_loop_count,
    the trustworthy clock: an early version of this test that counted its
    own wait_frames(0) calls saw step gaps inflated by a consistent amount
    and looked like a ramp bug, until game_loop_count showed the ramp was
    exact all along).
  * every check here verifies "does the OBSERVED index match what the model
    predicts for the loop count I actually sampled", not "did I see a step
    happen at the expected loop count" -- because a wait_frames(0) call can
    also advance MORE than one real loop (compensating elsewhere), a fast-
    stage sample can land past a step without the polling loop ever directly
    observing that specific transition. Asking "is this state consistent
    with the model" is robust to a skipped sample; asking "did I see this
    exact transition" is not, and an earlier version of this test that
    watched for transitions directly was intermittently flaky for exactly
    this reason.
See CLAUDE.md's "Aiming and shot" section.

Checks:
  * holding Right tracks tools/turn_model.steps_completed exactly, sampled
    throughout all four ramp stages;
  * a brief tap (shorter than AIM_TURN_H1) never exceeds one step -- it must
    not accidentally ride a faster stage from a stale hold counter;
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
from turn_model import DIRECTIONS, steps_completed, throttle_at  # noqa: E402

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


def sample_hold(sym, press, hold_loops):
    """Holds `press` for `hold_loops` game-loop iterations (measured on
    game_loop_count), sampling (loop, gaim_index) every real loop the polling
    happens to land on. Returns the list of (loop, idx) pairs -- NOT
    necessarily one per loop, since wait_frames(0) can skip some."""
    out = wait_lua(
        f"local function loops() local r = cpc.getRam({sym['game_loop_count']}, 2) "
        f"return r:byte(1) + 256 * r:byte(2) end\n"
        f"keyboard_write({press})\n"
        f"local start = loops()\n"
        f"local out = {{}}\n"
        f"while loops() - start <= {hold_loops} do\n"
        f"  wait_frames(0)\n"
        f"  local d = loops() - start\n"
        f"  out[#out + 1] = string.format('%d:%d', d, cpc.getRam({sym['gaim_index']}, 1):byte(1))\n"
        f"end\n"
        f"keyboard_write({RELEASE})\n"
        f"print(table.concat(out, ' '))\n")
    pairs = []
    for token in out.split():
        if ":" not in token:
            continue
        loop, idx = token.split(":")
        pairs.append((int(loop), int(idx)))
    return pairs


def verify_ramp(samples, start_index, sign, label, failures, max_steps=None):
    """Checks every (loop, idx) sample against the model, CALIBRATING for
    keyboard-registration latency first rather than assuming it's zero.

    How long a real keypress takes to become visible to the game's own poll
    (cpct_isKeyPressed_asm, scanned once per frame off an interrupt) is a
    host/emulator/platform detail, not something this test should pin an
    exact value to -- measured as low as 1 loop and as high as 2 across runs
    of this very test. What must stay exact is the RAMP ITSELF once it
    starts: step gaps, which stage applies when. So: find the loop of the
    first observed step, use it to infer the registration offset (that loop
    minus the model's AIM_TURN_T0), then verify every sample against
    steps_completed(loop - offset) instead of steps_completed(loop) raw.
    Robust to missing samples (a skipped loop just isn't checked) and to
    the registration offset itself; NOT robust to a wrong value once
    calibrated, which is exactly the failure mode this exists to catch.
    """
    samples = sorted(samples)
    first_step_loop = next((loop for loop, idx in samples if idx != start_index), None)
    if first_step_loop is None:
        failures.append(f"{label}: no step observed at all in {len(samples)} sample(s)")
        return set()
    offset = first_step_loop - AIM_TURN_T0_EXPECT
    bad = []
    seen_steps = set()
    for loop, idx in samples:
        done = steps_completed(loop - offset)
        if max_steps is not None:
            done = min(done, max_steps)
        want = (start_index + sign * done) % DIRECTIONS
        seen_steps.add(done)
        if idx != want:
            bad.append((loop, idx, want, done))
    if bad:
        failures.append(f"{label}: {len(bad)} sample(s) disagree with the model (registration "
                        f"offset calibrated at {offset} loops), e.g. {bad[:5]} (loop, observed "
                        f"idx, expected idx, steps so far)")
    return seen_steps


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
        start_index = int(wait_lua(f"print(cpc.getRam({sym['gaim_index']}, 1):byte(1))").split()[-2])

        # --- 1. full ramp matches the model across all four stages ----------
        loops = 170
        samples = sample_hold(sym, PRESS_RIGHT, loops)
        seen_steps = verify_ramp(samples, start_index, +1, "ramp", failures)
        expected_total = steps_completed(loops)
        if max(seen_steps, default=-1) < expected_total - 1:
            failures.append(f"ramp: samples only ever reached step count "
                            f"{max(seen_steps, default=None)}, expected to reach close to "
                            f"{expected_total} over {loops} loops -- looks like the hold "
                            f"stopped advancing, not just a missed sample")
        else:
            print(f"ramp matches turn_model.py over {loops} loop iterations "
                 f"({len(samples)} samples, {expected_total} steps expected)")

        # --- 2. a brief tap never exceeds the slowest stage's single step ---
        wait_lua("wait_frames(2)")
        start_index = int(wait_lua(f"print(cpc.getRam({sym['gaim_index']}, 1):byte(1))").split()[-2])
        tap_loops = 10   # well under AIM_TURN_H1; steps_completed(10) with T0=6 is 1
        tap = sample_hold(sym, PRESS_RIGHT, tap_loops)
        verify_ramp(tap, start_index, +1, "tap", failures)

        # --- 3. release resets the ramp: re-holding starts slow again -------
        wait_lua("wait_frames(2)")
        long_hold = 60      # reach the fast stage
        sample_hold(sym, PRESS_RIGHT, long_hold)
        wait_lua("wait_frames(9)")  # release, let it stay released a while
        start_index = int(wait_lua(f"print(cpc.getRam({sym['gaim_index']}, 1):byte(1))").split()[-2])
        second = sample_hold(sym, PRESS_RIGHT, 10)
        verify_ramp(second, start_index, +1, "post-release", failures)

        # --- 4. reversing direction without releasing also resets the ramp --
        # Checked by re-deriving the model FROM the moment of the switch,
        # separately for the (short) tail of right-steps that can legitimately
        # still land after the keypress due to the same keyboard-scan latency
        # documented throughout this project, and for the left-steps that
        # follow -- the left side must restart at AIM_TURN_T0, not inherit
        # the fast stage the right-hold had reached.
        wait_lua("wait_frames(2)")
        out = wait_lua(
            f"local function idx() return cpc.getRam({sym['gaim_index']}, 1):byte(1) end\n"
            f"local function loops() local r = cpc.getRam({sym['game_loop_count']}, 2) "
            f"return r:byte(1) + 256 * r:byte(2) end\n"
            f"keyboard_write({PRESS_RIGHT})\n"
            f"local t0 = loops()\n"
            f"while loops() - t0 < 41 do wait_frames(0) end\n"   # ride into the fast stage
            f"keyboard_write({PRESS_LEFT})\n"
            f"local t1 = loops()\n"
            f"local start = idx()\n"
            f"local out = {{}}\n"
            f"while loops() - t1 <= 12 do\n"
            f"  wait_frames(0)\n"
            f"  out[#out + 1] = string.format('%d:%d', loops() - t1, idx())\n"
            f"end\n"
            f"print('START=' .. start)\n"
            f"keyboard_write({RELEASE})\n"
            f"print(table.concat(out, ' '))\n")
        switch_start = int(out.split("START=")[1].split()[0])
        samples4 = sorted(tuple(int(v) for v in tok.split(":")) for tok in out.split() if ":" in tok)
        # A right-step can still land right at the switch (scan latency), so
        # the first LEFT step doesn't necessarily take idx straight below
        # switch_start -- it might first just cancel a trailing right-step
        # back to switch_start exactly. Detect the first left step as the
        # first sample-to-sample DECREASE, not as a fixed target value.
        first_left_loop = None
        last_idx = switch_start
        max_forward = 0
        for loop, idx in samples4:
            delta = (idx - last_idx) % DIRECTIONS
            if delta not in (0, 1):   # a decrease (mod DIRECTIONS): a left step happened
                first_left_loop = loop
                break
            last_idx = idx
            max_forward = max(max_forward, (idx - switch_start) % DIRECTIONS)
        if first_left_loop is None:
            failures.append(f"direction reversal: never saw a left (decrementing) step within "
                            f"12 loops of switching -- samples: {samples4}")
        elif first_left_loop < AIM_TURN_T0_EXPECT - 2:
            failures.append(f"direction reversal: first left step observed at loop "
                            f"{first_left_loop}, expected around {AIM_TURN_T0_EXPECT} -- looks "
                            f"like the fast stage from the earlier right-hold carried over "
                            f"instead of the ramp restarting (samples: {samples4})")
        elif first_left_loop > AIM_TURN_T0_EXPECT + 4:
            failures.append(f"direction reversal: first left step observed at loop "
                            f"{first_left_loop}, expected around {AIM_TURN_T0_EXPECT} -- slower "
                            f"than a fresh ramp should be (samples: {samples4})")
        # Right must not keep advancing far past the switch (a stray step or
        # two from scan latency is fine; a whole extra ramp's worth is not).
        if max_forward > 2:
            failures.append(f"direction reversal: Right advanced {max_forward} steps past the "
                            f"switch point {switch_start} before any left step -- Right should "
                            f"stop firing almost immediately (samples: {samples4})")

        # --- 5. Left decrements and wraps at the 0/63 boundary ---------------
        # Release + settle first: guarantee gaim_turn_dir/hold/tick are back to
        # 0 (gaim_read_turn_keys's "neither held" branch) before this check,
        # rather than trusting whatever state the previous section left.
        wait_lua(f"keyboard_write({RELEASE})\nwait_frames(4)\n"
                f"cpc.setRam({sym['gaim_index']}, string.char(0))\nwait_frames(2)\n")
        left_samples = sample_hold(sym, PRESS_LEFT, 8)
        verify_ramp(left_samples, 0, -1, "left-wrap", failures)
        final_idx = int(wait_lua(f"print(cpc.getRam({sym['gaim_index']}, 1):byte(1))").split()[-2])
        if final_idx != DIRECTIONS - 1:
            failures.append(f"left from index 0 should wrap to {DIRECTIONS - 1}, got {final_idx}")
    finally:
        if not args.keep_emulator:
            shutdown(emulator)

    for failure in failures:
        print("FAIL " + failure)
    print("turn_test: " + ("FAIL" if failures else "PASS"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
