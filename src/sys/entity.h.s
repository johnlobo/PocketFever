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
EndStruct e
