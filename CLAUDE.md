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
- Bump `_game_version_string` in `src/main.s` (currently ` POCKETFEVER V.007`).
- Run `./code-server-compile.sh` — `make recode` and copy `PocketFever.dsk` to `../../www/gamez`. Always deploy before commit+push so the playable DSK is what gets tested.
- `git commit` and `git push`. Do not wait to be asked.

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
```

Runs the built game in `../tools/amspirit-lite` (headless), writes ball state into the entity pool through a Lua script and samples every ball each frame. Covers collision separation against all four cushions, the separation axis for every relative position, plus seeded random rounds (`--seed N`). Needs port 6128 free. Edits to a `.h.s` need `make clean && make` first (the Makefile does not track header dependencies).

## Commands

`cpct_winape -as -f` after build.
