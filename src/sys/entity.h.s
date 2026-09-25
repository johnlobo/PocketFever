;; Ball entity pool. Positions and velocities are 8.8 (low=frac, high=pixel).
.module entity_system

.include "globals.inc"
.include "sys/component.inc"
.include "sys/struct.inc"

BALL_CMPS = c_cmp_render | c_cmp_movable | c_cmp_collider | c_cmp_collisionable

.macro DefineBall _id, _x, _y, _pen
    .db BALL_CMPS
    .dw (_x)*256
    .dw (_y)*256
    .dw 0
    .dw 0
    .db _x
    .db _y
    .db _id
    .db _pen
    .db CF_PENDING
    .db 0
.endm

BeginStruct e
Field e, cmps, 1
Field e, x, 2
Field e, y, 2
Field e, vx, 2
Field e, vy, 2
Field e, old_x, 1
Field e, old_y, 1
Field e, id, 1
Field e, color, 1
Field e, cflags, 1
Field e, facc, 1
EndStruct e

;; e_cflags. Every change of a ball's position sets CF_PENDING (physics when
;; it integrates, collision separation, anything that places a ball). At the
;; start of each collision pass PENDING becomes CF_ACTIVE, a snapshot that
;; stays fixed for the pass; a pair is checked only if one ball is ACTIVE.
CF_ACTIVE        = 0x01
CF_PENDING       = 0x02
CF_PENDING_BIT   = 1

;; Z when the ball has no velocity at all. Clobbers A.
.macro IsStill _r
    ld a, e_vx(_r)
    or e_vx+1(_r)
    or e_vy(_r)
    or e_vy+1(_r)
.endm
