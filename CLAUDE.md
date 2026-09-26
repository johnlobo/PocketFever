# PocketFever

Amstrad CPC Mode 0, Z80 assembly, CPCtelera. Side Pocket-style 9-ball.

## Build

```bash
make            # → PocketFever.dsk / .sna / .cdt
make clean
make cleanall
```

`CPCT_PATH` required. Load at `0x4000`.

**Version bump + deploy + commit (do this unprompted after every significant change):**
- Bump `_game_version_string` in `src/main.s` (currently ` POCKETFEVER V.013`).
- Run `./code-server-compile.sh` — `make recode` and copy `PocketFever.dsk` to `../../www/gamez`. Always deploy before commit+push so the playable DSK is what gets tested.
- `git commit` and `git push`. Do not wait to be asked.

## Main loop timing

Single buffer. Erase + draw must run right after `cpct_waitVSYNC_asm`, before the beam reaches the felt; physics + collision go after (~14 ms in V.008, much less since V.009). Putting work between erase and draw hides the balls (V.005-V.007 bug).

`game_loop_count` (main.s) counts loop iterations; `perf_test.py` compares it with emulated frames. For a per-phase breakdown set `PROFILE_RASTER = 1` in config.h.s (`make clean && make`): the border turns black while idle, red for erase+draw, yellow for physics and white for collision, so a screenshot shows each phase in raster lines. V.012, visible lines at rest / all 10 moving: erase+draw ≥81 / ≥80, physics 13 / 106, collision 5 / 64, idle 172 / 21 (V.011 physics 42 all moving; the per-ball division in friction costs ~6 lines per moving ball; caching the direction ratio would win it back). V.008: collision 133 / 136, idle 26 / 18.

## Friction

`sys_physics_friction` slows a ball by `PHYS_FRICTION` (4/256 px per frame per frame since V.012) along its direction of travel: the dominant axis loses F, the other F·minor/major (8-bit fraction, remainder carried in `e_facc`). Paths stay straight while slowing. Friction per axis (V.011 and earlier) stopped the smaller component first and bent diagonal rolls by up to 20°, worst on x because x numbers are ~0.6× smaller for the same screen speed. `tools/friction_model.py` models this code exactly, compares models (end drift, bend, distance, stop time) and is the spec `tests/physics_test.py` checks against. Change friction there first, then in physics.s.

## Aiming and shot

`game/aim.s`: cursor left/right rotate `gaim_index::` (public, one of 32 steps in `src/game/shot_table.s`, throttled to one step per `AIM_TURN_THROTTLE` held frames), shown as a dashed XOR line from the cue ball while every ball is at rest. `game/shot.s`: hold SPACE to charge, release to fire the cue ball (slot 0) in `gaim_index`'s direction -- no RNG anywhere any more. Power starts at `SHOT_POWER_MIN` on the first held frame and gains 1 every `SHOT_CHARGE_STEP` frames up to `MIN+SPAN` (config.h.s): 2..4 raster lines per frame, full on the 49th held frame (~1 s). A HUD bar (`SHOT_BAR_*`) grows one segment per level and clears on release. Keep the top speed under `BALL_HEIGHT_PX` lines per frame or balls can pass through each other. The direction table is generated: edit `tools/gen_shot_table.py` and rerun `python3 tools/gen_shot_table.py > src/game/shot_table.s`; it corrects x for the wide mode 0 pixel (1.65 line heights) so every direction covers the same screen distance -- cos(a) = sin(a + 90 deg), one trig call, computed at BUILD time in Python, never on the Z80. Cushions: physics clamps and reverses velocity at all four edges; there are no pockets yet.

**XOR line invariant**: `gaim_draw_line` only ever XORs pixels that no ball's ordinary per-frame erase/redraw (a direct felt overwrite, not XOR -- `sys/entity.s`) will touch before the SAME dashes are XORed again to erase them. That needs two things, both enforced in `gaim_draw_line`/`tools/aim_model.py`: the line is shown only while every ball is at rest (`gaim_all_still`, checked before drawing and before erasing), and each dash stops the line rather than overlapping any ball's box (`gdl_overlaps_any_ball`; `AIM_STEP_MULT` is sized so the first dash always clears the cue's own box). Break either one and a stray XOR mark is left on the felt permanently.

`gaim_all_still` checks each ball's velocity AND its `e_cflags` (nonzero = touched by physics or a collision separation nudge as of the last pass, `sys/collision.s`'s CF_PENDING/CF_ACTIVE). Velocity alone is not enough: `sys_collision_balls_bounce` separates two overlapping RESTING balls by nudging position directly, never touching velocity, so a chain of balls can keep sliding 1px/frame apart with v=0 the whole time -- found in review, reproduced in `tests/aim_test.py` with three balls placed already overlapping (not struck by a moving one, which would mask the bug: the striker's own nonzero velocity gets caught by a velocity-only check).

**`sys_render_draw_box_xor` gotcha**: for a 1-byte-wide (2px) box, do not pass its real height as the routine's `B` input. The routine always draws a full top row and a full bottom row, plus (`B`-1) "border" rows in between that XOR the left- and right-edge BYTES separately -- at 1-byte width those are the SAME byte, so each middle row draws then immediately un-draws itself (confirmed on screen: visible row, blank row, visible row for `B`=2). Pass `B` = wanted-height-in-rows - 1 to land on the "exactly a full top + full bottom row, no middle" case. `gaim_draw_line`'s dash call does this; any future 1-byte-wide XOR box needs the same adjustment.

**Test-script gotcha** (found writing `tests/aim_test.py`, the first test here to POST several separate `/api/script` calls per run instead of one big script): right after posting script N+1, a GET can still report `running: false` with script N's leftover output -- confirmed by direct experiment, not just POST-before-start latency. A completion marker must be unique PER CALL (a counter suffix), not just present, or a poll can match the PREVIOUS call's marker before the new script has even started. `tests/aim_test.py`'s `wait_lua` does this; the other tests dodge the whole problem by never making more than one `/api/script` call per run. Separately, in AmSpiriT Lua, `wait_frames(n)` advances n+1 frames (see `tests/amspirit.py`); samples taken in a `wait_frames(1)` loop are every other frame.

## Collision rules

- Every change of a ball's position sets `CF_PENDING` in `e_cflags`: physics for moving balls, each separation nudge that moves a ball, the rack at boot, and anything else that places a ball (tests poke it too). Forget it and that ball's overlaps are never seen.
- Each collision pass first snapshots PENDING into `CF_ACTIVE`, then checks a pair (lower slot = collider, later slots only) only if one ball is ACTIVE. No ACTIVE ball: the pass ends after the snapshot.
- Hits swap velocities and nudge both balls 1 px apart, clamped at the cushions, as in V.008. A nudged ball is PENDING, so leftover overlap keeps being resolved one pixel per frame. Not bit-identical to V.008: an overlap a nudge creates mid-pass between two non-ACTIVE balls is handled next frame, so a break can end a pixel differently (never overlapping).
- Tried and rejected (V.009 review): skipping still balls as colliders and full one-shot separation. Both left overlaps at rest (mid-pass hits, pushes into a third ball) or ping-ponged in a squeeze. The scenarios live in `tests/collision_test.py`.

## Frozen layout

- Felt 160×132 (looks 2:1 on CRT 4:3), bottom-aligned (Y=68). HUD 68 px at Y=0.
- Balls 4×6. `src/config.h.s`.
- Legal ball top-left: x `0..TABLE_X_MAX`, y `TABLE_Y_PX..TABLE_Y_MAX` (config.h.s). Anything that moves a ball (physics, collision separation) must stay inside it.

## Architecture

Follows DeckTower/model01: `src/sys/` reusable, `src/game/` game-specific. `sys` must not reference `game`.

Copied from DeckTower (trimmed): `system`, `input`, `text`, `messages`, `array`. Also `render` and `util` because text/messages need them. `sys/entity` is PocketFever's ball pool (10 slots). `game/table` paints the felt and seeds the 9-ball rack.

## Tests

```bash
make && python3 tests/collision_test.py   # ~40 s, boots the real DSK in AmSpiriT-Lite
python3 tests/render_test.py              # ~25 s, balls visible in real screenshots
python3 tests/perf_test.py                # ~30 s, main loop at 50 Hz (rest, break, all moving)
python3 tests/shot_test.py                # ~90 s, hold SPACE 3/27/60 frames: power 8/12/16, balls settle cleanly
python3 tests/physics_test.py             # ~60 s, friction along the direction, bit-exact with tools/friction_model.py
python3 tests/aim_test.py                 # ~40 s, XOR aim line round-trips a full revolution pixel-exact
```

Runs the built game in `../tools/amspirit-lite` (headless), writes ball state into the entity pool through a Lua script and samples every ball each frame. Covers collision separation against all four cushions, the separation axis for every relative position, plus seeded random rounds (`--seed N`). `render_test` checks the emulator's screenshot (what the beam drew), not video RAM: every ball's 4×6 pixels must show its pen colour. Shared driver in `tests/amspirit.py`. Run the tests one at a time; each needs port 6128 free. Edits to a `.h.s` need `make clean && make` first (the Makefile does not track header dependencies).

## Commands

`cpct_winape -as -f` after build.
