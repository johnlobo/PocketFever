;; 8.8 integrator for table balls. Not model01's platformer physics.
.module physics_system

.include "cpctelera.h.s"
.include "sys/array.h.s"
.include "sys/entity.h.s"
.include "sys/component.inc"
.include "globals.inc"
.include "sys/physics.h.s"

PHYS_FRICTION = 0x0006

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
    ld l, e_vx(ix)
    ld h, e_vx+1(ix)
    call sys_physics_friction
    ld e_vx(ix), l
    ld e_vx+1(ix), h
    ld e, l
    ld d, h
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
    ld l, e_vy(ix)
    ld h, e_vy+1(ix)
    call sys_physics_friction
    ld e_vy(ix), l
    ld e_vy+1(ix), h
    ld e, l
    ld d, h
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

;; HL = velocity 8.8. Pulls toward 0 by PHYS_FRICTION.
sys_physics_friction:
    ld a, h
    or l
    ret z
    bit 7, h
    jr nz, spf_neg
    ld de, #PHYS_FRICTION
    or a
    sbc hl, de
    ret nc
    ld hl, #0
    ret
spf_neg:
    ld de, #PHYS_FRICTION
    add hl, de
    ret nc
    bit 7, h
    ret nz
    ld hl, #0
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
