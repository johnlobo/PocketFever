;; 8.8 integrator for table balls. Not model01's platformer physics.
.module physics_system

.include "cpctelera.h.s"
.include "sys/array.h.s"
.include "sys/entity.h.s"
.include "sys/component.inc"
.include "globals.inc"
.include "sys/physics.h.s"

;; Linear friction along the direction of travel, in 1/256 px per frame per
;; frame. Tune with tools/friction_model.py (it models this exact code).
PHYS_FRICTION = 4
;; spf_reduce loops PHYS_FRICTION times through B: 0 would loop 256 times and
;; never stop a ball, and more than 255 does not fit in B.
.ifeq PHYS_FRICTION
    .error 1    ; PHYS_FRICTION must be 1..255
.endif
.ifgt PHYS_FRICTION-255
    .error 1    ; PHYS_FRICTION must be 1..255
.endif

.area _DATA

spf_major: .dw 0
spf_minor: .dw 0
spf_ax:    .dw 0
spf_ay:    .dw 0

.area _CODE

;;-----------------------------------------------------------------
;;
;; sys_physics_init
;;
;;  Input:
;;  Output:
;;  Modified: None
;;
sys_physics_init::
    ret

;;-----------------------------------------------------------------
;;
;; sys_physics_update
;;
;;  Integrates every movable entity.
;;  Input:
;;  Output:
;;  Modified: AF, BC, DE, HL, IX
;;
sys_physics_update::
    ld ix, #entities
    ld b, #c_cmp_movable
    ld hl, #sys_physics_update_one
    jp sys_array_execute_each_ix_matching

;;-----------------------------------------------------------------
;;
;; sys_physics_update_one
;;
;;  Still balls return at once: friction, integration and cushion checks
;;  do nothing for them. A moving ball is marked CF_PENDING for collision.
;;  Input: IX = entity
;;  Output:
;;  Modified: AF, BC, DE, HL
;;
sys_physics_update_one:
    IsStill ix
    ret z
    set CF_PENDING_BIT, e_cflags(ix)
    call sys_physics_friction
    ld e, e_vx(ix)
    ld d, e_vx+1(ix)
    ld l, e_x(ix)
    ld h, e_x+1(ix)
    add hl, de
    ld e_x(ix), l
    ld e_x+1(ix), h
    ld a, h
    cp #TABLE_X_MAX+1
    jr c, spuo_x_ok
    bit 7, e_vx+1(ix)
    jr nz, spuo_x_left
    ld e_x+1(ix), #TABLE_X_MAX
    ld e_x(ix), #0
    call sys_physics_neg_vx
    jr spuo_y
spuo_x_left:
    ld e_x+1(ix), #0
    ld e_x(ix), #0
    call sys_physics_neg_vx
    jr spuo_y
spuo_x_ok:
    bit 7, e_vx+1(ix)
    jr z, spuo_y
    ld a, e_x+1(ix)
    or a
    jr nz, spuo_y
    call sys_physics_neg_vx

spuo_y:
    ld e, e_vy(ix)
    ld d, e_vy+1(ix)
    ld l, e_y(ix)
    ld h, e_y+1(ix)
    add hl, de
    ld e_y(ix), l
    ld e_y+1(ix), h
    ld a, h
    cp #TABLE_Y_MAX+1
    jr c, spuo_y_lo
    bit 7, e_vy+1(ix)
    jr nz, spuo_y_top
    ld e_y+1(ix), #TABLE_Y_MAX
    ld e_y(ix), #0
    jp sys_physics_neg_vy
spuo_y_top:
    ld e_y+1(ix), #TABLE_Y_PX
    ld e_y(ix), #0
    jp sys_physics_neg_vy
spuo_y_lo:
    bit 7, e_vy+1(ix)
    ret z
    ld a, e_y+1(ix)
    cp #TABLE_Y_PX
    ret nc
    ld e_y+1(ix), #TABLE_Y_PX
    ld e_y(ix), #0
    jp sys_physics_neg_vy

;;-----------------------------------------------------------------
;;
;; sys_physics_friction
;;
;;  Slows the ball by PHYS_FRICTION along its direction of travel, so the
;;  path stays straight while it slows down. (Friction per axis used to
;;  stop the smaller component first and bend every diagonal roll.)
;;  The dominant axis loses PHYS_FRICTION; the other loses
;;  PHYS_FRICTION * minor/major, where minor/major is an 8-bit fraction and
;;  the sub-LSB remainder is carried in e_facc from frame to frame.
;;  Input: IX = moving entity
;;  Output: e_vx, e_vy, e_facc updated
;;  Modified: AF, BC, DE, HL
;;
sys_physics_friction:
    ld l, e_vx(ix)
    ld h, e_vx+1(ix)
    call spf_abs
    ld (spf_ax), hl
    ld l, e_vy(ix)
    ld h, e_vy+1(ix)
    call spf_abs
    ld (spf_ay), hl
    ld de, (spf_ax)
    or a
    sbc hl, de
    jr c, spf_x_major
    jr z, spf_x_major
    ld hl, (spf_ay)
    ld de, (spf_ax)
    call spf_reduce
    ld (spf_ay), hl
    ld (spf_ax), de
    jr spf_store
spf_x_major:
    ld hl, (spf_ax)
    ld de, (spf_ay)
    call spf_reduce
    ld (spf_ax), hl
    ld (spf_ay), de
spf_store:
    ld hl, (spf_ax)
    bit 7, e_vx+1(ix)
    call nz, sys_physics_neg_hl
    ld e_vx(ix), l
    ld e_vx+1(ix), h
    ld hl, (spf_ay)
    bit 7, e_vy+1(ix)
    call nz, sys_physics_neg_hl
    ld e_vy(ix), l
    ld e_vy+1(ix), h
    ret

;; HL = |HL|
spf_abs:
    bit 7, h
    ret z
    jp sys_physics_neg_hl

;; Input: HL = major magnitude (> 0), DE = minor magnitude (<= major)
;; Output: HL = major - F (floored at 0), DE = minor - F*minor/major
;;         (0 when the major axis stops)
spf_reduce:
    ld (spf_major), hl
    ld (spf_minor), de
    or a
    sbc hl, de
    jr nz, spf_divide
    ld hl, #256*PHYS_FRICTION
    jr spf_share
spf_divide:
    ;; C = floor(minor * 256 / major), restoring division, 8 bits
    ld hl, (spf_minor)
    ld de, (spf_major)
    ld bc, #0x0800
spf_div_loop:
    add hl, hl
    or a
    sbc hl, de
    jr nc, spf_div_one
    add hl, de
    sla c
    jr spf_div_next
spf_div_one:
    scf
    rl c
spf_div_next:
    djnz spf_div_loop
    ld e, c
    ld d, #0
    ld hl, #0
    ld b, #PHYS_FRICTION
spf_mul:
    add hl, de
    djnz spf_mul
spf_share:
    ;; HL = share in 1/256 LSB; add the carried remainder
    ld e, e_facc(ix)
    ld d, #0
    add hl, de
    ld e_facc(ix), l
    ld e, h
    ld d, #0
    ld hl, (spf_minor)
    or a
    sbc hl, de
    jr nc, spf_minor_ok
    ld hl, #0
spf_minor_ok:
    ld (spf_minor), hl
    ld hl, (spf_major)
    ld de, #PHYS_FRICTION
    or a
    sbc hl, de
    jr c, spf_stop
    jr z, spf_stop
    ld de, (spf_minor)
    ret
spf_stop:
    ld hl, #0
    ld de, #0
    ld e_facc(ix), #0
    ret

sys_physics_neg_vx:
    ld l, e_vx(ix)
    ld h, e_vx+1(ix)
    call sys_physics_neg_hl
    ld e_vx(ix), l
    ld e_vx+1(ix), h
    ret

sys_physics_neg_vy:
    ld l, e_vy(ix)
    ld h, e_vy+1(ix)
    call sys_physics_neg_hl
    ld e_vy(ix), l
    ld e_vy+1(ix), h
    ret

sys_physics_neg_hl:
    ld a, l
    cpl
    ld l, a
    ld a, h
    cpl
    ld h, a
    inc hl
    ret
