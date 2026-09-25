#!/usr/bin/env python3
"""Compare friction models for sys/physics.s on a free-rolling ball.

Integer 8.8 arithmetic, as the Z80 does it. For every direction in
src/game/shot_table.s and every shot power, a ball rolls from rest-free space
until it stops (no cushions). Reported per model:

  drift   worst angle, in screen degrees, between the launch direction and the
          direction of the last TAIL raster lines of travel (the "weird curve")
  bend    worst angle between the launch direction and the straight line from
          start to the final resting point
  dist    rolled distance on screen (raster lines) for the strongest shot
  frames  frames until the strongest shot stops

Screen space: one x pixel = PIXEL_ASPECT raster lines (mode 0).

Usage: python3 tools/friction_model.py
"""
import math
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
PIXEL_ASPECT = 2 * 132 / 160
POWERS = range(8, 17)
TAIL = 10


def directions():
    text = (ROOT / "src" / "game" / "shot_table.s").read_text()
    return [tuple(int(v) for v in m) for m in re.findall(r"\.dw\s+(-?\d+),\s+(-?\d+)", text)]


def per_axis(f):
    """Current code: subtract f from each component, snap at zero."""
    def step(vx, vy, state):
        def one(v):
            if v > 0:
                return max(0, v - f)
            if v < 0:
                return min(0, v + f)
            return 0
        return one(vx), one(vy), state
    return step


def along_direction(f):
    """Linear friction f along the velocity. The dominant axis loses f; the
    other loses f*minor/major, with the remainder carried in a per-ball 8-bit
    fraction accumulator (1/256 units) so no ratio is lost to rounding."""
    def step(vx, vy, acc):
        ax, ay = abs(vx), abs(vy)
        if ax == 0 and ay == 0:
            return 0, 0, 0
        if ax >= ay:
            major, minor = ax, ay
        else:
            major, minor = ay, ax
        # Same steps as sys_physics_friction: 8-bit fraction minor/major
        # (256 when equal), times f, plus the carried remainder.
        ratio = 256 if minor == major else (minor * 256) // major
        share = f * ratio + acc
        dec_minor, acc = share >> 8, share & 255
        new_major = max(0, major - f)
        new_minor = max(0, minor - dec_minor)
        if new_major == 0:
            new_minor, acc = 0, 0
        if ax >= ay:
            nx, ny = new_major, new_minor
        else:
            nx, ny = new_minor, new_major
        return (nx if vx >= 0 else -nx), (ny if vy >= 0 else -ny), acc
    return step


def settle(vx, vy, f, x=0, y=0):
    """Final 8.8 position and frame count of one free ball, exactly as the
    game computes it (friction, then integrate). Used by tests/physics_test.py."""
    model, acc, frames = along_direction(f), 0, 0
    while (vx or vy) and frames < 5000:
        vx, vy, acc = model(vx, vy, acc)
        x, y = x + vx, y + vy
        frames += 1
    return x, y, frames


def roll(model, dx, dy, power):
    vx, vy, state = dx * power, dy * power, 0
    x, y = 0, 0                  # 8.8 positions
    track = [(0, 0)]
    frames = 0
    while (vx or vy) and frames < 5000:
        vx, vy, state = model(vx, vy, state)
        x, y = x + vx, y + vy
        frames += 1
        pixel = (x >> 8, y >> 8)
        if pixel != track[-1]:
            track.append(pixel)
    return track, frames


def screen_angle(dx, dy):
    return math.degrees(math.atan2(dy, dx * PIXEL_ASPECT))


def diff(a, b):
    d = (a - b + 180) % 360 - 180
    return abs(d)


def evaluate(model):
    drift = bend = 0.0
    far = frames_max = 0
    for dx, dy in directions():
        launch = screen_angle(dx, dy)
        for power in POWERS:
            track, frames = roll(model, dx, dy, power)
            if len(track) < 3:
                continue
            # Direction over the last ~TAIL screen lines of travel: a single
            # pixel step is always axis-aligned, so it says nothing.
            ex, ey = track[-1]
            back = next(((px, py) for px, py in reversed(track)
                         if math.hypot((ex - px) * PIXEL_ASPECT, ey - py) >= TAIL), track[0])
            end_dir = screen_angle(ex - back[0], ey - back[1])
            drift = max(drift, diff(end_dir, launch))
            fx, fy = track[-1]
            bend = max(bend, diff(screen_angle(fx, fy), launch))
            if power == max(POWERS):
                far = max(far, math.hypot(fx * PIXEL_ASPECT, fy))
                frames_max = max(frames_max, frames)
    return drift, bend, far, frames_max


def main():
    models = [("per-axis f=6 (V.011)", per_axis(6)), ("per-axis f=4", per_axis(4))]
    models += [(f"along-direction f={f}", along_direction(f)) for f in (6, 5, 4, 3)]
    print(f"{'model':24} {'drift':>7} {'bend':>7} {'dist':>7} {'frames':>7}")
    for name, model in models:
        drift, bend, far, frames = evaluate(model)
        print(f"{name:24} {drift:6.1f}° {bend:6.1f}° {far:7.0f} {frames:7d}")


if __name__ == "__main__":
    main()
