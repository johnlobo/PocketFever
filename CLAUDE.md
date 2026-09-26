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
- Bump `_game_version_string` in `src/main.s` (currently ` POCKETFEVER V.015`).
- Run `./code-server-compile.sh` — `make recode` and copy `PocketFever.dsk` to `../../www/gamez`. Always deploy before commit+push so the playable DSK is what gets tested.
- `git commit` and `git push`. Do not wait to be asked.

## Main loop timing

Single buffer. Erase + draw must run right after `cpct_waitVSYNC_asm`, before the beam reaches the felt; physics + collision go after (~14 ms in V.008, much less since V.009). Putting work between erase and draw hides the balls (V.005-V.007 bug).

`game_loop_count` (main.s) counts loop iterations; `perf_test.py` compares it with emulated frames. For a per-phase breakdown set `PROFILE_RASTER = 1` in config.h.s (`make clean && make`): the border turns black while idle, red for erase+draw, yellow for physics and white for collision, so a screenshot shows each phase in raster lines.

`sys_entity_erase_one`/`sys_entity_draw_one` (sys/entity.s) skip a ball entirely once it's settled (`SkipIfSettled`, sys/entity.h.s: no velocity AND `e_cflags` clear -- same test `gaim_all_still` uses). A settled ball's `e_old_x`/`e_old_y` already equal its current position, so erase(old)+draw(current) would be a no-op anyway; skipping it is pure win. V.015, visible lines at rest / all 10 moving: erase+draw 7 / 88, physics 13 / 108, collision 10 / 69, idle 241 / 6 (V.012: erase+draw ≥81 / ≥80, idle 172 / 21 -- moving-ball redraw cost is unchanged, since nothing to skip there). V.008: collision 133 / 136, idle 26 / 18.

## Friction

`sys_physics_friction` slows a ball by `PHYS_FRICTION` (4/256 px per frame per frame since V.012) along its direction of travel: the dominant axis loses F, the other F·minor/major (8-bit fraction, remainder carried in `e_facc`). Paths stay straight while slowing. Friction per axis (V.011 and earlier) stopped the smaller component first and bent diagonal rolls by up to 20°, worst on x because x numbers are ~0.6× smaller for the same screen speed. `tools/friction_model.py` models this code exactly, compares models (end drift, bend, distance, stop time) and is the spec `tests/physics_test.py` checks against. Change friction there first, then in physics.s.

## Aiming and shot

`game/aim.s`: cursor left/right rotate `gaim_index::` (public, one of `DIRECTIONS`=64 steps in `src/game/shot_table.s`, from `tools/gen_shot_table.py`), shown as a dashed XOR line from the cue ball while every ball is at rest. Turning is a staged ramp, not a flat throttle: `AIM_TURN_T0` (slowest, ~120 ms/step, precise single-step aiming) down to `AIM_TURN_T3` (fastest, ~20 ms/step, full spin) as the held frame count crosses `AIM_TURN_H1`/`H2`/`H3` (config.h.s), so a 64-step revolution takes ~2 s held continuously instead of the ~7.7 s a flat slow throttle would need, without losing single-step precision on a tap. Switching direction without releasing restarts the ramp (`gaim_turn_dir`), a deliberate reversal is not a continuation of the spin being built up. Sized and verified with `tools/turn_model.py`; change the ramp there first, `tests/turn_test.py` checks the Z80 against it exactly (via `game_loop_count`, not `wait_frames` -- see the gotcha below). `game/shot.s`: hold SPACE to charge, release to fire the cue ball (slot 0) in `gaim_index`'s direction -- no RNG anywhere any more. Power starts at `SHOT_POWER_MIN` on the first held frame and gains 1 every `SHOT_CHARGE_STEP` frames up to `MIN+SPAN` (config.h.s): 2..4 raster lines per frame, full on the 49th held frame (~1 s). A HUD bar (`SHOT_BAR_*`) grows one segment per level and clears on release. Keep the top speed under `BALL_HEIGHT_PX` lines per frame or balls can pass through each other. The direction table is generated: edit `tools/gen_shot_table.py` and rerun `python3 tools/gen_shot_table.py > src/game/shot_table.s`; it corrects x for the wide mode 0 pixel (1.65 line heights) so every direction covers the same screen distance -- cos(a) = sin(a + 90 deg), one trig call, computed at BUILD time in Python, never on the Z80. Cushions: physics clamps and reverses velocity at all four edges; there are no pockets yet.

**XOR line invariant**: `gaim_draw_line` only ever XORs pixels that no ball's ordinary per-frame erase/redraw (a direct felt overwrite, not XOR -- `sys/entity.s`) will touch before the SAME dashes are XORed again to erase them. Since V.015 that's true unconditionally: `sys_entity_erase_one`/`draw_one` skip any SETTLED ball (see "Main loop timing"), and the line is only ever shown while EVERY ball is settled (`gaim_all_still`) -- so nothing ever redraws a ball while the line is up, and a dash can cross a ball's box freely (`gdl_overlaps_any_ball` is gone; the line only stops at the felt edge, `gdl_in_bounds`). A dash over a ball shows the XOR of whatever pattern sits there, not necessarily the aim colour -- accepted, cosmetic only, reversibility never depended on it. Break the settle-skip or the all-still gate and a stray XOR mark is left on the felt permanently; `tests/aim_test.py`'s round-trip (a full revolution) and its dedicated ball-crossing check both fail on that regression.

`gaim_all_still` checks each ball's velocity AND its `e_cflags` (nonzero = touched by physics or a collision separation nudge as of the last pass, `sys/collision.s`'s CF_PENDING/CF_ACTIVE). Velocity alone is not enough: `sys_collision_balls_bounce` separates two overlapping RESTING balls by nudging position directly, never touching velocity, so a chain of balls can keep sliding 1px/frame apart with v=0 the whole time -- found in review, reproduced in `tests/aim_test.py` with three balls placed already overlapping (not struck by a moving one, which would mask the bug: the striker's own nonzero velocity gets caught by a velocity-only check).

**`sys_render_draw_box_xor` gotcha**: for a 1-byte-wide (2px) box, do not pass its real height as the routine's `B` input. The routine always draws a full top row and a full bottom row, plus (`B`-1) "border" rows in between that XOR the left- and right-edge BYTES separately -- at 1-byte width those are the SAME byte, so each middle row draws then immediately un-draws itself (confirmed on screen: visible row, blank row, visible row for `B`=2). Pass `B` = wanted-height-in-rows - 1 to land on the "exactly a full top + full bottom row, no middle" case. `gaim_draw_line`'s dash call does this; any future 1-byte-wide XOR box needs the same adjustment.

**Test-script gotcha** (found writing `tests/aim_test.py`, the first test here to POST several separate `/api/script` calls per run instead of one big script): right after posting script N+1, a GET can still report `running: false` with script N's leftover output -- confirmed by direct experiment, not just POST-before-start latency. A completion marker must be unique PER CALL (a counter suffix), not just present, or a poll can match the PREVIOUS call's marker before the new script has even started. `tests/aim_test.py`'s `wait_lua` does this; the other tests dodge the whole problem by never making more than one `/api/script` call per run. Separately, in AmSpiriT Lua, `wait_frames(n)` advances n+1 frames (see `tests/amspirit.py`); samples taken in a `wait_frames(1)` loop are every other frame.

**`wait_frames(0)` gotcha** (found writing `tests/turn_test.py`): unlike `wait_frames(n)` for n>=1, `wait_frames(0)` does not reliably advance exactly one real game-loop iteration every call -- confirmed against `game_loop_count` (the only trustworthy clock here), which sometimes does not increment at all across a `wait_frames(0)` call, and other times advances by more than one to compensate. A tight polling loop that counts its OWN `wait_frames(0)` iterations as "frames elapsed" can drift by several frames over a few dozen calls; the fix is to key every sample on `game_loop_count`'s own delta, never on how many times the polling loop ran. `tests/turn_test.py`'s `sample_hold` does this -- but a second manifestation still got through: a poll can also SKIP a sample (advance 2 real loops in one call), so "wait for the exact transition I expect" can walk straight past it (this broke the round-trip check in `tests/aim_test.py`, which polled for gaim_index returning to its exact starting value and could skip over it once the turn ramp's fast stage steps by 2 per poll). Two different fixes for the two different shapes of this problem: `tests/aim_test.py`'s round-trip now holds for the EXACT frame count `tools/turn_model.simulate()` predicts for a full revolution, checking the outcome once, never polling for a mid-flight transition; `tests/turn_test.py`'s `verify_ramp` checks every SAMPLE it happens to get against what the model predicts for that sample's own loop count (calibrating out input-registration latency from the first observed step), rather than checking whether a specific expected transition was ever directly observed.

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
python3 tests/turn_test.py                # ~30 s, cursor-key turn ramp matches tools/turn_model.py exactly
```

Runs the built game in `../tools/amspirit-lite` (headless), writes ball state into the entity pool through a Lua script and samples every ball each frame. Covers collision separation against all four cushions, the separation axis for every relative position, plus seeded random rounds (`--seed N`). `render_test` checks the emulator's screenshot (what the beam drew), not video RAM: every ball's 4×6 pixels must show its pen colour. Shared driver in `tests/amspirit.py`. Run the tests one at a time; each needs port 6128 free. Edits to a `.h.s` need `make clean && make` first (the Makefile does not track header dependencies).

## Commands

`cpct_winape -as -f` after build.
