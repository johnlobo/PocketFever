;;-----------------------------LICENSE NOTICE------------------------------------
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

;; Ported from model01/src/sys/text.s (itself shared lineage with DeckHero's
;; sys/text.s — same font asset, same FONT_WIDTH/HEIGHT, same char-index
;; mapping). Trimmed to what's needed now: init, string utilities, char/string
;; drawing. NOT ported: sys_text_num2str8 / draw_small_char_number /
;; draw_small_number — those need a small-numbers icon asset and
;; sys_render_drawSpriteMaskedAlignedColorizeM0_asm, neither of which exist in
;; DeckTower yet. Add them back the same way (copy from model01) once a screen
;; actually needs to print numbers.
;;
;; sys_text_draw_char recolors glyphs via a 4-pattern Mode 0 swap
;; (0c/sc/cc/c0). Shadow mix is Pen 14 (Blue). See _swapColors.

.module text_manager

.include "cpctelera.h.s"
.include "globals.inc"

FONT_WIDTH = 2
FONT_HEIGHT = 9

;;
;; Start of _DATA area
;;
.area _DATA

aux_txt:: .ds 20
sys_text_font: .dw 0

;;
;; Start of _CODE area
;;
.area _CODE

;;-----------------------------------------------------------------
;;
;; sys_text_init
;;
;;  Registers the game-provided font sprite base.
;;  Input: HL = font sprite base
;;  Output:
;;  Modified: None
;;
sys_text_init::
    ld (sys_text_font), hl
    ret

;;-----------------------------------------------------------------
;;
;; sys_text_str_length
;;
;;  Counts characters up to the terminating zero byte.
;;  Input: HL = zero-terminated string
;;  Output: A = character count
;;  Modified: AF, B, HL
;;
sys_text_str_length::
    ld b, #0
str_length_loop:
    ld a, (hl)
    or a
    jr z, str_length_exit
    inc b
    inc hl
    jr str_length_loop
str_length_exit:
    ld a, b
    ret

;;-----------------------------------------------------------------
;;
;; sys_text_str_copy
;;
;;  Copies the nonzero characters of a string to a destination buffer.
;;  Input: HL = source string; DE = destination buffer
;;  Output: DE points one byte past copied data; no terminator is appended
;;  Modified: AF, BC, DE, HL
;;
sys_text_str_copy::
    ld (str_copy_savehl), hl
    call sys_text_str_length
str_copy_savehl = .+1
    ld hl, #0000
    ld b, #0
    ld c, a
    ldir
    ret

;;-----------------------------------------------------------------
;;
;; sys_text_str_cmp
;;
;;  Compares two zero-terminated strings.
;;  Input: HL = first string; DE = second string
;;  Output: A = 1 when equal, A = 0 otherwise
;;  Modified: AF, BC, DE, HL
;;
sys_text_str_cmp::
    ld a, (hl)
    or a
    jr z, str_cmp_check_last_pair
    push af
    ld a, (de)
    or a
    jr z, str_cmp_exit_false
    pop bc
    cp b
    jr nz, str_cmp_exit_false
    inc hl
    inc de
    jr sys_text_str_cmp
str_cmp_check_last_pair:
    ld a, (de)
    or a
    jr nz, str_cmp_exit_false
str_cmp_exit_true:
    ld a, #1
    ret
str_cmp_exit_false:
    xor a
    ret

;;-----------------------------------------------------------------
;;
;; sys_text_draw_char
;;
;;  Recolors and draws one font glyph with masked transparency.
;;  Input: HL = glyph sprite; DE = video address; A = color (0-5); C = width; B = height
;;  Output:
;;  Modified: AF, BC, DE, HL, IX
;;
sys_text_draw_char::
    push de
    push bc
    push hl
    sla a
    sla a       ;; color * 4 (one byte per font pattern: 0c, sc, cc, c0)
    ld hl, #_swapColors
    add_hl_a
    push hl
    pop ix
    ld h, c
    ld e, b
    call sys_util_h_times_e
    ld b, h
    ld c, l
    pop hl
    ld de, #_char_buffer
_std_loop:
    ld a, (hl)
    cp #0x55                    ;; 0c
    jr z, _std_first_byte
    cp #0xBF                    ;; sc — Pen 14 (Blue) + 15
    jr z, _std_second_byte
    cp #0xff                    ;; cc
    jr z, _std_third_byte
    cp #0xaa                    ;; c0
    jr z, _std_forth_byte
    jr _std_continue
_std_first_byte:
    ld a, 0(ix)
    jr _std_modified_byte
_std_second_byte:
    ld a, 1(ix)
    jr _std_modified_byte
_std_third_byte:
    ld a, 2(ix)
    jr _std_modified_byte
_std_forth_byte:
    ld a, 3(ix)
_std_modified_byte:
_std_continue:
    ld (de), a
    inc hl
    inc de
    dec c
    ld a, c
    or a
    jr nz, _std_loop
    ld bc, #_char_buffer
    pop ix
    pop de
    ld hl, #transparency_table
    call cpct_drawSpriteMaskedAlignedTable_asm
    ret

;; Mode 0: 2 pixels/byte. Font only contains 0c, sc, cc, c0 (c=pen15).
;; Shadow mix is Pen 14 (Blue, FW1). sc source = encode(14,15) = 0x7F.
;; Each row: encode(0,t), encode(14,t), encode(t,t), encode(t,0).
_swapColors:
    .db 0x55, 0xBF, 0xFF, 0xAA   ;; 0: White          (pen15)
    .db 0x14, 0x3D, 0x3C, 0x28   ;; 1: Magenta        (pen6)
    .db 0x50, 0xB5, 0xF0, 0xA0   ;; 2: Orange         (pen5)
    .db 0x04, 0x1D, 0x0C, 0x08   ;; 3: Bright Blue    (pen2)
    .db 0x10, 0x35, 0x30, 0x20   ;; 4: Bright Red     (pen4)
    .db 0x45, 0x9F, 0xCF, 0x8A   ;; 5: Bright Green   (pen11)
    .db 0x41, 0x97, 0xC3, 0x82   ;; 6: Yellow         (pen9)
    .db 0x05, 0x1F, 0x0F, 0x0A   ;; 7: Green          (pen10)
    .db 0x01, 0x17, 0x03, 0x02   ;; 8: Bright Yellow  (pen8)
    .db 0x11, 0x37, 0x33, 0x22   ;; 9: Bright Cyan    (pen12)
    .db 0x51, 0xB7, 0xF3, 0xA2   ;; 10: Sky Blue      (pen13)
    .db 0x00, 0x15, 0x00, 0x00   ;; 11: Black         (pen0)
    .db 0x40, 0x95, 0xC0, 0x80   ;; 12: White         (pen1)
    .db 0x44, 0x9D, 0xCC, 0x88   ;; 13: Red           (pen3)
    .db 0x54, 0xBD, 0xFC, 0xA8   ;; 14: Pink          (pen7)
    ;; pen14 (Blue, FW1) deliberately has no row — that's the fixed shadow
    ;; ink baked into every OTHER row instead (see the "Shadow mix" comment
    ;; above), not a selectable foreground colour. Every PALETTE0 pen is now
    ;; covered except that one.
_char_buffer:: .db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0

;;-----------------------------------------------------------------
;;
;; sys_text_draw_string
;;
;;  Draws a zero-terminated string with the configured font.
;;  Input: HL = string; DE = video address; C = color
;;  Output:
;;  Modified: AF, BC, DE, HL, IX, IY
;;
sys_text_draw_string::
    cpctm_push ix, iy
    ld a, c
    ld (_string_color), a
draw_string_2:
    cpctm_push de, hl
    ld a, (hl)
    or a
    jr z, _draw_string_exit
    cp #32                          ;; space -> next char
    jr z, _next_char
    cp #33                          ;; exclamation sign
    jr z, _exclamation
    cp #45                          ;; '-' — same collision as ':' below
    jr z, _hyphen                   ;; (falls into the digit-index formula
                                     ;; otherwise), own dedicated glyph at
                                     ;; the end of the strip (index 49)
    cp #47                          ;; '/' — same collision as ':' below
    jr z, _slash                    ;; (falls into the digit-index formula
                                     ;; otherwise), own dedicated glyph at
                                     ;; the end of the strip (index 48)
    cp #58                          ;; colon — the ?@A-Z/digit index formulas
    jr z, _colon                    ;; below collide at ':', so it gets its
                                     ;; own dedicated glyph appended at the
                                     ;; end of the strip (index 47) instead
    cp #62                          ;; '>' — same collision as ':' above,
    jr z, _gt                       ;; but on the ?@A-Z side (falls into
                                     ;; _rest_of_chars otherwise), own
                                     ;; dedicated glyph at index 50
    cp #58                          ;; digits
    jr c, _numbers
_rest_of_chars:
    sub #44                         ;; chars from ? to Z
    jr _draw_char
_colon:
    ld a, #47
    jr _draw_char
_slash:
    ld a, #48
    jr _draw_char
_hyphen:
    ld a, #49
    jr _draw_char
_gt:
    ld a, #50
    jr _draw_char
_exclamation:
    ld a, #0
    jr _draw_char
_numbers:
    sub #39
_draw_char:
    push de
    ld h, #FONT_WIDTH
    ld e, #FONT_HEIGHT
    call sys_util_h_times_e         ;; hl = WIDTH * HEIGHT
    ld e, a                         ;; char position
    ld h, l
    call sys_util_h_times_e         ;; hl = WIDTH * HEIGHT * char position
    ld de, (sys_text_font)
    add hl, de
    pop de
    ld c, #FONT_WIDTH
    ld b, #FONT_HEIGHT
    ld a, (_string_color)
    call sys_text_draw_char
_next_char:
    pop hl
    inc hl
    pop de
    inc de
    inc de
    jr draw_string_2
_draw_string_exit:
    cpctm_pop hl, de, iy, ix
    ret
_string_color: .db 0

;;-----------------------------------------------------------------
;;
;; sys_text_draw_small_char_number
;;
;;  Draws one digit (0-9) of DeckHero's small-digit HUD font
;;  (_s_small_numbers_00.._09, assets/small_numbers.png), recoloured on the
;;  fly via cpct_pens2pixelPatternPairM0_asm — OldPen is hardcoded to 15
;;  because that's the pen slot the asset's white ink lands on when
;;  converted under THIS project's own PALETTE0 (position 15 = firmware
;;  colour 26 = white — verified, not assumed; same convention DeckHero's
;;  copy of the asset happens to use too). Ported from DeckHero's
;;  src/sys/text.s. Requires sys_render_drawSpriteMaskedAlignedColorizeM0_asm
;;  (sys/render.s) and this project's transparency_table (main.s).
;;  Input:  A = digit (0-9), DE = video address, B = colour (pen 0-15)
;;  Output:
;;  Modified: AF, BC, DE, HL, IX
;;
sys_text_draw_small_char_number::
    push de

    ld h, #10
    ld e, a
    call sys_util_h_times_e         ;; l = 10 * digit

    ld a, b
    ld (stdscn_color), a

    ld b, #0
    ld c, l
    ld hl, #_s_small_numbers_00
    add hl, bc
    push hl

    ld d, #15                       ;; OldPen: white, see doc comment above
stdscn_color = . + 1
    ld e, #0                        ;; NewPen: self-modified from the B param
    call cpct_pens2pixelPatternPairM0_asm
    ex de, hl

    pop af
    pop de
    ld c, #S_SMALL_NUMBERS_WIDTH
    ld b, #S_SMALL_NUMBERS_HEIGHT
    push ix
    push iy                         ;; sys_render_drawSpriteMaskedAlignedColorizeM0_asm
                                     ;; uses IY as scratch and does NOT restore it (only
                                     ;; IX) — real bug hit in testing: when this runs
                                     ;; while sys_input_generic_update (sys/input.s) is
                                     ;; mid-dispatch, IY is that routine's own live
                                     ;; key-table walk pointer; clobbering it here made
                                     ;; the dispatcher resume scanning from garbage
                                     ;; memory and jump to a random "handler" address,
                                     ;; resetting the emulator. Save/restore it here too.
    ld ix, #transparency_table
    call sys_render_drawSpriteMaskedAlignedColorizeM0_asm
    pop iy
    pop ix
    ret

;;-----------------------------------------------------------------
;;
;; sys_text_draw_big_char_number
;;
;;  Same recolour trick as sys_text_draw_small_char_number, but draws one
;;  digit (0-9) at the REGULAR font's size (FONT_WIDTH x FONT_HEIGHT, same
;;  glyph frames sys_text_draw_string itself uses) instead of the small HUD
;;  digit font. Exists so a number embedded in regular text (e.g. a card
;;  description's damage value) can be recoloured in place without looking
;;  mismatched in size against the surrounding white text — sys_text_draw_
;;  char's own colouring (the _swapColors byte-substitution table above)
;;  is NOT used here: it's flagged unverified for this project's actual
;;  PALETTE0 ordering (see its header comment), whereas this routine reuses
;;  the SAME proven cpct_pens2pixelPatternPairM0_asm + colorize-blit
;;  pipeline already confirmed correct for this palette (small numbers,
;;  status icons, intention). Frame index = digit + 9, same "sub 39 from
;;  ASCII '0'" mapping draw_string_2 itself uses for digits.
;;  Input:  A = digit (0-9), DE = video address, B = colour (pen 0-15)
;;  Output:
;;  Modified: AF, BC, DE, HL, IX
;;
sys_text_draw_big_char_number::
    push de

    add a, #9                       ;; digit -> font strip frame index
    ld h, #(FONT_WIDTH*FONT_HEIGHT) ;; bytes per frame
    ld e, a
    call sys_util_h_times_e         ;; hl = frame_index * bytes_per_frame —
                                     ;; unlike small_numbers (max offset 90,
                                     ;; always < 256), the big font's max
                                     ;; offset is 18*18=324, so the high
                                     ;; byte (H) is real here and must not
                                     ;; be dropped (sys_util_h_times_e
                                     ;; itself already sets D=0, so DE holds
                                     ;; the full 16-bit product too)
    ld a, b
    ld (stdbcn_color), a

    ld b, h
    ld c, l
    ld hl, #_s_font_0
    add hl, bc
    push hl

    ld d, #15                       ;; OldPen: white, same verified slot as
stdbcn_color = . + 1                ;; sys_text_draw_small_char_number
    ld e, #0                        ;; NewPen: self-modified from the B param
    call cpct_pens2pixelPatternPairM0_asm
    ex de, hl

    pop af
    pop de
    ld c, #FONT_WIDTH
    ld b, #FONT_HEIGHT
    push ix
    push iy                         ;; see sys_text_draw_small_char_number's
                                     ;; comment — same IY-clobber gotcha
    ld ix, #transparency_table
    call sys_render_drawSpriteMaskedAlignedColorizeM0_asm
    pop iy
    pop ix
    ret
