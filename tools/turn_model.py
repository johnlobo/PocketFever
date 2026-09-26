#!/usr/bin/env python3
"""Model for accelerating cursor-key aim turning (game/aim.s).

V.017: DIRECTIONS went from 64 to 256 (finer aiming), and the ramp
mechanism changed from THROTTLE (frames between steps, step always 1) to
STEP SIZE (a step happens every held frame, but how many indices it
advances grows the longer the key stays held). A tap always advances
exactly STAGES[0]'s step (1, the finest of the 256 directions); holding
longer ramps the step size up to a fast floor, so a full revolution at the
new 4x finer resolution doesn't take 4x as long to spin through.

The stages are a plain list of (held-frames threshold, step size) pairs,
checked low members first -- easy to reproduce with a handful of Z80
compares, no division, and (since DIRECTIONS=256 is exactly one byte's
range) `add a, step` / `sub a, step` wrap the index automatically, no
masking needed regardless of step size. Tune STAGES here, verify with
`python3 tools/turn_model.py`, then copy the numbers into src/config.h.s.

Usage: python3 tools/turn_model.py
"""

# (min frames continuously held, step size at that point). Must be sorted
# by threshold ascending; the last entry's step is the ceiling. STAGES[0]'s
# threshold must be 0 and its step must be 1 -- a tap (a single held frame)
# has to land on the finest possible step, never ride the ramp.
STAGES = [
    (0, 1),     # tap or brief hold: 1 of 256 directions (1.406 deg), finest
    (20, 2),    # ~0.4 s in
    (45, 4),    # ~0.9 s in: full speed -- 5.625 deg/frame, same top angular
                # rate the old 64-direction ramp topped out at (T3=1 step of
                # 5.625 deg/frame), so a long hold spins exactly as fast as
                # before; only the finer stages below are new
]
DIRECTIONS = 256
FRAME_MS = 20


def step_at(held_frames):
    level = STAGES[0][1]
    for threshold, step in STAGES:
        if held_frames >= threshold:
            level = step
    return level


def steps_completed(held_loops):
    """Total index distance (in the 256-direction space) covered after
    `held_loops` continuous held frames, one step attempted every frame
    (0 for held_loops<=0). Complements simulate(): that asks "how many
    frames to cover N distance", this asks "how far after N frames" --
    used to verify a single observed sample against the model."""
    if held_loops <= 0:
        return 0
    held, total = 0, 0
    for _ in range(held_loops):
        held += 1
        total += step_at(held)
    return total


def simulate(distance):
    """Frames to cover `distance` index units, holding the whole time."""
    held, frame, total = 0, 0, 0
    while total < distance:
        frame += 1
        held += 1
        total += step_at(held)
    return frame


def main():
    assert STAGES[0] == (0, 1), "STAGES[0] must be (0, 1): a tap must land on the finest step"
    for a, b in zip(STAGES, STAGES[1:]):
        assert a[0] < b[0] and a[1] < b[1], f"STAGES must strictly increase: {a} -> {b}"

    print(f"{'held(frames)':>14} {'step':>6} {'deg/step':>9} {'deg/s':>7}")
    seen = set()
    for threshold, step in STAGES:
        if step in seen:
            continue
        seen.add(step)
        deg_per_step = step * 360 / DIRECTIONS
        print(f"{threshold:>14} {step:>6} {deg_per_step:>9.3f} {1000 * deg_per_step / FRAME_MS:>7.1f}")

    one_tap = simulate(1)
    quarter = simulate(DIRECTIONS // 4)
    full = simulate(DIRECTIONS)
    print(f"\na single tap (1 unit of index distance): {one_tap} frame(s), {one_tap * FRAME_MS} ms "
          f"-- must be 1 frame, or a tap doesn't land on exactly 1 of the 256 directions")
    print(f"quarter turn ({DIRECTIONS // 4} units) held continuously: "
          f"{quarter} frames, {quarter * FRAME_MS} ms")
    print(f"full turn ({DIRECTIONS} units) held continuously: "
          f"{full} frames, {full * FRAME_MS} ms")

    flat_full = -(-DIRECTIONS // STAGES[0][1])
    print(f"\nfor comparison, flat step={STAGES[0][1]} (no ramp) the whole way: "
          f"full turn = {flat_full} frames, {flat_full * FRAME_MS} ms")


if __name__ == "__main__":
    main()
