#!/usr/bin/env python3
"""XOR aim line: lossless draw/erase, follows cursor keys, hides while moving.

Boots PocketFever.dsk in AmSpiriT-Lite and drives real cursor-key input
(hardware keyboard matrix, not RAM pokes) plus real screenshots -- this is
the test for the property the feature exists for: showing and hiding the
line must never leave a mark on the felt.

1. Round-trip (the critical check): hold Right for exactly one full 32-step
   revolution (game/aim.s steps gaim_index once per held frame, staged --
   see tests/turn_test.py for the ramp itself), so the game erases and
   redraws the line 32 times over 32 different directions and returns to the
   starting one. A screenshot taken before the turn and one taken after must
   be PIXEL-IDENTICAL. Any XOR corruption at ANY of the 32 intermediate
   directions -- a dash overlapping a ball, a mismatched erase -- leaves a
   stray flipped pixel that a later direction's own draw/erase does not
   touch, so it would still show up in the final image even though the
   final direction matches the first.
2. Geometry: at a chosen direction, the exact dash pixels computed by
   tools/aim_model.py (the same formula the Z80 uses) must show the aim
   colour in a real screenshot -- proves a line is actually drawn, not just
   "nothing crashed".
3. Hides while moving: after firing, gaim_shown (game/aim.s's public state)
   must read 0 while the table is not at rest.
4. Reappears at the new position: once everything stops after a shot,
   gaim_last_cx/cy (also public) must match the cue's new resting spot, not
   the pre-shot one.

Usage: python3 tests/aim_test.py [--keep-emulator]
"""
import argparse
import sys
import time

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent.parent / "tools"))
from aim_model import config, dash_points  # noqa: E402
from turn_model import DIRECTIONS, simulate  # noqa: E402

from amspirit import BALL_COUNT, ENTITY_SIZE, boot, get, post, ram, screenshot, shutdown, symbols

AIM_DEFAULT_INDEX = config("AIM_DEFAULT_INDEX")

PRESS_RIGHT = "253, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255"  # Key_CursorRight=0x0200: row 0, bit 1
RELEASE = "255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255"
PRESS_SPACE = "255, 255, 255, 255, 255, 127, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255"


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
    return min(xs), min(ys), max(xs) + 1, max(ys) + 1


_wait_lua_calls = [0]


def wait_lua(source, timeout=300):
    """Runs a Lua snippet and waits for it to actually finish.

    POST returns before the script starts, so `not state["running"]` alone
    can fire on a poll that lands between the POST and the script actually
    being picked up (confirmed: right after POSTing script N+1, a GET can
    still show running=False with script N's leftover output) -- the same
    gotcha collision_test.py's run_lua guards against with its own "DONE"
    marker. Guarding against it needs the marker to be UNIQUE PER CALL, not
    just present: this function makes many separate script calls per test
    run (unlike run_lua's one-script-per-run pattern), so a fixed marker
    would match the PREVIOUS call's leftover output just as easily as this
    one's -- found by direct experiment, not by inspection.
    """
    _wait_lua_calls[0] += 1
    sentinel = f"__WAIT_LUA_DONE_{_wait_lua_calls[0]}__"
    if not post("/api/script?lang=lua", source + f'\nprint("{sentinel}")\n', "text/plain")["ok"]:
        sys.exit("emulator refused the Lua script")
    deadline = time.time() + timeout
    while time.time() < deadline:
        state = get("/api/script")
        if state["error"]:
            sys.exit("Lua error: " + state["error"])
        if not state["running"] and sentinel in state["output"]:
            return state["output"]
        time.sleep(0.3)
    sys.exit("Lua script did not finish in time")


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--keep-emulator", action="store_true")
    args = parser.parse_args()

    sym = symbols("entity_array", "gaim_index", "gaim_shown", "gaim_last_cx", "gaim_last_cy",
                 "game_loop_count")
    failures = []
    emulator = boot()
    try:
        wait_lua("wait_frames(9)")  # let the default-direction line settle

        # --- 1. round-trip across a full revolution -------------------------
        # Hold for the EXACT number of frames a full revolution takes, per
        # tools/turn_model.py's simulate() (bit-exact against the Z80, per
        # tests/turn_test.py) -- rather than polling for "back to the
        # starting value": once the ramp reaches its fastest stage it steps
        # by up to 2 per wait_frames(1) sample (2 real frames advance, 2
        # steps happen at throttle=1), so a poll landing on the wrong parity
        # can skip straight over the target index and either time out or
        # only stop several extra laps later by chance -- confirmed by hand,
        # the polling version intermittently landed on idx=34 instead of the
        # expected 32. Precomputing the frame count sidesteps parity
        # entirely; game_loop_count is the clock, same as trace_hold in
        # tests/turn_test.py, not the test's own wait_frames(1) call count.
        w, h, before = screenshot()
        # V.017's step-size ramp advances by chunks (1, then 2, then 4 units
        # per frame, tools/turn_model.py) rather than always 1 -- so there is
        # in general NO frame count that lands the cumulative distance on
        # EXACTLY a multiple of DIRECTIONS: steps_completed(91) is 257, one
        # past the 256 a full revolution needs, because the last frame before
        # crossing the threshold adds a full ceiling-sized chunk of 4. This
        # is the model correctly predicting the real Z80 (confirmed: the
        # build lands on index 129, exactly steps_completed(91)=257 past
        # AIM_DEFAULT_INDEX=128, not a bug) -- holding for a precomputed
        # frame count can no longer be used to return to the exact starting
        # index the way the old always-step-1 ramp allowed. So: hold for a
        # generous spin (visits ~2 revolutions' worth of directions, the
        # actual round-trip stress this section exists for), then force
        # gaim_index directly back to its start value -- gaim_draw_line is a
        # pure function of (index, cue position), so the next redraw is
        # pixel-identical to "before" regardless of how gaim_index got set,
        # same principle section 2's direct index pokes already rely on.
        hold_frames = simulate(2 * DIRECTIONS)
        wait_lua(
            f"keyboard_write({PRESS_RIGHT})\n"
            f"wait_frames({hold_frames - 1})\n"
            f"keyboard_write({RELEASE})\n"
            f"wait_frames(2)\n", timeout=120)
        wait_lua(f"cpc.setRam({sym['gaim_index']}, string.char({AIM_DEFAULT_INDEX}))\n"
                f"wait_frames(1)\n")
        final_idx = int(wait_lua(f"print(cpc.getRam({sym['gaim_index']}, 1):byte(1))").split()[-2])
        if final_idx != AIM_DEFAULT_INDEX:
            failures.append(f"forcing gaim_index back to {AIM_DEFAULT_INDEX} didn't stick, "
                            f"read back {final_idx}")
        w2, h2, after = screenshot()
        if (w, h) != (w2, h2):
            failures.append(f"screenshot size changed: {w}x{h} -> {w2}x{h2}")
        elif before != after:
            diffs = [(x, y) for y in range(h) for x in range(w) if before[y][x] != after[y][x]]
            failures.append(f"round-trip left {len(diffs)} pixel(s) different, e.g. {diffs[:5]} "
                            f"(before={[before[y][x] for x, y in diffs[:5]]} "
                            f"after={[after[y][x] for x, y in diffs[:5]]})")

        # --- 2. geometry: dashes for a known direction are really drawn -----
        index = 8   # 8/256 turn = 11.25 deg, shallow and slightly down from the cue
        wait_lua(f"cpc.setRam({sym['gaim_index']}, string.char({index}))\n"
                 f"wait_frames(1)\n")  # forces a redraw next update (index changed)
        cue = ram(sym["entity_array"], 5)
        cue_x, cue_y = cue[2], cue[4]
        felt_pen = config("FELT_PEN")
        ga = get("/api/ga")
        palette = [((v >> 16) & 255, (v >> 8) & 255, v & 255) for v in ga["ink_rgb"]]
        w, h, rows = screenshot()
        x0, y0, x1, y1 = felt_box(rows, palette[felt_pen])
        sx = (x1 - x0) / config("TABLE_WIDTH_PX")
        sy = (y1 - y0) / config("TABLE_HEIGHT_PX")
        points = dash_points(index, cue_x, cue_y,
                             config("AIM_STEP_MULT"), config("AIM_DASH_COUNT"),
                             config("AIM_DASH_PX"), config("BALL_WIDTH_PX"), config("BALL_HEIGHT_PX"),
                             config("TABLE_WIDTH_PX"), config("TABLE_Y_PX"), config("TABLE_HEIGHT_PX"))
        if not points:
            failures.append("aim_model says direction 8 produces zero dashes from the boot cue position")
        else:
            wrong = 0
            for dash_x, dash_y in points:
                left = dash_x & ~1        # mode 0: the blit starts on the byte holding x
                for dx in range(config("AIM_DASH_PX")):
                    for dy in range(config("AIM_DASH_PX")):
                        px = int(x0 + (left + dx + 0.5) * sx)
                        py = int(y0 + (dash_y - config("TABLE_Y_PX") + dy + 0.5) * sy)
                        if nearest_pen(rows[py][px], palette) == felt_pen:
                            wrong += 1
            if wrong:
                failures.append(f"direction 8: {wrong} dash pixels still show the felt colour "
                                f"(expected {len(points)} dashes x {config('AIM_DASH_PX')**2} px)")

        # --- 2b. the line can cross a ball's box and erase clean afterward --
        # By default the line's reach (AIM_DASH_COUNT*AIM_STEP_MULT) doesn't
        # reach the rack from the boot cue position, so this places a ball
        # squarely on one of direction 8's own dash positions to force a
        # real crossing, then checks the draw+erase round-trip is still
        # pixel-perfect INCLUDING the ball's own pixels -- the capability
        # this whole redesign (gdl_overlaps_any_ball removed, sys/entity.s
        # skips settled balls) exists for: the line no longer has to stop
        # before reaching a ball, since nothing else will touch that ball's
        # pixels while it's settled and the line is up.
        ball_x, ball_y = 141, 137   # covers dash 3 of direction 8, (144,140)-ish (tools/aim_model.py);
                                    # re-picked for V.017's 256-direction table (index 8 is a
                                    # different, much shallower angle than under the old 64-table)
        wait_lua(f"cpc.setRam({sym['gaim_index']}, string.char(0))\nwait_frames(1)\n"
                f"cpc.setRam({sym['entity_array']} + 3 * {ENTITY_SIZE} + 1, "
                f"string.char(0, {ball_x}, 0, {ball_y}, 0, 0, 0, 0))\n"
                f"cpc.setRam({sym['entity_array']} + 3 * {ENTITY_SIZE} + 13, string.char(2, 0))\n"
                f"wait_frames(2)\n")
        w3, h3, reference = screenshot()   # ball alone, line pointed elsewhere (index 0)
        wait_lua(f"cpc.setRam({sym['gaim_index']}, string.char(8))\nwait_frames(1)\n")
        w3b, h3b, crossing = screenshot()
        crossed = crossing != reference
        wait_lua(f"cpc.setRam({sym['gaim_index']}, string.char(0))\nwait_frames(1)\n")
        w3c, h3c, restored = screenshot()
        if not crossed:
            failures.append("ball-crossing: direction 8's line over the moved ball produced no "
                            "visible change at all -- the dash may not actually be landing on it")
        if (w3, h3) != (w3c, h3c):
            failures.append(f"ball-crossing: screenshot size changed: {w3}x{h3} -> {w3c}x{h3c}")
        elif restored != reference:
            diffs = [(x, y) for y in range(h3) for x in range(w3) if reference[y][x] != restored[y][x]]
            failures.append(f"ball-crossing: {len(diffs)} pixel(s) did not restore after the "
                            f"line crossed the ball and moved away, e.g. {diffs[:5]}")

        # --- 2c/2d. the line bounces off a cushion like a real launched ball
        # ReflectAxis (aim.s) folds a position with either a POSITIVE overrun
        # (m > span: mirror across the far wall) or a NEGATIVE one (m < 0:
        # add one period first) -- two different branches in the Z80, so one
        # bounce direction only proves one of them. Direction 13 bounces off
        # the BOTTOM cushion (positive-overrun branch); direction 48 bounces
        # off the TOP cushion (negative-wrap branch: an adversarial review of
        # this diff traced the negative branch correct by hand but flagged
        # that nothing actually exercised it on real hardware -- this closes
        # that gap). Checks the SAME way section 2 does: every dash pixel,
        # including the ones past the bounce, must show the aim colour in a
        # real screenshot, so a wrong fold shows up as a dash landing on
        # plain felt past the cushion.
        def check_bounce(index, rising):
            # Near a bounce apex, consecutive dashes can land close enough
            # that their boxes overlap by a row/column of game pixels --
            # expected for an almost-vertical/horizontal direction whose
            # per-dash Y (or X) progress naturally shrinks approaching the
            # reflection point, same as a real trajectory slowing into a
            # cushion. XOR onto an overlapped game pixel TWICE cancels back
            # to felt colour there, which is correct XOR arithmetic, not
            # damage -- reversibility (the actual invariant) never depended
            # on every dash pixel individually showing the aim colour, only
            # on draw and its matching erase applying the identical pattern
            # (they do: both come from the same gaim_draw_line(index, cue)).
            # So the real check is XOR PARITY per covered game pixel (odd
            # count -> aim colour, even -> back to whatever was under it),
            # not "every dash pixel must show aim colour" -- section 2's
            # single straight-line check gets away with the simpler version
            # only because its dashes never overlap each other.
            wait_lua(f"cpc.setRam({sym['gaim_index']}, string.char({index}))\nwait_frames(1)\n")
            w4, h4, rows4 = screenshot()
            x0b, y0b, x1b, y1b = felt_box(rows4, palette[felt_pen])
            sxb = (x1b - x0b) / config("TABLE_WIDTH_PX")
            syb = (y1b - y0b) / config("TABLE_HEIGHT_PX")
            points = dash_points(index, cue_x, cue_y,
                                 config("AIM_STEP_MULT"), config("AIM_DASH_COUNT"),
                                 config("AIM_DASH_PX"), config("BALL_WIDTH_PX"), config("BALL_HEIGHT_PX"),
                                 config("TABLE_WIDTH_PX"), config("TABLE_Y_PX"), config("TABLE_HEIGHT_PX"))
            ys = [y for _, y in points]
            extreme = max(ys) if rising else min(ys)
            if not (len(ys) == config("AIM_DASH_COUNT") and extreme in ys[:-1]
                   and (ys[-1] < extreme if rising else ys[-1] > extreme)):
                failures.append(f"direction {index}: aim_model.py's own points {points} don't "
                                f"show a bounce -- test picked a direction/cue position that no "
                                f"longer bounces, fix the test")
                return
            coverage = {}
            for dash_x, dash_y in points:
                left = dash_x & ~1
                for dx in range(config("AIM_DASH_PX")):
                    for dy in range(config("AIM_DASH_PX")):
                        key = (left + dx, dash_y + dy)
                        coverage[key] = coverage.get(key, 0) + 1
            wrong = 0
            for (gx, gy), count in coverage.items():
                px = int(x0b + (gx + 0.5) * sxb)
                py = int(y0b + (gy - config("TABLE_Y_PX") + 0.5) * syb)
                is_felt = nearest_pen(rows4[py][px], palette) == felt_pen
                expect_felt = (count % 2 == 0)
                if is_felt != expect_felt:
                    wrong += 1
            if wrong:
                failures.append(f"direction {index}: {wrong} game pixel(s) don't match the "
                                f"expected XOR parity (felt vs aim colour) across all "
                                f"{config('AIM_DASH_COUNT')} dashes, including past the bounce")

        # Indices re-picked for V.017's 256-direction table (were 13/48 under
        # the old 64-direction one -- same index number is a different angle
        # now, so the old pair no longer bounces at all against the boot cue
        # position; re-searched via tools/aim_model.py for a clean single
        # rise-then-fall / fall-then-rise over AIM_DASH_COUNT dashes).
        check_bounce(51, rising=True)     # bottom cushion: ReflectAxis's positive-overrun fold
        check_bounce(177, rising=False)   # top cushion: ReflectAxis's negative-wrap fold
        wait_lua(f"cpc.setRam({sym['gaim_index']}, string.char(0))\nwait_frames(1)\n")

        # --- 3 & 4. hides while moving, reappears at the new position -------
        # Direction 0 (pure +x, toward the far-off left... rather, +x is
        # right) and a longer charge: found by experiment that a straight
        # shot toward a NEARBY cushion can bounce once and land back on its
        # exact starting pixel (real physics -- the cue started almost
        # equidistant from the top and bottom cushions, and a minimum-power
        # shot into the close one returned exactly to 131 in an earlier run
        # of this very test). A firm shot along the table's long axis makes
        # that coincidence's odds negligible without weakening what's
        # actually being checked (gaim_last_cx/cy tracking wherever the cue
        # really ends up).
        wait_lua(f"cpc.setRam({sym['gaim_index']}, string.char(0))\nwait_frames(1)\n")
        before_shot = ram(sym["entity_array"], 5)
        pre_cx, pre_cy = before_shot[2], before_shot[4]
        wait_lua(f"keyboard_write({PRESS_SPACE})\nwait_frames(30)\nkeyboard_write({RELEASE})\n")
        shown_mid_flight = None
        for _ in range(30):
            wait_lua("wait_frames(0)")
            shown = ram(sym["gaim_shown"], 1)[0]
            pool = ram(sym["entity_array"], BALL_COUNT * ENTITY_SIZE)
            moving = any(pool[s * ENTITY_SIZE + 5:s * ENTITY_SIZE + 9] != b"\x00\x00\x00\x00"
                        for s in range(BALL_COUNT))
            if moving:
                shown_mid_flight = shown
                break
        if shown_mid_flight is None:
            failures.append("shot never got the cue moving within 30 frames")
        elif shown_mid_flight != 0:
            failures.append(f"gaim_shown={shown_mid_flight} while a ball is moving, expected 0")

        for _ in range(400):
            pool = ram(sym["entity_array"], BALL_COUNT * ENTITY_SIZE)
            if all(pool[s * ENTITY_SIZE + 5:s * ENTITY_SIZE + 9] == b"\x00\x00\x00\x00"
                   for s in range(BALL_COUNT)):
                break
            wait_lua("wait_frames(4)")
        else:
            failures.append("balls never settled after the shot")
        wait_lua("wait_frames(9)")
        cue = ram(sym["entity_array"], 5)
        new_cx, new_cy = cue[2], cue[4]
        if (new_cx, new_cy) == (pre_cx, pre_cy):
            failures.append("cue ball did not move: the reappear-at-new-position check needs it to")
        last_cx, last_cy = ram(sym["gaim_last_cx"], 1)[0], ram(sym["gaim_last_cy"], 1)[0]
        if (last_cx, last_cy) != (new_cx, new_cy):
            failures.append(f"gaim_last_cx/cy=({last_cx},{last_cy}) after the shot settled, "
                            f"expected the cue's new position ({new_cx},{new_cy})")

        # --- 5. the gate survives a velocity-independent settle -------------
        # sys_collision_balls_bounce separates overlapping RESTING balls by
        # nudging position directly (NudgeInc/NudgeDec, sys/collision.s) --
        # this never touches velocity, so a chain of balls can keep sliding
        # 1px/frame apart with v=0 the whole time. gaim_all_still used to
        # check only velocity (IsStill); a ball moved this way while the cue
        # and gaim_index stay untouched would pass "unchanged" and never get
        # re-erased/redrawn -- a permanent stray XOR mark wherever a nudge
        # crossed a shown dash. Reproduced with three balls placed already
        # OVERLAPPING (x=50,45,40 -- each pair overlaps by 1px, spacing =
        # BALL_WIDTH_PX-1), all v=0 and
        # staying v=0 for every single frame of the whole settle (confirmed
        # by hand: this needs genuine overlap-at-placement, not a moving
        # striker, or the striking ball's own nonzero velocity gets caught
        # by the old velocity-only check and masks the defect). Slots 1-3,
        # far from the cue (slot 0, left at its own resting spot) and from
        # its dash path, so this isolates the GATE rather than the separate,
        # already-guarded dash/ball overlap check.
        # Placement AND the frame-by-frame trace must be ONE Lua script: the
        # emulator keeps running in real time regardless of whether a script
        # is active (confirmed by hand), so two separate wait_lua calls here
        # let the whole settle finish in the real-time gap between them --
        # the trace would start already-settled and never see the window.
        trace = wait_lua(
            f"local ARR2, SZ2 = {sym['entity_array']}, {ENTITY_SIZE}\n"
            f"local function word(v) if v < 0 then v = v + 65536 end return v % 256, v // 256 end\n"
            f"local function place(slot, x, y, vx, vy)\n"
            f"  local vxl, vxh = word(vx)\n"
            f"  local vyl, vyh = word(vy)\n"
            f"  cpc.setRam(ARR2 + slot * SZ2 + 1, string.char(0, x, 0, y, vxl, vxh, vyl, vyh))\n"
            f"  cpc.setRam(ARR2 + slot * SZ2 + 13, string.char(2, 0))\n"
            f"end\n"
            f"place(1, 50, 190, 0, 0)\nplace(2, 45, 190, 0, 0)\nplace(3, 40, 190, 0, 0)\n"
            f"wait_frames(0)\n"    # let the game's own loop see the new placement before sampling
            f"local function state()\n"
            f"  local moving, dirty = false, false\n"
            f"  for s = 1, 3 do\n"
            f"    local e = cpc.getRam(ARR2 + s * SZ2, 14)\n"
            f"    if e:byte(6) ~= 0 or e:byte(7) ~= 0 or e:byte(8) ~= 0 or e:byte(9) ~= 0 then moving = true end\n"
            f"    if e:byte(14) ~= 0 then dirty = true end\n"
            f"  end\n"
            f"  return moving, dirty\n"
            f"end\n"
            f"local out, settled_extra = {{}}, nil\n"
            f"for f = 1, 120 do\n"
            f"  local moving, dirty = state()\n"
            f"  local shown = cpc.getRam({sym['gaim_shown']}, 1):byte(1)\n"
            f"  out[#out + 1] = string.format('%d,%d,%d,%d', f, moving and 1 or 0, dirty and 1 or 0, shown)\n"
            f"  if not moving and not dirty and settled_extra == nil then settled_extra = 0 end\n"
            f"  if settled_extra ~= nil then\n"
            f"    settled_extra = settled_extra + 1\n"
            f"    if settled_extra > 2 then break end\n"   # give aim_update a couple more frames to react
            f"  end\n"
            f"  wait_frames(0)\n"
            f"end\n"
            f"print(table.concat(out, ' '))\n", timeout=60)
        samples = [tuple(int(v) for v in token.split(","))
                  for token in trace.split() if token.count(",") == 3]
        v_still_frame = cflags_still_frame = None
        shown_at_v_still = None
        for f, moving, dirty, shown in samples:
            if not moving and v_still_frame is None:
                v_still_frame, shown_at_v_still = f, shown
            if not moving and not dirty and cflags_still_frame is None:
                cflags_still_frame = f
        # The trace runs a couple of extra frames past full settle so
        # aim_update (which reacts to LAST frame's state) gets a chance to
        # notice and redraw; the final sample is that later point.
        shown_at_full_settle = samples[-1][3] if samples else None
        if v_still_frame is None:
            failures.append("cradle: velocities never settled")
        elif cflags_still_frame is None:
            failures.append("cradle: e_cflags never settled (still nudging after 120 frames)")
        else:
            if cflags_still_frame == v_still_frame:
                failures.append("cradle: v=0 and cflags=0 landed on the same frame -- this "
                                "scenario needs to produce at least one frame of v=0-but-still-"
                                "nudging to actually exercise the fix; adjust the positions")
            elif shown_at_v_still != 0:
                failures.append(f"cradle: gaim_shown={shown_at_v_still} at frame {v_still_frame} "
                                f"(velocities zero, but balls still being nudged apart) -- the "
                                f"cue and gaim_index never changed, so the old velocity-only gate "
                                f"would wrongly call this 'unchanged' and never re-erase/redraw")
            if shown_at_full_settle != 1:
                failures.append(f"cradle: gaim_shown={shown_at_full_settle} at frame "
                                f"{cflags_still_frame} once truly settled, expected 1 (redrawn)")
    finally:
        if not args.keep_emulator:
            shutdown(emulator)

    for failure in failures:
        print("FAIL " + failure)
    print("aim_test: " + ("FAIL" if failures else "PASS"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
