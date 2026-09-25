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
- Bump `_game_version_string` in `src/main.s` (currently ` POCKETFEVER V.010`).
- Run `./code-server-compile.sh` — `make recode` and copy `PocketFever.dsk` to `../../www/gamez`. Always deploy before commit+push so the playable DSK is what gets tested.
- `git commit` and `git push`. Do not wait to be asked.

## Main loop timing

Single buffer. Erase + draw must run right after `cpct_waitVSYNC_asm`, before the beam reaches the felt; physics + collision go after (~14 ms in V.008, much less since V.009). Putting work between erase and draw hides the balls (V.005-V.007 bug).

`game_loop_count` (main.s) counts loop iterations; `perf_test.py` compares it with emulated frames. For a per-phase breakdown set `PROFILE_RASTER = 1` in config.h.s (`make clean && make`): the border turns black while idle, red for erase+draw, yellow for physics and white for collision, so a screenshot shows each phase in raster lines. V.009, visible lines at rest / all 10 moving: erase+draw ≥81 / ≥80, physics 12 / 42, collision 6 / 64, idle 172 / 85 (V.008: collision 133 / 136, idle 26 / 18).

## Test shot (temporary, until aiming exists)

`game/shot.s`: each SPACE press (edge, not hold) fires the cue ball (slot 0) in one of 32 directions from `src/game/shot_table.s` with power `SHOT_POWER_MIN..+SHOT_POWER_SPAN` (config.h.s), 2..4 raster lines per frame. Keep the top speed under `BALL_HEIGHT_PX` lines per frame or balls can pass through each other. The table is generated: edit `tools/gen_shot_table.py` and rerun `python3 tools/gen_shot_table.py > src/game/shot_table.s`; it corrects x for the wide mode 0 pixel (1.65 line heights) so every direction covers the same screen distance. The RNG is seeded on the first press. Cushions: physics clamps and reverses velocity at all four edges; there are no pockets yet.

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
python3 tests/shot_test.py                # ~60 s, SPACE fires the cue ball, balls settle cleanly
```

Runs the built game in `../tools/amspirit-lite` (headless), writes ball state into the entity pool through a Lua script and samples every ball each frame. Covers collision separation against all four cushions, the separation axis for every relative position, plus seeded random rounds (`--seed N`). `render_test` checks the emulator's screenshot (what the beam drew), not video RAM: every ball's 4×6 pixels must show its pen colour. Shared driver in `tests/amspirit.py`. Run the tests one at a time; each needs port 6128 free. Edits to a `.h.s` need `make clean && make` first (the Makefile does not track header dependencies).

## Commands

`cpct_winape -as -f` after build.
