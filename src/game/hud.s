;; Live ANGLE/POWER readout above the table (see hud.h.s). Labels are drawn
;; once at boot (they never change); the numbers are redrawn only when the
;; value actually changed, same "skip work nothing needs" principle as
;; sys/entity.s's SkipIfSettled -- gaim_index can hold steady for many
;; frames while aiming, and gsu_power steps at most once every
;; SHOT_CHARGE_STEP frames, so most frames have nothing new to draw.
;;
;; Numbers use sys_text_draw_string (the regular font), not sys_text_draw_
;; small_char_number's small HUD-digit font: that routine has a confirmed
;; repeat-call bug (see its header comment in sys/text.s). sys_text_draw_
;; string doesn't have THAT bug, but it shares the same underlying
;; limitation: sys_text_draw_char draws through a MASK (cpct_drawSprite
;; MaskedAlignedTable_asm), so it only ever paints "ink" pixels and leaves
;; whatever was already there for the rest -- fine for a label drawn once,
;; but redrawing "195" over "180" at the same spot without erasing first
;; leaves both digits' ink mixed together (confirmed: looked like garbled
;; overlaid glyphs, not either number). So every redraw here clears the
;; field to the HUD's black background with a solid box first, exactly the
;; way game/shot.s's gsu_clear_bar/gsu_draw_segment already do for the
;; charge bar -- same codebase pattern, same reason.
;;
;; The ANGLE redraw is skipped entirely while either cursor key is held.
;; Not just an optimisation: a real per-call cost was measured against
;; sys_text_draw_string here that isn't explained by its documented timing
;; (~1.7ms for a 3-char field) -- observed closer to a full frame's worth,
;; severe enough that redrawing every held frame during a fast continuous
;; turn measurably dropped real game-loop iterations (tests/turn_test.py
;; started failing: the turn ramp's own input-latency calibration is exact
;; enough to notice). Not root-caused (the individual pieces -- the glyph
;; recolour loop, sys_util_h_times_e, the masked blit's documented cost --
;; all check out far too cheap to explain it) -- worth investigating
;; properly if this module grows more live text. Gating on "not currently
;; turning" sidesteps it AND is arguably the more honest UX: while
;; continuously spinning through 256 directions, the angle changes many
;; times a second anyway, faster than a human reads a 3-digit number --
;; showing the settled value the instant the key is released is what
;; actually matters, and that's exactly what a normal (ungated) compare
;; against hud_last_angle produces the very first frame turning stops.
.module game_hud

.include "cpctelera.h.s"
.include "globals.inc"
.include "game/hud.h.s"

.area _DATA

hud_angle_label: .asciz "ANGLE:"
hud_power_label: .asciz "POWER:"
hud_angle_str: .ds 4            ;; 3 ASCII digits + null, sys_text_num_to_ascii3
hud_power_str: .ds 4

;; 0xFFFF never matches a real degrees (0-358) or power (0, or SHOT_POWER_MIN
;; ..MIN+SPAN) value, so the first game_hud_update call always draws both
;; fields once, regardless of gaim_index/gsu_power's actual boot values.
hud_last_angle: .dw 0xFFFF
hud_last_power: .dw 0xFFFF

.area _CODE

;;-----------------------------------------------------------------
;;
;; game_hud_init
;;
;;  Draws the two static labels once. Call before the main loop.
;;  Input:
;;  Output:
;;  Modified: AF, BC, DE, HL, IX, IY
;;
game_hud_init::
    cpctm_screenPtr_asm de, 0xC000, HUD_ANGLE_LABEL_X_BYTES, HUD_ROW_Y_PX
    ld hl, #hud_angle_label
    ld c, #0
    call sys_text_draw_string

    cpctm_screenPtr_asm de, 0xC000, HUD_POWER_LABEL_X_BYTES, HUD_ROW_Y_PX
    ld hl, #hud_power_label
    ld c, #0
    jp sys_text_draw_string

;;-----------------------------------------------------------------
;;
;; game_hud_update
;;
;;  Redraws ANGLE if gaim_index's degrees changed AND neither cursor key is
;;  currently held (see the module comment above), POWER if gsu_power did
;;  (unconditionally -- charging never showed this cost, since gsu_power
;;  only steps once every SHOT_CHARGE_STEP frames on its own). gsu_power
;;  reads 0 while not charging, drawn as "000".
;;  Input:
;;  Output:
;;  Modified: AF, BC, DE, HL, IX, IY
;;
game_hud_update::
    ld hl, #Key_CursorLeft
    call cpct_isKeyPressed_asm
    jr nz, ghu_power                ;; turning: skip the angle field entirely
    ld hl, #Key_CursorRight
    call cpct_isKeyPressed_asm
    jr nz, ghu_power

    ;; --- angle: shot_degrees[gaim_index], a plain word table (2 bytes per
    ;; entry -- NOT shot_directions's 4-byte dx/dy pairs) ---
    ld a, (gaim_index)
    ld l, a
    ld h, #0
    add hl, hl                     ;; index*2
    ld de, #shot_degrees
    add hl, de
    ld e, (hl)
    inc hl
    ld d, (hl)                     ;; DE = degrees (0-358)

    ld hl, (hud_last_angle)
    or a
    sbc hl, de
    jr z, ghu_power                ;; unchanged: skip straight to power

    ld (hud_last_angle), de
    ex de, hl                      ;; HL = degrees (sys_text_num_to_ascii3's value input)
    ld de, #hud_angle_str
    call sys_text_num_to_ascii3

    cpctm_screenPtr_asm de, 0xC000, HUD_ANGLE_NUM_X_BYTES, HUD_ROW_Y_PX
    ld c, #HUD_NUM_WIDTH_BYTES
    ld b, #FONT_HEIGHT
    xor a                           ;; pattern 0 = black, the HUD's background
    call cpct_drawSolidBox_asm

    cpctm_screenPtr_asm de, 0xC000, HUD_ANGLE_NUM_X_BYTES, HUD_ROW_Y_PX
    ld hl, #hud_angle_str
    ld c, #HUD_TEXT_COLOUR_WHITE
    call sys_text_draw_string

ghu_power:
    ld a, (gsu_power)
    ld l, a
    ld h, #0                       ;; HL = power (0 if not charging), zero-extended
    ex de, hl                      ;; DE = power value

    ld hl, (hud_last_power)
    or a
    sbc hl, de
    ret z                          ;; unchanged: nothing left to do

    ld (hud_last_power), de
    ex de, hl
    ld de, #hud_power_str
    call sys_text_num_to_ascii3

    cpctm_screenPtr_asm de, 0xC000, HUD_POWER_NUM_X_BYTES, HUD_ROW_Y_PX
    ld c, #HUD_NUM_WIDTH_BYTES
    ld b, #FONT_HEIGHT
    xor a
    call cpct_drawSolidBox_asm

    cpctm_screenPtr_asm de, 0xC000, HUD_POWER_NUM_X_BYTES, HUD_ROW_Y_PX
    ld hl, #hud_power_str
    ld c, #HUD_TEXT_COLOUR_WHITE
    jp sys_text_draw_string
