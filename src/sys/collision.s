;; Ball-ball AABB, modelled on model01/src/sys/collision.s.
.module collision_system

.include "sys/array.h.s"
.include "globals.inc"
.include "sys/collision.h.s"
.include "sys/entity.h.s"
.include "sys/component.inc"

;; Separation nudges stop at the cushion. An unclamped dec at x=0 gave 255,
;; which physics read as past the right cushion and teleported the ball.
;; A nudged ball is marked CF_PENDING so the next pass rechecks all its pairs.
.macro NudgeDec _coord, _flags, _min, ?skip
    ld a, _coord
    cp #_min+1
    jr c, skip
    dec _coord
    set CF_PENDING_BIT, _flags
skip:
.endm

.macro NudgeInc _coord, _flags, _max, ?skip
    ld a, _coord
    cp #_max
    jr nc, skip
    inc _coord
    set CF_PENDING_BIT, _flags
skip:
.endm

.area _DATA

collision_handler: .dw sys_collision_balls_bounce

.area _CODE

;;-----------------------------------------------------------------
;;
;; sys_collision_init
;;
;;  Input:
;;  Output:
;;  Modified: HL
;;
sys_collision_init::
    ld hl, #sys_collision_balls_bounce
    ld (collision_handler), hl
    ret

;;-----------------------------------------------------------------
;;
;; sys_collision_set_handler
;;
;;  Input: HL = handler (IX=collider, IY=collisionable), or 0 for bounce
;;  Output:
;;  Modified: AF, HL
;;
sys_collision_set_handler::
    ld a, h
    or l
    jr nz, scsh_store
    ld hl, #sys_collision_balls_bounce
scsh_store:
    ld (collision_handler), hl
    ret

;;-----------------------------------------------------------------
;;
;; sys_collision_on_hit
;;
;;  Input: IX = collider, IY = collisionable
;;  Output: IX and IY preserved
;;  Modified: AF, BC, DE, HL (plus handler)
;;
sys_collision_on_hit::
    push ix
    push iy
    ld hl, #scoh_return
    push hl
    ld hl, (collision_handler)
    jp (hl)
scoh_return:
    pop iy
    pop ix
    ret

;;-----------------------------------------------------------------
;;
;; sys_collision_check_pair
;;
;;  AABB using integer pixels (high byte of 8.8) and ball size constants.
;;  Input:  IX, IY = entities
;;  Output: Z if no hit (returns via ret nc); calls handler on hit
;;  Modified: AF, B
;;
sys_collision_check_pair::
    ld a, e_x+1(ix)
    add a, #BALL_WIDTH_PX
    ld b, a
    ld a, e_x+1(iy)
    cp b
    ret nc
    ld a, e_x+1(iy)
    add a, #BALL_WIDTH_PX
    ld b, a
    ld a, e_x+1(ix)
    cp b
    ret nc
    ld a, e_y+1(ix)
    add a, #BALL_HEIGHT_PX
    ld b, a
    ld a, e_y+1(iy)
    cp b
    ret nc
    ld a, e_y+1(iy)
    add a, #BALL_HEIGHT_PX
    ld b, a
    ld a, e_y+1(ix)
    cp b
    ret nc
    jp sys_collision_on_hit

;;-----------------------------------------------------------------
;;
;; sys_collision_check_one_collider
;;
;;  Checks IX against every later slot (earlier slots already checked
;;  their pair with IX). An ACTIVE collider checks all of them; an idle one
;;  only the ACTIVE ones.
;;  Input: IX = collider, A = its slot index
;;  Output:
;;  Modified: AF, BC, DE, HL, IY
;;
sys_collision_check_one_collider::
    ld iy, #entities
    ld c, a
    ld a, a_count(iy)
    sub c
    dec a
    ret z
    ld b, a
    push ix
    pop iy
    ld de, #sizeof_e
    add iy, de
    bit 0, e_cflags(ix)
    jr nz, sccoc_all
sccoc_active_only:
    push bc
    ld a, x_cmps(iy)
    and #c_cmp_collisionable
    jr z, sccoc_active_next
    bit 0, e_cflags(iy)
    call nz, sys_collision_check_pair
sccoc_active_next:
    ld de, #sizeof_e
    add iy, de
    pop bc
    djnz sccoc_active_only
    ret
sccoc_all:
    push bc
    ld a, x_cmps(iy)
    and #c_cmp_collisionable
    call nz, sys_collision_check_pair
    ld de, #sizeof_e
    add iy, de
    pop bc
    djnz sccoc_all
    ret

;;-----------------------------------------------------------------
;;
;; sys_collision_update
;;
;;  Checks each pair once (lower slot is the collider), but only pairs where
;;  at least one ball changed position since it was last checked (CF_ACTIVE).
;;  Pairs of unchanged balls cannot have a new overlap, and an old one was
;;  seen when it was made; the nudge moves at least one ball (both, unless
;;  one sits on the cushion) and marks it again. A table at rest costs one
;;  pass over the flags.
;;  Input:
;;  Output:
;;  Modified: AF, BC, DE, HL, IX, IY
;;
sys_collision_update::
    ld ix, #entities
    ld a, a_count(ix)
    or a
    ret z
    ld b, a
    ld de, #a_array
    add ix, de
    push ix
    push bc
    ld de, #sizeof_e
    ld c, #0
scu_mark:
    ld a, e_cflags(ix)
    and #CF_PENDING
    jr z, scu_idle
    ld e_cflags(ix), #CF_ACTIVE
    inc c
    jr scu_mark_next
scu_idle:
    ld e_cflags(ix), #0
scu_mark_next:
    add ix, de
    djnz scu_mark
    ld a, c
    pop bc
    pop ix
    or a
    ret z
    ld c, #0
scu_loop:
    push bc
    ld a, x_cmps(ix)
    and #c_cmp_collider
    ld a, c
    call nz, sys_collision_check_one_collider
    ld de, #sizeof_e
    add ix, de
    pop bc
    inc c
    djnz scu_loop
    ret

;; Equal-mass bounce: swap 8.8 velocities and nudge apart on the
;; axis with the smaller overlap so they do not stick.
sys_collision_balls_bounce:
    ld l, e_vx(ix)
    ld h, e_vx+1(ix)
    ld e, e_vx(iy)
    ld d, e_vx+1(iy)
    ld e_vx(ix), e
    ld e_vx+1(ix), d
    ld e_vx(iy), l
    ld e_vx+1(iy), h
    ld l, e_vy(ix)
    ld h, e_vy+1(ix)
    ld e, e_vy(iy)
    ld d, e_vy+1(iy)
    ld e_vy(ix), e
    ld e_vy+1(ix), d
    ld e_vy(iy), l
    ld e_vy+1(iy), h

    ;; Overlap per axis = size - |distance|, whichever side IY is on.
    ld a, e_x+1(ix)
    sub e_x+1(iy)
    jr nc, scbb_dx_pos
    neg
scbb_dx_pos:
    ld c, a
    ld a, #BALL_WIDTH_PX
    sub c
    ld c, a
    ld a, e_y+1(ix)
    sub e_y+1(iy)
    jr nc, scbb_dy_pos
    neg
scbb_dy_pos:
    ld b, a
    ld a, #BALL_HEIGHT_PX
    sub b
    cp c
    jr nc, scbb_sep_x
    ld a, e_y+1(ix)
    cp e_y+1(iy)
    jr c, scbb_ix_up
    NudgeInc e_y+1(ix), e_cflags(ix), TABLE_Y_MAX
    NudgeDec e_y+1(iy), e_cflags(iy), TABLE_Y_PX
    ret
scbb_ix_up:
    NudgeDec e_y+1(ix), e_cflags(ix), TABLE_Y_PX
    NudgeInc e_y+1(iy), e_cflags(iy), TABLE_Y_MAX
    ret
scbb_sep_x:
    ld a, e_x+1(ix)
    cp e_x+1(iy)
    jr c, scbb_ix_left
    NudgeInc e_x+1(ix), e_cflags(ix), TABLE_X_MAX
    NudgeDec e_x+1(iy), e_cflags(iy), 0
    ret
scbb_ix_left:
    NudgeDec e_x+1(ix), e_cflags(ix), 0
    NudgeInc e_x+1(iy), e_cflags(iy), TABLE_X_MAX
    ret
