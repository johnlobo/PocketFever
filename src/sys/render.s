;;-----------------------------LICENSE NOTICE------------------------------------
;;
;;  This program is free software: you can redistribute it and/or modify
;;  it under the terms of the GNU Lesser General Public License as published by
;;  the Free Software Foundation, either version 3 of the License, or
;;  (at your option) any later version.
;;
;;  This program is distributed in the hope that it will be useful,
;;  but WITHOUT ANY WARRANTY; without even the implied warranty of
;;  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;  GNU Lesser General Public License for more details.
;;
;;  You should have received a copy of the GNU Lesser General Public License
;;  along with this program.  If not, see <http://www.gnu.org/licenses/>.
;;-------------------------------------------------------------------------------

.module render_system

.include "cpctelera.h.s"
.include "sys/render.h.s"
.include "globals.inc"

;;
;; Start of _CODE area
;;
.area _CODE

;;-----------------------------------------------------------------
;; sys_render_clear_buffer (internal)
;;   Input: HL = start address of an 8x2K-block (16K) screen buffer
;;   Modified: AF, BC, DE, HL
;; Code taken from Miss Input (via model01/src/sys/render.s).
sys_render_clear_buffer:
    ld a, #8
srender_clear_raster_block:
    ld (hl), #0
    ld d, h
    ld e, l
    inc de
    ld bc, #0x07D0-1                 ;; 2,000 visible bytes in this 2K block
    ldir
    ex de, hl                        ;; hl = first byte of the invisible tail
    ld bc, #0x0030                   ;; skip its 48 bytes to the next 2K block
    add hl, bc
    dec a
    jr nz, srender_clear_raster_block
    ret

;;-----------------------------------------------------------------
;;
;; sys_render_clear_front_buffer
;;
;;  Clears the front buffer (0xC000-0xFFFF) to black.
;;  Modified: AF, BC, DE, HL
;;
sys_render_clear_front_buffer::
    ld hl, #0xC000
    call sys_render_clear_buffer
    ret

;;-----------------------------------------------------------------
;;
;; sys_render_pen_solid_byte
;;
;;  Drop-in replacement for cpct_px2byteM0_asm when both sub-pixels are
;;  the SAME pen (the only way this project ever calls it: solid box
;;  fills). cpct_px2byteM0_asm has a real, confirmed engine bug: its
;;  internal add_de_a macro does "sub a" to zero A while (per its own
;;  comment) "preserving the Carry flag" -- but SUB A on a real Z80
;;  always computes A-A, which unconditionally CLEARS carry (A-A can
;;  never borrow). So any carry from the preceding 8-bit table-index add
;;  is silently dropped before the high-byte ADC, corrupting the lookup
;;  address whenever cpct_dc_mode0_ct (the engine's fixed, not-256-byte-
;;  aligned pen-conversion table) plus the pen value overflows a byte --
;;  which happens for specific pen values depending on wherever the
;;  linker happens to place that table. Confirmed by hand-decoding
;;  corrupted output bytes for several pens (2026-08-23) after ruling out
;;  every part of this project's OWN drawing/masking code via exhaustive
;;  simulation. cpct_pens2pixelPatternPairM0_asm's lookup instead uses a
;;  real 16-bit ADD HL,BC (no such bug) -- reuse it here with OldPen=
;;  NewPen=the same pen, which naturally produces "both sub-pixels this
;;  pen". Do NOT reintroduce a direct cpct_px2byteM0_asm call for a
;;  solid-fill byte anywhere in this project; go through this instead.
;;  Input:  H = L = pen (0-15) -- same calling shape as cpct_px2byteM0_asm
;;          had, so callers only need their `call` target changed
;;  Output: L = pattern byte (both sub-pixels = pen)
;;  Modified: AF, BC, DE, HL
;;
sys_render_pen_solid_byte::
    ld a, l
    ld d, a
    ld e, a
    call cpct_pens2pixelPatternPairM0_asm
    ld l, e
    ret

;;-----------------------------------------------------------------
;;
;; sys_render_draw_box
;;
;;  Draws a box outline (border only, one pixel-row thick top/bottom, one
;;  byte thick left/right) or a filled box, at the given screen address.
;;  Adapted from DeckHero's sys_messages_draw_box (src/sys/messages.s) —
;;  DeckHero draws its map-node frames this way, not with a plain filled
;;  cpct_drawSolidBox_asm rectangle, which is why theirs looks "framed"
;;  instead of a flat block.
;;  Input:  DE = video memory address, upper-left corner
;;          A  = colour pattern (mode-0 screen-format byte, e.g. from
;;               cpct_px2byteM0_asm)
;;          C  = width in bytes [1-64]
;;          B  = height in bytes (>0)
;;          L  = 0 for border only, nonzero to also fill the interior
;;  Output:
;;  Modified: AF, BC, DE, HL
;;
sys_render_draw_box::
    push af
    ld a, l
    or a
    jr z, srdb_empty
    cpctm_push de, bc
    ld a, #0x00
    call cpct_drawSolidBox_asm
    cpctm_pop bc, de
srdb_empty:
    pop af
    ld (srdb_border+1), a
    ld (srdb_border2+1), a
    ld (srdb_line+1), a
    ld a, c
    ld (srdb_width), a
    ld h, d
    ld l, e
    inc b
    jr srdb_line

srdb_next_line:
    ld a, b
    dec a
    or a
    ret z
    ld b, a
    ld a, (srdb_width)
    ld c, a
    ld a, b
    cp #1
    jr z, srdb_line
srdb_border:
    ld (hl), #0xff
    ld a, c
    dec a
    add_hl_a
srdb_border2:
    ld (hl), #0xff
    jr srdb_down_line

srdb_line:
    ld (hl), #0xff
    inc hl
    dec c
    ld a, c
    or a
    jr nz, srdb_line

srdb_down_line:
    ld a, #8
    add d
    ld h, a
    ld d, a
    ld l, e
    and #0x38
    jp nz, srdb_next_line
    ld hl, #0xC050
    add hl, de
    ld d, h
    ld e, l
    jp srdb_next_line

srdb_width: .db 0

;;-----------------------------------------------------------------
;;
;; sys_render_draw_box_xor
;;
;;  Same border-only geometry as sys_render_draw_box (top/bottom full
;;  rows, left/right single bytes per middle row, same interleaved-
;;  scanline row-stepping), but XORs the pattern onto the existing screen
;;  content instead of overwriting it. Calling this twice at the same DE
;;  with the same pattern draws then perfectly erases the border, with no
;;  need to know or redraw whatever was underneath (used for a selection
;;  box that moves over other art every frame without repainting it).
;;  No fill option — this is only ever used border-only.
;;  Input:  DE = video memory address, upper-left corner
;;          A  = colour pattern (mode-0 screen-format byte)
;;          C  = width in bytes [1-64]
;;          B  = height in bytes (>0)
;;  Output:
;;  Modified: AF, BC, DE, HL
;;
sys_render_draw_box_xor::
    ld (srdbx_pattern), a
    ld a, c
    ld (srdbx_width), a
    ld h, d
    ld l, e
    inc b
    jr srdbx_line

srdbx_next_line:
    ld a, b
    dec a
    or a
    ret z
    ld b, a
    ld a, (srdbx_width)
    ld c, a
    ld a, b
    cp #1
    jr z, srdbx_line
    ld a, (srdbx_pattern)
    xor (hl)
    ld (hl), a
    ld a, c
    dec a
    add_hl_a
    ld a, (srdbx_pattern)
    xor (hl)
    ld (hl), a
    jr srdbx_down_line

srdbx_line:
    ld a, (srdbx_pattern)
    xor (hl)
    ld (hl), a
    inc hl
    dec c
    ld a, c
    or a
    jr nz, srdbx_line

srdbx_down_line:
    ld a, #8
    add d
    ld h, a
    ld d, a
    ld l, e
    and #0x38
    jp nz, srdbx_next_line
    ld hl, #0xC050
    add hl, de
    ld d, h
    ld e, l
    jp srdbx_next_line

srdbx_pattern: .db 0
srdbx_width: .db 0

;;-----------------------------------------------------------------
;;
;; sys_render_drawSpriteMaskedAlignedColorizeM0_asm
;;
;;  Draws a masked mode-0 sprite while swapping one pen for another on the
;;  fly (used to recolour the small-digit HUD numbers — see
;;  sys_text_draw_small_char_number, sys/text.s). Ported verbatim from
;;  DeckHero's src/sys/render.s (credited there to @Docent, CPCWiki). Uses
;;  IX/IY half-registers via the engine's undocumented-opcode macros
;;  (available through cpctelera.h.s's allmacros.h.s include, same as this
;;  file's cpctm_push/pop usage above) — do not "clean up" the ld__ixl_a
;;  style calls, they're real Z80 undocumented opcodes, not typos.
;;  Input:  AF = sprite address (A=high,F unused/low via push af convention
;;               below — see caller in sys/text.s for the exact call shape)
;;          DE = video memory destination
;;          BC = height(B) and width(C) of the sprite, in bytes
;;          HL = replacement pattern pair from cpct_pens2pixelPatternPairM0_asm
;;          IX = transparency/mask table (this project's transparency_table)
;;  Output:
;;  Modified: AF, BC, DE, HL, IX, IY
;;
sys_render_drawSpriteMaskedAlignedColorizeM0_asm::
   ld (dms_restore_ix + 2), ix
   push  af
   ld   (aligned_mask_table), ix

   ld    a, l
   xor   h
   ld__iyl_a

   ld    a, h
   ld__ixl_a

   ld__iyh_c
   pop   hl

height_loop:
   push  de

width_loop:
   ld__a_ixl
   xor  (hl)
   ld__ixh_a

   rrca
   rrca
   or__ixh
   ld__ixh_a
   rrca
   rrca
   rrca
   rrca
   or__ixh
   cpl

   and__iyl
   xor  (hl)

   push  hl
aligned_mask_table = .+1
  ld     hl, #0000

   ld    l, a
   ld    a, (de)
   and  (hl)
   or    l

   pop  hl

   ld  (de), a
   inc   hl
   inc   de

   dec   c
   jp    nz, width_loop

   pop   de
   dec   b
   jp    z, end_sprite_colourize

   ld__c_iyh
   ld    a, d
   add   #0x08
   ld    d, a
   and   #0x38
   jp    nz, height_loop

   ld    a, e
   add   #0x50
   ld    e, a
   ld    a, d
   adc   #0xC0
   ld    d, a
   jp    height_loop

end_sprite_colourize:

dms_restore_ix:
   ld   ix, #0000
   ret
