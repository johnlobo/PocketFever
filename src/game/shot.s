;; Test shot: hold SPACE to charge, release to fire the cue ball (slot 0) in
;; one of 32 random directions. Testing aid until real aiming exists.
.module game_shot

.include "cpctelera.h.s"
.include "globals.inc"
.include "sys/array.h.s"
.include "sys/entity.h.s"
.include "game/shot.h.s"

.area _DATA

gsu_power:  .db 0              ;; 0 = not charging, else current power
gsu_tick:   .db 0              ;; frames held since the last power step
gsu_seeded: .db 0

.area _CODE

;;-----------------------------------------------------------------
;;
;; game_shot_update
;;
;;  Pressed: start or keep charging (bar grows one segment per level).
;;  Released after charging: fire with the charged power, clear the bar.
;;  The random generator is seeded on the first press, so the player's
;;  timing (R register, interrupt phase) decides the sequence.
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
    ld a, (gsu_seeded)
    or a
    jr nz, gsu_start
    inc a
    ld (gsu_seeded), a
    call sys_util_seed_random
gsu_start:
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
gsu_fire:
    push af
    call cpct_getRandom_mxor_u8_asm
    ld a, l
    and #31
    add a, a
    add a, a
    ld e, a
    ld d, #0
    ld hl, #shot_directions
    add hl, de
    ld e, (hl)
    inc hl
    ld d, (hl)
    inc hl
    ld c, (hl)
    inc hl
    ld b, (hl)
    pop af
    push bc
    ld b, a
    ld ix, #entities+a_array
    call gsu_scale
    ld e_vx(ix), l
    ld e_vx+1(ix), h
    pop de
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
