# PocketFever

Amstrad CPC Mode 0, Z80 assembly, CPCtelera. Side Pocket-style 9-ball.

## Build

```bash
make            # → PocketFever.dsk / .sna / .cdt
make clean
make cleanall
```

`CPCT_PATH` required. Load at `0x4000`.

**Version bump + deploy (do this unprompted after every significant change):**
- Bump `_game_version_string` in `src/main.s` (currently ` POCKETFEVER V.002`).
- Run `./code-server-compile.sh` — `make recode` and copy `PocketFever.dsk` to `../../www/gamez`.
- `git commit` and `git push`. Do not wait to be asked.

## Frozen layout

- Felt 160×132 (looks 2:1 on CRT 4:3). HUD 68 px at Y=132.
- Balls 4×6. `src/config.h.s`.

## Architecture

Follows DeckTower/model01: `src/sys/` reusable, `src/game/` not yet. `sys` must not reference `game`.

Copied from DeckTower (trimmed): `system` (6-int chain, keyboard scan on int 2; no sound), `input`, `text`, `messages`. Also `render` and `util` because text/messages need them. Font + small_numbers assets from DeckTower.

## Commands

`cpct_winape -as -f` after build.
