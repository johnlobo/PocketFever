#!/usr/bin/env python3
"""Model for the XOR aim line (game/aim.s): dash placement.

Same integer 8.8 arithmetic as the Z80: dash i's offset from the cue ball's
CENTER is shot_directions[index] * (AIM_STEP_MULT * i), high byte only. A
dash is a small AIM_DASH_PXxAIM_DASH_PX XOR box; the line stops only at the
felt edge -- crossing a ball's own drawn box is safe, since sys/entity.s
skips erase/draw entirely for any ball that hasn't moved, and the line is
only ever shown while every ball is settled (gaim_all_still). The one
invariant that keeps XOR draw/erase lossless is that nothing ELSE redraws a
touched pixel between one draw and its matching erase, which the settled-ball
skip guarantees regardless of where the dashes land.

This script exists to size AIM_STEP_MULT/AIM_DASH_COUNT/AIM_DASH_PX before
writing the Z80, and is the reference tests/aim_test.py checks the real
build against.

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


def dash_points(index, cue_x, cue_y, step_mult, dash_count, dash_px, ball_w, ball_h):
    """Returns the list of dash top-left pixels drawn for this direction,
    stopping only when a dash would leave the felt."""
    dx, dy = directions()[index]
    cx, cy = cue_x * 256 + (ball_w // 2) * 256, cue_y * 256 + (ball_h // 2) * 256
    points = []
    for i in range(1, dash_count + 1):
        px = (cx + dx * step_mult * i) >> 8
        py = (cy + dy * step_mult * i) >> 8
        left, top = px - dash_px // 2, py - dash_px // 2
        if not (0 <= left <= config("TABLE_WIDTH_PX") - dash_px
                and config("TABLE_Y_PX") <= top <= config("TABLE_Y_PX") + config("TABLE_HEIGHT_PX") - dash_px):
            break
        points.append((left, top))
    return points


def main():
    ball_w, ball_h = config("BALL_WIDTH_PX"), config("BALL_HEIGHT_PX")
    cue = (120, 131)   # game/table.s ball_cue
    count = len(directions())
    for step_mult, dash_count, dash_px in ((16, 8, 2), (24, 6, 2), (40, 5, 2)):
        min_first, max_reach, short = 999, 0, 0
        for index in range(count):
            points = dash_points(index, *cue, step_mult, dash_count, dash_px, ball_w, ball_h)
            if len(points) < dash_count:
                short += 1
            if not points:
                continue
            fx, fy = points[0]
            min_first = min(min_first, ((fx - cue[0]) ** 2 + (fy - cue[1]) ** 2) ** 0.5)
            lx, ly = points[-1]
            max_reach = max(max_reach, ((lx - cue[0]) ** 2 + (ly - cue[1]) ** 2) ** 0.5)
        print(f"step_mult={step_mult:3d} dash_count={dash_count} dash_px={dash_px}: "
              f"first dash >= {min_first:.1f}px from cue centre, furthest reach {max_reach:.1f}px, "
              f"{short}/{count} directions clipped by the felt edge before {dash_count} dashes")


if __name__ == "__main__":
    main()
