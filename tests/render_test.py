#!/usr/bin/env python3
"""Regression test: every ball on the felt is visible on the real display.

Boots PocketFever.dsk in AmSpiriT-Lite and checks the emulator's screenshot
(what the CRT beam actually drew), not video RAM. V.005-V.007 kept the balls in
video RAM, but the main loop erased them right after VSYNC and redrew them
~14 ms later, after physics + collision. By then the beam had already scanned
the felt, so the balls were never on screen.

For each of several screenshots, every ball's 4x6 pixels must show the ball's
own pen colour. The pen->RGB mapping comes from the live Gate Array palette,
and the screen geometry comes from the felt's bounding box, so nothing about the
emulator's scaling is hard-coded.

Usage: python3 tests/render_test.py [--keep-emulator]
Needs a built game (make) and nothing else listening on 127.0.0.1:6128.
"""
import argparse
import sys
import time

from amspirit import (BALL_COUNT, ENTITY_SIZE, boot, config_value, get, ram,
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


def check_shot(balls, palette, shot_number):
    felt = config_value("FELT_PEN")
    width_px, height_px = config_value("TABLE_WIDTH_PX"), config_value("TABLE_HEIGHT_PX")
    top = config_value("TABLE_Y_PX")
    _, _, rows = screenshot()
    box = felt_box(rows, palette[felt])
    if not box:
        return [f"shot {shot_number}: no felt on screen"]
    x0, y0, x1, y1 = box
    sx, sy = (x1 - x0) / width_px, (y1 - y0) / height_px
    failures = []
    for ball_id, x, y, pen in balls:
        wrong = 0
        left = x & ~1            # mode 0: the blit starts on the byte holding x
        for dy in range(config_value("BALL_HEIGHT_PX")):
            for dx in range(config_value("BALL_WIDTH_PX")):
                px = int(x0 + (left + dx + 0.5) * sx)
                py = int(y0 + (y - top + dy + 0.5) * sy)
                if nearest_pen(rows[py][px], palette) != pen:
                    wrong += 1
        if wrong:
            failures.append(f"shot {shot_number}: ball {ball_id} at ({x},{y}) pen {pen}: "
                            f"{wrong}/24 pixels not its colour")
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--keep-emulator", action="store_true")
    args = parser.parse_args()

    array = symbols("entity_array")["entity_array"]
    emulator = boot()
    try:
        pool = ram(array, BALL_COUNT * ENTITY_SIZE)
        balls = []
        for slot in range(BALL_COUNT):
            e = pool[slot * ENTITY_SIZE:(slot + 1) * ENTITY_SIZE]
            balls.append((e[11], e[2], e[4], e[12]))   # id, x px, y px, pen
        # A ball in the felt pen would "pass" without ever being drawn.
        for ball_id, _, _, pen in balls:
            if pen == config_value("FELT_PEN"):
                sys.exit(f"ball {ball_id} uses the felt pen; visibility cannot be tested")
        palette = [((v >> 16) & 255, (v >> 8) & 255, v & 255) for v in get("/api/ga")["ink_rgb"]]
        failures = []
        for shot in range(1, SHOTS + 1):
            failures += check_shot(balls, palette, shot)
            time.sleep(0.7)
    finally:
        if not args.keep_emulator:
            shutdown(emulator)
    for line in failures:
        print("FAIL " + line)
    if failures:
        print("render_test: FAIL")
        return 1
    print(f"render_test: PASS ({BALL_COUNT} balls visible in {SHOTS} screenshots)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
