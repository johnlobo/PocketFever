#!/usr/bin/env python3
"""Model for accelerating cursor-key aim turning (game/aim.s).

Holding a cursor key steps gaim_index once every THROTTLE frames. A flat
THROTTLE trades precision against full-turn time: slow enough to place a
single step exactly, but then a 64-step revolution takes forever, or fast
enough to spin around quickly, but then you overshoot the direction you
wanted by several steps.

This models a staged ramp instead: THROTTLE starts high (precise) and drops
in stages the longer the key stays held, floored at a fast minimum. The
stages are a plain list of (held-frames threshold, throttle) pairs, checked
low members first -- easy to reproduce with a handful of Z80 compares, no
division. Tune STAGES here, verify with `python3 tools/turn_model.py`, then
copy the numbers into src/config.h.s.

Usage: python3 tools/turn_model.py
"""

# (min frames continuously held, throttle at that point). Must be sorted by
# threshold ascending; the last entry's throttle is the floor.
STAGES = [
    (0, 6),     # tap or brief hold: one step per 6 frames (~120 ms), fine control
    (18, 4),    # ~0.36 s in:  one step per 4 frames (~80 ms)
    (36, 2),    # ~0.72 s in:  one step per 2 frames (~40 ms)
    (60, 1),    # ~1.2 s in:   one step per frame (~20 ms), full speed
]
DIRECTIONS = 64
FRAME_MS = 20


def throttle_at(held_frames):
    level = STAGES[0][1]
    for threshold, throttle in STAGES:
        if held_frames >= threshold:
            level = throttle
    return level


def steps_completed(held_loops):
    """How many steps have fired after `held_loops` continuous held frames
    (0 for held_loops<=0). Complements simulate(): that asks "how many frames
    for N steps", this asks "how many steps in N frames" -- used to verify a
    single observed sample against the model without needing to have caught
    every individual step transition (a poll can skip one)."""
    if held_loops <= 0:
        return 0
    held, tick, done = 0, 0, 0
    for _ in range(held_loops):
        held += 1
        tick += 1
        if tick >= throttle_at(held):
            tick = 0
            done += 1
    return done


def simulate(steps):
    """Frames to complete `steps` index changes, holding the whole time."""
    held, frame, done = 0, 0, 0
    tick = 0
    while done < steps:
        frame += 1
        held += 1
        tick += 1
        if tick >= throttle_at(held):
            tick = 0
            done += 1
    return frame


def main():
    print(f"{'held(frames)':>14} {'throttle':>9} {'steps/s':>8}")
    seen = set()
    for threshold, throttle in STAGES:
        if throttle in seen:
            continue
        seen.add(throttle)
        print(f"{threshold:>14} {throttle:>9} {1000 / (throttle * FRAME_MS):>7.1f}")

    one_step = simulate(1)
    quarter = simulate(DIRECTIONS // 4)
    full = simulate(DIRECTIONS)
    print(f"\na single tap (1 step): {one_step} frame(s), {one_step * FRAME_MS} ms "
          f"-- must equal STAGES[0]'s throttle exactly, or a tap already rides the ramp")
    print(f"quarter turn ({DIRECTIONS // 4} steps) held continuously: "
          f"{quarter} frames, {quarter * FRAME_MS} ms")
    print(f"full turn ({DIRECTIONS} steps) held continuously: "
          f"{full} frames, {full * FRAME_MS} ms")

    flat_full = DIRECTIONS * STAGES[0][1]
    print(f"\nfor comparison, flat throttle={STAGES[0][1]} (no ramp) the whole way: "
          f"full turn = {flat_full} frames, {flat_full * FRAME_MS} ms")


if __name__ == "__main__":
    main()
