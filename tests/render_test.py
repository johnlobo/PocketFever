#!/usr/bin/env python3
"""Regression test: every ball on the felt is visible on the real display,
AND its rounded shape (tools/gen_ball_blit.py's SHAPE) is exactly right --
felt-coloured corners, ball-coloured everything else -- at Y phases that
exercise every branch of the generated blit's row-stepping (even/odd Y,
and Y&7==7, the character-row-crossing case).

Boots PocketFever.dsk in AmSpiriT-Lite and checks the emulator's screenshot
(what the CRT beam actually drew), not video RAM. V.005-V.007 kept the balls in
video RAM, but the main loop erased them right after VSYNC and redrew them
~14 ms later, after physics + collision. By then the beam had already scanned
the felt, so the balls were never on screen.

The pen->RGB mapping comes from the live Gate Array palette, and the screen
geometry comes from the felt's bounding box, so nothing about the
emulator's scaling is hard-coded.

Usage: python3 tests/render_test.py [--keep-emulator]
Needs a built game (make) and nothing else listening on 127.0.0.1:6128.
"""
import argparse
import pathlib
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "tools"))
from gen_ball_blit import SHAPE  # noqa: E402

from amspirit import (BALL_COUNT, ENTITY_SIZE, boot, config_value, get, post, ram,
                      screenshot, shutdown, symbols)

SHOTS = 4


def nearest_pen(rgb, palette):
    return min(range(len(palette)),
               key=lambda pen: sum((a - b) ** 2 for a, b in zip(rgb, palette[pen])))


def felt_box(rows, colour):
    xs, ys = [], []
    for y, row in enumerate(rows):
        for x, rgb in enumerate(row):
            if rgb == colour:
                xs.append(x)
                ys.append(y)
    if not xs:
        return None
    return min(xs), min(ys), max(xs) + 1, max(ys) + 1


def expected_pen(dx, dy, ball_pen, felt_pen):
    """SHAPE's own pixel at (dx, dy): 'X' -> the ball's pen, '.' -> felt."""
    return ball_pen if SHAPE[dy][dx] == "X" else felt_pen


def check_shape(rows, palette, x0, y0, sx, sy, top, ball_id, x, y, pen, felt_pen, label):
    wrong = []
    left = x & ~1            # mode 0: the blit starts on the byte holding x
    for dy in range(config_value("BALL_HEIGHT_PX")):
        for dx in range(config_value("BALL_WIDTH_PX")):
            want = expected_pen(dx, dy, pen, felt_pen)
            px = int(x0 + (left + dx + 0.5) * sx)
            py = int(y0 + (y - top + dy + 0.5) * sy)
            got = nearest_pen(rows[py][px], palette)
            if got != want:
                wrong.append((dx, dy, want, got))
    if wrong:
        return [f"{label}: ball {ball_id} at ({x},{y}) pen {pen}: {len(wrong)}/"
               f"{config_value('BALL_WIDTH_PX') * config_value('BALL_HEIGHT_PX')} pixels wrong "
               f"vs SHAPE, e.g. {wrong[:5]} (dx,dy,want_pen,got_pen)"]
    return []


def check_shot(balls, palette, felt_pen, shot_number):
    width_px, height_px = config_value("TABLE_WIDTH_PX"), config_value("TABLE_HEIGHT_PX")
    top = config_value("TABLE_Y_PX")
    _, _, rows = screenshot()
    box = felt_box(rows, palette[felt_pen])
    if not box:
        return [f"shot {shot_number}: no felt on screen"]
    x0, y0, x1, y1 = box
    sx, sy = (x1 - x0) / width_px, (y1 - y0) / height_px
    failures = []
    for ball_id, x, y, pen in balls:
        failures += check_shape(rows, palette, x0, y0, sx, sy, top, ball_id, x, y, pen,
                                felt_pen, f"shot {shot_number}")
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--keep-emulator", action="store_true")
    args = parser.parse_args()

    def wait_lua(source, timeout=30):
        wait_lua.n += 1
        marker = f"__RT_DONE_{wait_lua.n}__"
        if not post("/api/script?lang=lua", source + f'\nprint("{marker}")\n', "text/plain")["ok"]:
            sys.exit("emulator refused the Lua script")
        deadline = time.time() + timeout
        while time.time() < deadline:
            state = get("/api/script")
            if not state["running"] and marker in state["output"]:
                return state["output"]
            time.sleep(0.2)
        sys.exit("Lua script did not finish in time")
    wait_lua.n = 0

    array = symbols("entity_array")["entity_array"]
    felt_pen = config_value("FELT_PEN")
    table_y = config_value("TABLE_Y_PX")
    emulator = boot()
    try:
        pool = ram(array, BALL_COUNT * ENTITY_SIZE)
        balls = []
        for slot in range(BALL_COUNT):
            e = pool[slot * ENTITY_SIZE:(slot + 1) * ENTITY_SIZE]
            balls.append((e[11], e[2], e[4], e[12]))   # id, x px, y px, pen
        # A ball in the felt pen would "pass" without ever being drawn.
        for ball_id, _, _, pen in balls:
            if pen == felt_pen:
                sys.exit(f"ball {ball_id} uses the felt pen; visibility cannot be tested")
        palette = [((v >> 16) & 255, (v >> 8) & 255, v & 255) for v in get("/api/ga")["ink_rgb"]]
        failures = []
        for shot in range(1, SHOTS + 1):
            failures += check_shot(balls, palette, felt_pen, shot)
            time.sleep(0.7)

        # --- shape at controlled Y phases: even, odd, and the character-row
        # crossing (rel_y & 7 == 7, the row right before sys_ball_blit_draw's
        # generated wrap-fixup branch fires) -- tools/gen_ball_blit.py's row
        # stepping is the part most likely to break subtly (a wrong 0xC050
        # constant would only show up crossing a character row, not on an
        # ordinary line). Slot 3 (a rack ball, id known from ball_templates)
        # moved well clear of every other ball so nothing else overlaps it.
        rel_y_even = 0
        rel_y_odd = 1
        rel_y_cross = 7  # last line of a character-row block
        cases = [(120, table_y + rel_y_even, "even Y"),
                (60, table_y + rel_y_odd, "odd Y"),
                (100, table_y + rel_y_cross, "Y&7==7 (character-row crossing)")]
        pen3 = pool[3 * ENTITY_SIZE + 12]
        for x, y, label in cases:
            wait_lua(f"cpc.setRam({array} + 3 * {ENTITY_SIZE} + 1, "
                    f"string.char(0, {x}, 0, {y}, 0, 0, 0, 0))\n"
                    f"cpc.setRam({array} + 3 * {ENTITY_SIZE} + 13, string.char(2, 0))\n"
                    f"wait_frames(2)\n")
            _, _, rows = screenshot()
            box = felt_box(rows, palette[felt_pen])
            if not box:
                failures.append(f"{label}: no felt on screen")
                continue
            x0, y0, x1, y1 = box
            sx = (x1 - x0) / config_value("TABLE_WIDTH_PX")
            sy = (y1 - y0) / config_value("TABLE_HEIGHT_PX")
            failures += check_shape(rows, palette, x0, y0, sx, sy, table_y, 3, x, y, pen3,
                                    felt_pen, label)
    finally:
        if not args.keep_emulator:
            shutdown(emulator)
    for line in failures:
        print("FAIL " + line)
    if failures:
        print("render_test: FAIL")
        return 1
    print(f"render_test: PASS ({BALL_COUNT} balls visible in {SHOTS} screenshots, "
         f"shape verified at even/odd/character-row-crossing Y)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
