#!/usr/bin/env python3
"""Generate src/sys/ball_blit.s: an unrolled, fixed-shape ball sprite blit.

Replaces cpct_drawSolidBox_asm's generic byte-counting loop (djnz width,
djnz height, recompute the row address every line via a fixed +8-to-H/
wraparound step it re-derives at RUNTIME) with one straight-line sequence of
`ld (hl),reg` writes, one per byte of the shape, generated here at BUILD
time from a plain ASCII-art picture -- same "precompute in Python, the Z80
just executes it" pattern as tools/gen_shot_table.py's direction table.

The shape is given as one row per string, one CHARACTER per MODE-0 PIXEL
('X' = ball ink, '.' = felt/background). Each 2-pixel BYTE in a row is
classified once, here:
  - both pixels 'X'  -> "full" (both sub-pixels are the ball colour)
  - left '.' right 'X' -> "l"    (felt on the left sub-pixel, ball on the right)
  - left 'X' right '.' -> "r"    (ball on the left sub-pixel, felt on the right)
  - both '.'         -> "felt"  (both sub-pixels stay felt -- inside the
                                  bounding box but outside the shape)
Register convention for the generated routines (both DRAW and ERASE use the
same shape and the same per-byte classification, so both are generated
here): HL = video pointer to the shape's top-left byte, B = full pattern,
C = l pattern, D = r pattern, E = felt pattern. DRAW only ever uses B/C/D
for THIS shape (it has no fully-felt byte inside its bounding box -- only
single-pixel corners are cut, and a single cut pixel always shares its byte
with an ink pixel, landing on "l" or "r", never "felt"); ERASE only ever
uses E (a plain felt-coloured box the same size, corners included -- see
CLAUDE.md's "corners are opaque" note for why that's correct).

Address stepping between rows does NOT use cpct_getScreenPtr_asm (a rule
this project already follows for the row's own starting address --
tools/gen_row_table.py's felt_row_addr table -- extended here to the ball's
OWN internal rows): CPC mode-0 screen memory advances by only +8 to the
HIGH byte of the address for a plain "next scanline within the same
8-line character row" step (2048 = 0x0800), and by the 16-bit two's
complement constant 0xC050 ON TOP of that when the step crosses into the
next character row (detected by the just-updated high byte's bits 3-5, the
`(H & 0x38) == 0` check, going to zero) -- the standard CPC "next scanline"
address trick. Verified against a from-scratch reference formula
(addr = 0xC000 + 80*(Y//8) + 2048*(Y&7) + X) for every possible starting
row and several X offsets before ever writing a byte of Z80 (this
docstring update follows that check, not before it).

Byte-to-byte movement WITHIN a row alternates direction (a "boustrophedon"/
serpentine sweep): row 0 is written left-to-right ending on its last byte,
then the row-step lands on that SAME column in row 1, which is written
right-to-left back to the first column, then row 2 forward again, and so
on -- `inc hl`/`dec hl` only, NEVER `inc l`/`dec l` alone, because a 80-byte
row can cross a 256-byte page boundary mid-row (e.g. the row at byte offset
240 spans 240..255 then 0..63 of the next page) and `inc l` would wrap
inside the byte instead of carrying into H.

Usage: python3 tools/gen_ball_blit.py > src/sys/ball_blit.s
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# One row per string, one character per MODE-0 PIXEL. 'X' = ball ink, '.' =
# felt. Corners cut (single pixel each) so a 6x8 box reads as a rounded
# ball, not a square block. Change this (and BALL_HEIGHT_PX in config.h.s
# to match the row count) to reshape the ball; the generator recomputes
# everything else.
SHAPE = [
    ".XXXX.",
    "XXXXXX",
    "XXXXXX",
    "XXXXXX",
    "XXXXXX",
    "XXXXXX",
    "XXXXXX",
    ".XXXX.",
]


def config(name):
    text = (ROOT / "src" / "config.h.s").read_text()
    return int(re.search(rf"^\s*{name}\s*=\s*(\d+)", text, re.M).group(1))


def classify_row(row, width_bytes):
    """Returns a list of 'full'/'l'/'r'/'felt', one per byte in the row."""
    cells = []
    for byte_i in range(width_bytes):
        left, right = row[byte_i * 2], row[byte_i * 2 + 1]
        if left == "X" and right == "X":
            cells.append("full")
        elif left == "." and right == "X":
            cells.append("l")
        elif left == "X" and right == ".":
            cells.append("r")
        elif left == "." and right == ".":
            cells.append("felt")
        else:
            sys.exit(f"bad shape character in row {row!r} at byte {byte_i}")
    return cells


def reg_for(cell):
    return {"full": "b", "l": "c", "r": "d", "felt": "e"}[cell]


def gen_routine(name, rows, width_bytes, use_felt_only):
    """Emits one unrolled routine. If use_felt_only, every byte is written
    with `e` (the erase routine: a plain felt box, corners included --
    ignores the shape's own full/l/r classification entirely, since erasing
    the WHOLE bounding box back to felt is correct regardless of the ball's
    silhouette, see CLAUDE.md)."""
    lines = []
    lines.append(f";;-----------------------------------------------------------------")
    lines.append(f";;")
    lines.append(f";; {name}")
    lines.append(f";;")
    lines.append(f";;  Input: HL = video pointer to the shape's top-left byte,")
    if use_felt_only:
        lines.append(f";;         E = felt pattern (B/C/D unused)")
    else:
        lines.append(f";;         B = full pattern, C = l pattern, D = r pattern (E unused --")
        lines.append(f";;         this shape has no fully-felt byte inside its bounding box)")
    lines.append(f";;  Output:")
    lines.append(f";;  Modified: AF, HL")
    lines.append(f";;")
    lines.append(f"{name}::")

    going_forward = True
    for row_i, row in enumerate(rows):
        is_last_row = row_i == len(rows) - 1
        cells = classify_row(row, width_bytes)
        order = list(range(width_bytes) if going_forward else reversed(range(width_bytes)))
        for pos_i, byte_i in enumerate(order):
            cell = cells[byte_i]
            reg = "e" if use_felt_only else reg_for(cell)
            lines.append(f"    ld (hl), {reg}")
            is_last_byte_of_row = pos_i == len(order) - 1
            if not is_last_byte_of_row:
                lines.append("    inc hl" if going_forward else "    dec hl")
        if not is_last_row:
            lines.append("    ld a, h")
            lines.append("    add a, #8")
            lines.append("    ld h, a")
            lines.append("    and #0x38")
            skip_label = f"{name}_skip_wrap_{row_i}"
            lines.append(f"    jr nz, {skip_label}")
            lines.append("    ld a, l")
            lines.append("    add a, #0x50")
            lines.append("    ld l, a")
            lines.append("    ld a, h")
            lines.append("    adc a, #0xC0")
            lines.append("    ld h, a")
            lines.append(f"{skip_label}:")
        going_forward = not going_forward
    lines.append("    ret")
    return lines


def main():
    width_px = config("BALL_WIDTH_PX")
    width_bytes = config("BALL_WIDTH_BYTES")
    height = config("BALL_HEIGHT_PX")

    if width_px != 6 or width_bytes != 3:
        sys.exit(f"gen_ball_blit.py's SHAPE is hardcoded for a 6px (3-byte) wide ball; "
                 f"config.h.s has BALL_WIDTH_PX={width_px}, BALL_WIDTH_BYTES={width_bytes}. "
                 f"Update SHAPE (and this check) before changing ball width.")
    if len(SHAPE) != height:
        sys.exit(f"SHAPE has {len(SHAPE)} rows but config.h.s's BALL_HEIGHT_PX={height}; "
                 f"they must match. Update SHAPE to add/remove rows.")
    for row in SHAPE:
        if len(row) != width_px:
            sys.exit(f"SHAPE row {row!r} is {len(row)} chars wide, expected {width_px}")

    print(";; GENERATED by tools/gen_ball_blit.py. Do not edit; rerun the script.")
    print(f";; Ball shape ({width_px}x{height}):")
    for row in SHAPE:
        print(f";;   {row}")
    print(".module sys_ball_blit")
    print()
    print(".area _CODE")
    print()
    for line in gen_routine("sys_ball_blit_draw", SHAPE, width_bytes, use_felt_only=False):
        print(line)
    print()
    for line in gen_routine("sys_ball_blit_erase", SHAPE, width_bytes, use_felt_only=True):
        print(line)


if __name__ == "__main__":
    main()
