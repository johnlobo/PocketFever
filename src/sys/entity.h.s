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
    .db 0           ;; e_pat_full -- computed once in sys_entity_create
    .db 0           ;; e_pat_l
    .db 0           ;; e_pat_r
    .dw 0           ;; e_old_ptr
.endm

;; e_pat_full/l/r and e_old_ptr are appended AFTER e_facc, not inserted
;; earlier -- tests/collision_test.py, physics_test.py, shot_test.py,
;; perf_test.py and aim_test.py all poke e_cflags at the FIXED byte offset
;; +13 from a slot's own Lua-side literal, not via this struct, so any field
;; inserted before e_cflags silently breaks every one of them. Grew
;; sizeof_e 15 -> 20; tests/amspirit.py's ENTITY_SIZE constant must match.
BeginStruct e
Field e, cmps, 1
Field e, x, 2
Field e, y, 2
Field e, vx, 2
Field e, vy, 2
Field e, old_x, 1        ;; unused since e_old_ptr replaced it for erase (V.019) --
Field e, old_y, 1        ;; kept only as padding, see the offset-+13 warning above
Field e, id, 1
Field e, color, 1
Field e, cflags, 1
Field e, facc, 1
Field e, pat_full, 1
Field e, pat_l, 1
Field e, pat_r, 1
Field e, old_ptr, 2
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

;; RETURNS (ret z) from the CALLER when this ball needs no erase/draw this
;; frame: no velocity AND e_cflags clear -- neither physics nor a collision
;; separation nudge has touched its position since the last pass, so
;; e_old_x/e_old_y already equal the current x/y and erase(old)+draw(current)
;; would just redraw it exactly where it already sits. Same "settled" test
;; game/aim.s's gaim_all_still uses, and for the same reason: a nudge moves a
;; resting ball WITHOUT ever setting velocity, so IsStill alone would miss it
;; and skip a ball that actually needs redrawing at its new position.
.macro SkipIfSettled _r, ?not_settled
    IsStill _r
    jr nz, not_settled
    ld a, e_cflags(_r)
    or a
    ret z
not_settled:
.endm
