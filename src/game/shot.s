;; Random test shot: each SPACE press fires the cue ball (slot 0) in one of
;; 32 directions with a random power. Testing aid until real aiming exists.
.module game_shot

.include "cpctelera.h.s"
.include "globals.inc"
.include "sys/array.h.s"
.include "sys/entity.h.s"
.include "game/shot.h.s"

.area _DATA

gsu_was_down: .db 0
gsu_seeded:   .db 0

.area _CODE

;;-----------------------------------------------------------------
;;
;; game_shot_update
;;
;;  Fires on the press edge only: holding SPACE gives one shot. The random
;;  generator is seeded on the first press, so the player's timing (R
;;  register, interrupt phase) decides the sequence.
;;  Input:
;;  Output:
;;  Modified: AF, BC, DE, HL, IX
;;
game_shot_update::
    ld hl, #Key_Space
    call cpct_isKeyPressed_asm
    jr nz, gsu_down
    xor a
    ld (gsu_was_down), a
    ret
gsu_down:
    ld a, (gsu_was_down)
    or a
    ret nz
    inc a
    ld (gsu_was_down), a
    ld a, (gsu_seeded)
    or a
    jr nz, gsu_fire
    inc a
    ld (gsu_seeded), a
    call sys_util_seed_random
gsu_fire:
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
    push bc
    push de
    ld a, #SHOT_POWER_SPAN
    call sys_util_get_random_number
    add a, #SHOT_POWER_MIN
    ld b, a
    ld ix, #entities+a_array
    pop de
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
