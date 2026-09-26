;; Test shot: hold SPACE to charge, release to fire the cue ball (slot 0) in
;; the aimed direction (game/aim.s owns gaim_index; left/right cursor keys
;; aim, an XOR line shows it). Power is deterministic; direction is whatever
;; the player is pointing at, never random.
.module game_shot

.include "cpctelera.h.s"
.include "globals.inc"
.include "sys/array.h.s"
.include "sys/entity.h.s"
.include "game/shot.h.s"

.area _DATA

gsu_power:  .db 0              ;; 0 = not charging, else current power
gsu_tick:   .db 0              ;; frames held since the last power step
gsu_fire_power: .db 0          ;; gsu_fire's own working state
gsu_dx:         .dw 0
gsu_dy:         .dw 0

.area _CODE

;;-----------------------------------------------------------------
;;
;; game_shot_update
;;
;;  Pressed: start or keep charging (bar grows one segment per level).
;;  Released after charging: fire with the charged power in gaim_index's
;;  direction, clear the bar.
;;  Input:
;;  Output:
;;  Modified: AF, BC, DE, HL, IX
;;
game_shot_update::
    ld hl, #Key_Space
    call cpct_isKeyPressed_asm
    jr z, gsu_released
    ld a, (gsu_power)
    or a
    jr nz, gsu_charging
    xor a
    ld (gsu_tick), a
    ld a, #SHOT_POWER_MIN
    ld (gsu_power), a
    jp gsu_draw_segment
gsu_charging:
    cp #SHOT_POWER_MIN+SHOT_POWER_SPAN
    ret nc
    ld hl, #gsu_tick
    inc (hl)
    ld a, (hl)
    cp #SHOT_CHARGE_STEP
    ret c
    ld (hl), #0
    ld hl, #gsu_power
    inc (hl)
    jp gsu_draw_segment

gsu_released:
    ld a, (gsu_power)
    or a
    ret z
    push af
    xor a
    ld (gsu_power), a
    call gsu_clear_bar
    pop af
    ;; fall through with A = power

;;  Input: A = power (SHOT_POWER_MIN..MIN+SPAN)
;;  Output:
;;  Modified: AF, BC, DE, HL, IX
gsu_fire:
    ld (gsu_fire_power), a
    ;; index*4 in 16-bit HL, not the old 8-bit "add a,a" x2 -- DIRECTIONS=256
    ;; (V.017, was 64) means index can be up to 255, and 255*4=1020 overflows
    ;; a single byte (the old trick only worked because 63*4=252 fit).
    ld a, (gaim_index)
    ld l, a
    ld h, #0
    add hl, hl
    add hl, hl
    ld de, #shot_directions
    add hl, de
    ld e, (hl)
    inc hl
    ld d, (hl)
    ld (gsu_dx), de
    inc hl
    ld e, (hl)
    inc hl
    ld d, (hl)
    ld (gsu_dy), de

    ld ix, #entities+a_array
    ld a, (gsu_fire_power)
    ld b, a
    ld de, (gsu_dx)
    call gsu_scale
    ld e_vx(ix), l
    ld e_vx+1(ix), h

    ld a, (gsu_fire_power)
    ld b, a
    ld de, (gsu_dy)
    call gsu_scale
    ld e_vy(ix), l
    ld e_vy+1(ix), h
    ret

;; HL = DE * B (signed 8.8 times a small count). Preserves B.
gsu_scale:
    push bc
    ld hl, #0
gsu_scale_loop:
    add hl, de
    djnz gsu_scale_loop
    pop bc
    ret

;; Draws the bar segment for the current power level.
gsu_draw_segment:
    ld a, (gsu_power)
    sub #SHOT_POWER_MIN
    add a, a
    add a, #SHOT_BAR_X_BYTES
    ld c, a
    ld b, #SHOT_BAR_Y_PX
    ld de, #0xC000
    call cpct_getScreenPtr_asm
    push hl
    ld h, #SHOT_BAR_PEN
    ld l, h
    call sys_render_pen_solid_byte
    ld a, l
    pop de
    ld c, #2
    ld b, #SHOT_BAR_HEIGHT
    jp cpct_drawSolidBox_asm

;; Clears the whole bar to the HUD background (pen 0 = byte 0).
gsu_clear_bar:
    ld c, #SHOT_BAR_X_BYTES
    ld b, #SHOT_BAR_Y_PX
    ld de, #0xC000
    call cpct_getScreenPtr_asm
    ex de, hl
    ld c, #2*(SHOT_POWER_SPAN+1)
    ld b, #SHOT_BAR_HEIGHT
    xor a
    jp cpct_drawSolidBox_asm
