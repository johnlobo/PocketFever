#!/usr/bin/env python3
"""Live ANGLE/POWER HUD readout (game/hud.s): correctness and performance.

Boots PocketFever.dsk in AmSpiriT-Lite. Doesn't decode the rendered glyphs
pixel-by-pixel (that would mean reimplementing the font's masked-blit
encoding in Python); instead locks in the two real bugs found building this
feature, both of which are easy to check without a full font decoder:

1. A wrong colour-table index (passing a raw CPC pen number instead of an
   index into sys/text.s's _swapColors) made the number field render a
   garbled mix of glyphs that never actually changed on screen -- checked
   here by confirming the field's video-memory BYTES actually change when
   the underlying value does (a stuck-at-first-value field, garbled or not,
   would leave these bytes constant).
2. Redrawing ANGLE every held frame while continuously turning cost far
   more than sys_text_draw_string's documented per-call time, severely
   enough to drop real game-loop iterations (confirmed via game_loop_count:
   100 emulated frames held only completed 51 real loops) -- checked here
   directly via the same measurement, and via the gate that fixed it
   (ANGLE must NOT change on screen while a cursor key is held, only once
   it's released).

Usage: python3 tests/hud_test.py [--keep-emulator]
"""
import argparse
import sys
import time

from amspirit import boot, config_value, get, post, ram, shutdown, symbols

PRESS_RIGHT = "253, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255"
PRESS_SPACE = "255, 255, 255, 255, 255, 127, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255"
RELEASE = "255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255"

_calls = [0]


def wait_lua(source, timeout=30):
    """One Lua script, waited out with a marker unique to THIS call -- see
    tests/aim_test.py's own note on why a fixed marker isn't safe here."""
    _calls[0] += 1
    marker = f"__HUD_DONE_{_calls[0]}__"
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


def screen_addr(x_byte, y):
    """CPC mode-0 screen address for a byte-x/pixel-y coordinate, matching
    cpctm_screenPtr_asm's own formula (video_macros-h-s.html)."""
    return 0xC000 + 80 * (y // 8) + 2048 * (y & 7) + x_byte


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--keep-emulator", action="store_true")
    args = parser.parse_args()

    # Byte offsets/row must track src/config.h.s's HUD_* layout constants;
    # duplicated here as literals (same trade-off tests/amspirit.py's
    # config_value() elsewhere avoids for numeric constants, but these are
    # a small, stable, hand-placed layout, unlikely to move silently).
    ROW_Y = 50
    ANGLE_NUM_X = 12
    POWER_NUM_X = 34
    FIELD_WIDTH = 6   # HUD_NUM_WIDTH_BYTES: 3 chars * FONT_WIDTH
    FIELD_ROWS = 9    # FONT_HEIGHT

    def field_bytes(x_byte):
        return b"".join(ram(screen_addr(x_byte, ROW_Y + dy), FIELD_WIDTH) for dy in range(FIELD_ROWS))

    failures = []

    # Regression lock for the colour-index bug (see module docstring): a
    # garbled-but-plausible render turned out to be indistinguishable from a
    # correct one at the byte level in every mutation tried (the "garbage"
    # source turned out to be fully deterministic for a fixed call sequence,
    # not visually random) -- decoding the actual rendered glyphs pixel by
    # pixel would mean reimplementing the font's masked-blit encoding in
    # Python. The honest, direct lock is the constant itself. An earlier
    # version of this check only asserted the range (0-14, sys/text.s's
    # _swapColors has 15 rows) -- an adversarial review mutation-tested that
    # and found it passes for ANY in-range-but-wrong value (e.g. 3 = Orange
    # instead of 0 = White): still a valid table index, still the wrong
    # colour, silently undetected. The constant only has one correct value
    # here (this HUD's text is meant to be white), so pin the exact value,
    # not just its type/range.
    colour = config_value("HUD_TEXT_COLOUR_WHITE")
    if colour != 0:
        failures.append(f"HUD_TEXT_COLOUR_WHITE={colour}, expected 0 (White in "
                        f"sys/text.s's _swapColors index scheme) -- this HUD's text is "
                        f"meant to be white; any other in-range value (1-14) is a real, "
                        f"silently-wrong colour, not just a bounds violation")

    sym = symbols("gaim_index", "gsu_power", "game_loop_count")
    emulator = boot()
    try:
        wait_lua("wait_frames(9)")

        # --- 1. boot: both fields have actually drawn something ------------
        angle_boot = field_bytes(ANGLE_NUM_X)
        power_boot = field_bytes(POWER_NUM_X)
        if angle_boot == b"\x00" * len(angle_boot):
            failures.append("ANGLE field is still all-zero at boot -- nothing drew")
        if power_boot == b"\x00" * len(power_boot):
            failures.append("POWER field is still all-zero at boot -- nothing drew "
                            "(note: an all-zero field is also what a stuck-at-uninitialised "
                            "bug would look like, unlike ANGLE's non-zero default)")

        # --- 2. changing the underlying value actually changes the pixels --
        # Regression lock for the colour-index bug: a garbled-but-frozen
        # field would fail this (bytes never move), even though it isn't a
        # pixel-perfect check of what the digits actually say.
        wait_lua(f"cpc.setRam({sym['gaim_index']}, string.char(64))\nwait_frames(1)\n")
        angle_64 = field_bytes(ANGLE_NUM_X)
        if angle_64 == angle_boot:
            failures.append("ANGLE field bytes didn't change after gaim_index was set to a "
                            "different value (64) -- the redraw isn't taking effect")

        wait_lua(f"cpc.setRam({sym['gaim_index']}, string.char(128))\nwait_frames(1)\n")

        # --- 3. ANGLE is gated: frozen while a cursor key is held ----------
        before_hold = field_bytes(ANGLE_NUM_X)
        wait_lua(f"keyboard_write({PRESS_RIGHT})\nwait_frames(19)\n")  # well into the ramp
        during_hold = field_bytes(ANGLE_NUM_X)
        if during_hold != before_hold:
            failures.append("ANGLE field changed WHILE a cursor key was held -- the "
                            "turning-gate (game/hud.s) isn't suppressing the redraw, which "
                            "is what caused the dropped-frame regression this gate fixes")

        # --- 4. ...but updates to the settled value right after release ----
        wait_lua(f"keyboard_write({RELEASE})\nwait_frames(2)\n")
        idx_after = ram(sym["gaim_index"], 1)[0]
        after_release = field_bytes(ANGLE_NUM_X)
        if idx_after != 128 and after_release == before_hold:
            failures.append(f"ANGLE field didn't update after releasing the cursor key "
                            f"(gaim_index is now {idx_after}, was 128 before the hold)")

        # --- 5. no dropped frames while continuously turning ---------------
        # The regression itself: 100 emulated frames held right used to only
        # complete 51 real game-loop iterations before the turning-gate fix.
        out = wait_lua(
            f"local function loops() local r = cpc.getRam({sym['game_loop_count']}, 2) "
            f"return r:byte(1) + 256 * r:byte(2) end\n"
            f"local t0 = loops()\n"
            f"keyboard_write({PRESS_RIGHT})\n"
            f"wait_frames(99)\n"
            f"keyboard_write({RELEASE})\n"
            f"print('LOOPS=' .. (loops() - t0))\n")
        loops = int(out.split("LOOPS=")[1].split()[0])
        if loops < 98:
            failures.append(f"holding Right for 100 emulated frames only completed {loops} "
                            f"real game-loop iterations (expected ~100) -- the HUD update is "
                            f"dropping frames again")

        # --- 6. POWER updates live while charging, no drops either ---------
        wait_lua("wait_frames(2)")
        power_before = field_bytes(POWER_NUM_X)
        out = wait_lua(
            f"local function loops() local r = cpc.getRam({sym['game_loop_count']}, 2) "
            f"return r:byte(1) + 256 * r:byte(2) end\n"
            f"local t0 = loops()\n"
            f"keyboard_write({PRESS_SPACE})\n"
            f"wait_frames(99)\n"
            f"print('LOOPS=' .. (loops() - t0))\n")
        loops = int(out.split("LOOPS=")[1].split()[0])
        power_now = ram(sym["gsu_power"], 1)[0]
        power_after = field_bytes(POWER_NUM_X)
        wait_lua(f"keyboard_write({RELEASE})\nwait_frames(2)\n")
        if loops < 98:
            failures.append(f"holding SPACE for 100 emulated frames only completed {loops} "
                            f"real game-loop iterations (expected ~100)")
        if power_now > 0 and power_after == power_before:
            failures.append(f"POWER field bytes didn't change after charging to {power_now} "
                            f"-- the redraw isn't taking effect while holding SPACE")
    finally:
        if not args.keep_emulator:
            shutdown(emulator)

    for failure in failures:
        print("FAIL " + failure)
    print("hud_test: " + ("FAIL" if failures else "PASS"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
