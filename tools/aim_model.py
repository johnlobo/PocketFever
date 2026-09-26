#!/usr/bin/env python3
"""Model for the XOR aim line (game/aim.s): dash placement with cushion bounce.

Same integer 8.8 arithmetic as the Z80: dash i's offset from the cue ball's
CENTER is shot_directions[index] * (AIM_STEP_MULT * i), high byte only. Since
V.016 the line no longer stops at the felt edge: each axis of the running
CENTER position is independently reflected (a triangle wave) inside the
ball-center's legal range on that axis, mirroring how a real launched ball
bounces off a cushion (sys/physics.s clamps position to the cushion and
negates that axis's velocity). Unlike physics, which is stepped once per
frame and can lose a fractional pixel of "overshoot" past the wall on the
frame it clamps, this reflection is exact for any distance -- acceptable
because this is a preview line, not the physical simulation, and a
perfectly-reflected preview is if anything a *better* guide to where the
ball will end up than a lossy one would be.

Crossing a ball's own drawn box is still safe: sys/entity.s skips erase/draw
entirely for any ball that hasn't moved, and the line is only ever shown
while every ball is settled (gaim_all_still). The one invariant that keeps
XOR draw/erase lossless is that nothing ELSE redraws a touched pixel between
one draw and its matching erase, which the settled-ball skip guarantees
regardless of where the dashes land or how many times the line has bounced.

This script exists to size AIM_STEP_MULT/AIM_DASH_COUNT/AIM_DASH_PX and the
ball size before writing the Z80, and is the reference tests/aim_test.py
checks the real build against.

Usage: python3 tools/aim_model.py
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent


def config(name):
    text = (ROOT / "src" / "config.h.s").read_text()
    return int(re.search(rf"^\s*{name}\s*=\s*(\d+)", text, re.M).group(1))


def directions():
    text = (ROOT / "src" / "game" / "shot_table.s").read_text()
    return [tuple(int(v) for v in m) for m in re.findall(r"\.dw\s+(-?\d+),\s+(-?\d+)", text)]


def reflect(pos, lo, hi):
    """Fold `pos` into [lo, hi] by mirror reflection (triangle wave), the
    same rule sys/physics.s applies one axis at a time when a ball's
    position would cross a cushion: bounce back in, don't wrap or clip."""
    span = hi - lo
    if span <= 0:
        return lo
    period = 2 * span
    m = (pos - lo) % period
    if m > span:
        m = period - m
    return lo + m


def dash_points(index, cue_x, cue_y, step_mult, dash_count, dash_px, ball_w, ball_h,
                table_w, table_y, table_h):
    """Returns the list of dash top-left pixels drawn for this direction.
    The line never stops early: each axis of the running center position
    bounces off its own legal range (ball-center clearance from the felt
    edge on that axis) independently, exactly like a rectangular billiard
    reflecting off a straight cushion."""
    dx, dy = directions()[index]
    cx, cy = cue_x * 256 + (ball_w // 2) * 256, cue_y * 256 + (ball_h // 2) * 256
    x_lo, x_hi = ball_w // 2, table_w - ball_w // 2
    y_lo, y_hi = table_y + ball_h // 2, table_y + table_h - ball_h // 2
    points = []
    for i in range(1, dash_count + 1):
        px = (cx + dx * step_mult * i) >> 8
        py = (cy + dy * step_mult * i) >> 8
        px = reflect(px, x_lo, x_hi)
        py = reflect(py, y_lo, y_hi)
        points.append((px - dash_px // 2, py - dash_px // 2))
    return points


def max_raw_magnitude(step_mult, dash_count):
    """Largest |dx*step_mult*i| the Z80's 16-bit signed accumulator must
    hold before the high byte is read back -- must stay well under 32768 or
    the running total wraps and reflect() would fold the wrong value."""
    dirs = directions()
    peak = max(abs(v) for pair in dirs for v in pair)
    return peak * step_mult * dash_count


def max_pixel_offset(step_mult, dash_count, axis):
    """Largest |pixel offset from center| any dash can reach on one axis --
    the input to reflect() before folding."""
    dirs = directions()
    peak = max(abs(pair[axis]) for pair in dirs)
    return (peak * step_mult * dash_count) >> 8


def check_single_wrap_margin(step_mult, dash_count, span, period, axis, label):
    """gaim_reflect_axis (aim.s) folds with a single conditional add-period
    (if the offset pushed pos negative) and never needs a second add or any
    subtract-period, because it assumes m = pos-lo never lands outside
    (-period, period) to begin with. pos = center (already in [lo,hi], so
    m0 in [0,span]) plus an offset bounded by max_pixel_offset(). Assert the
    real margin here so a future constant bump that breaks this assumption
    fails loudly in Python, not silently in Z80."""
    offset = max_pixel_offset(step_mult, dash_count, axis)
    worst_low = 0 - offset          # most negative m can get
    worst_high = span + offset      # most positive m can get
    assert worst_low > -period, (
        f"{label}: offset {offset}px could need more than one wrap "
        f"(m as low as {worst_low}, period {period})")
    assert worst_high < period, (
        f"{label}: offset {offset}px could push m past a full period "
        f"(m as high as {worst_high}, period {period}) -- gaim_reflect_axis "
        f"would need a second fold")
    return offset, worst_low, worst_high


def main():
    ball_w, ball_h = config("BALL_WIDTH_PX"), config("BALL_HEIGHT_PX")
    table_w, table_y, table_h = config("TABLE_WIDTH_PX"), config("TABLE_Y_PX"), config("TABLE_HEIGHT_PX")
    cue = (120, 131 - 6 + ball_h)  # game/table.s ball_cue's actual top-left, ball_h-dependent
    count = len(directions())
    step_mult, dash_count, dash_px = config("AIM_STEP_MULT"), config("AIM_DASH_COUNT"), config("AIM_DASH_PX")

    peak_raw = max_raw_magnitude(step_mult, dash_count)
    print(f"ball {ball_w}x{ball_h}  step_mult={step_mult}  dash_count={dash_count}  dash_px={dash_px}")
    print(f"peak raw accumulator magnitude: {peak_raw} (16-bit signed headroom: 32767)")
    assert peak_raw < 32767, "accumulator would overflow/wrap -- lower step_mult or dash_count"

    # x_lo/x_hi/y_lo/y_hi mirror config.h.s's AIM_X_LO/HI, AIM_Y_LO/HI exactly
    # (BALL_WIDTH_PX/HEIGHT_PX and TABLE_* are plain numeric literals config()
    # can read; AIM_X_SPAN/PERIOD etc. are arithmetic expressions in
    # config.h.s, not literals, so they're recomputed here from the same
    # literals rather than parsed back out).
    x_lo, x_hi = ball_w // 2, table_w - ball_w // 2
    x_span, x_period = x_hi - x_lo, 2 * (x_hi - x_lo)
    y_lo, y_hi = table_y + ball_h // 2, table_y + table_h - ball_h // 2
    y_span, y_period = y_hi - y_lo, 2 * (y_hi - y_lo)
    for axis, (span, period, label) in enumerate([(x_span, x_period, "x"), (y_span, y_period, "y")]):
        offset, worst_low, worst_high = check_single_wrap_margin(step_mult, dash_count, span, period, axis, label)
        print(f"axis {label}: span={span} period={period} peak offset={offset}px  "
              f"m range [{worst_low}, {worst_high}] within (-{period}, {period}) -- single-wrap fold OK")

    total_arc = 0
    bounces_seen = 0
    for index in range(count):
        points = dash_points(index, *cue, step_mult, dash_count, dash_px, ball_w, ball_h,
                              table_w, table_y, table_h)
        # Count direction reversals in consecutive dash-to-dash deltas as a
        # proxy for "this direction bounced at least once in dash_count dashes".
        deltas = [(b[0] - a[0], b[1] - a[1]) for a, b in zip(points, points[1:])]
        for (ax, ay), (bx, by) in zip(deltas, deltas[1:]):
            if (ax * bx < 0) or (ay * by < 0):
                bounces_seen += 1
                break
        fx, fy = points[0]
        lx, ly = points[-1]
        total_arc += ((lx - fx) ** 2 + (ly - fy) ** 2) ** 0.5

    last_dash_arc_length = step_mult * dash_count  # raw units, direction-vector magnitude ~1 in 8.8
    print(f"{bounces_seen}/{count} directions show a cushion bounce within {dash_count} dashes")
    print(f"nominal reach (unbounced arc length to the last dash) scales with step_mult*dash_count "
          f"= {last_dash_arc_length} raw units")

    # Compare against the pre-V.016 baseline (ball 4x6, step_mult=40, count=5)
    # to confirm the +50% target.
    old_arc = 40 * 5
    print(f"baseline (V.015) arc length was 40*5={old_arc}; new is {last_dash_arc_length} "
          f"({100 * (last_dash_arc_length - old_arc) / old_arc:+.0f}%)")


if __name__ == "__main__":
    main()
