;; XOR trajectory guide for the cue ball. Cursor left/right rotate the aim
;; direction (one of shot_table.s's 64 steps); a dashed line from the cue
;; shows it. Shown only while every ball is at rest, since XOR draw/erase is
;; only lossless when nothing else redraws those pixels in between: the
;; ordinary ball erase/draw (sys/entity.s) is a direct felt overwrite, not
;; XOR, so it must never touch a dash pixel. Dash placement guarantees that
;; (see config.h.s and tools/aim_model.py); this module only has to
;; guarantee timing: never leave a dash showing across a frame where any
;; ball might move under it.
.module game_aim

.include "cpctelera.h.s"
.include "globals.inc"
.include "sys/array.h.s"
.include "sys/entity.h.s"
.include "sys/component.inc"
.include "game/aim.h.s"

.area _DATA

gaim_index::      .db AIM_DEFAULT_INDEX  ;; public: game/shot.s reads this to fire
gaim_shown::      .db 0
gaim_turn_tick:   .db 0
gaim_hold_frames: .db 0                 ;; frames a cursor key has been held continuously
gaim_turn_dir:    .db 0                 ;; 0 none, 1 left, 2 right (last frame's), for ramp reset on reversal
gaim_last_index:: .db 0
gaim_last_cx::    .db 0                  ;; cue slot-0 top-left x/y when last (re)drawn
gaim_last_cy::    .db 0
gaim_pattern:     .db 0                  ;; precomputed felt_byte XOR aim_pen_byte

;; gaim_draw_line's own working state (module-private).
gdl_dx:    .dw 0                 ;; direction vector, 8.8, from shot_directions
gdl_dy:    .dw 0
gdl_accx:  .dw 0                 ;; running dx*AIM_STEP_MULT*i / dy*..., signed 8.8
gdl_accy:  .dw 0
gdl_cx:    .db 0                 ;; cue ball CENTRE, pixels
gdl_cy:    .db 0
gdl_count: .db 0                 ;; dashes left to place

.area _CODE

;;-----------------------------------------------------------------
;;
;; game_aim_init
;;
;;  Precomputes the byte that, XORed onto felt, displays as AIM_PEN (both
;;  are compile-time pens, but the pixel-format conversion table is a
;;  runtime lookup, so this is done once at boot rather than hand-decoding
;;  a constant). Call once before the main loop.
;;  Input:
;;  Output:
;;  Modified: AF, BC, DE, HL
;;
game_aim_init::
    ld h, #FELT_PEN
    ld l, h
    call sys_render_pen_solid_byte
    ld a, l
    push af                     ;; stash the felt byte on the stack: B/C are
                                ;; among sys_render_pen_solid_byte's own
                                ;; clobbers, so a register can't survive it
    ld h, #AIM_PEN
    ld l, h
    call sys_render_pen_solid_byte
    ld a, l
    pop bc                      ;; B = felt byte back (push af pushed A high, F low)
    xor b
    ld (gaim_pattern), a
    ret

;;-----------------------------------------------------------------
;;
;; game_aim_update
;;
;;  Input:
;;  Output:
;;  Modified: AF, BC, DE, HL, IX, IY
;;
game_aim_update::
    call gaim_all_still         ;; Z = all still, NZ = something moving
    jr nz, gaim_moving
    call gaim_read_turn_keys
    ld ix, #entities+a_array
    ld a, e_x+1(ix)
    ld b, a                     ;; B = current cue x
    ld a, e_y+1(ix)
    ld c, a                     ;; C = current cue y
    ld a, (gaim_shown)
    or a
    jr z, gaim_draw_new         ;; nothing shown yet: just draw
    ld a, (gaim_last_index)
    ld hl, #gaim_index
    cp (hl)
    jr nz, gaim_move
    ld a, (gaim_last_cx)
    cp b
    jr nz, gaim_move
    ld a, (gaim_last_cy)
    cp c
    ret z                       ;; unchanged since last frame: leave it alone
gaim_move:
    push bc                     ;; B,C = current cue x/y; gaim_erase_last
    call gaim_erase_last        ;; overwrites B,C with the OLD (last-drawn)
    pop bc                      ;; position while erasing, so save/restore ours
gaim_draw_new:
    push bc
    ld a, (gaim_index)
    ld d, a
    pop bc
    push bc                     ;; gaim_draw_line clobbers B,C (its own dash
    call gaim_draw_line         ;; loop state), so the cue x/y needed AFTER it
    pop bc                      ;; returns must survive the call on the stack
    ld a, (gaim_index)
    ld (gaim_last_index), a
    ld a, b
    ld (gaim_last_cx), a
    ld a, c
    ld (gaim_last_cy), a
    ld a, #1
    ld (gaim_shown), a
    ret

gaim_moving:
    ;; A ball is moving: game_shot_update (which can set the cue's velocity)
    ;; always runs before this in the main loop, so if a line was up, nothing
    ;; has actually moved on screen yet this frame -- erasing it now with its
    ;; stored geometry is exact.
    ld a, (gaim_shown)
    or a
    ret z
    call gaim_erase_last
    xor a
    ld (gaim_shown), a
    ret

;;  Redraws (= erases, XOR is its own inverse) the line at its last stored
;;  index/position. Used both to erase before a move and to erase when the
;;  table starts moving.
;;  Modified: AF, BC, DE, HL, IX, IY
gaim_erase_last:
    ld a, (gaim_last_index)
    ld d, a
    ld a, (gaim_last_cx)
    ld b, a
    ld a, (gaim_last_cy)
    ld c, a
    jp gaim_draw_line

;;  Z if every ball is still (no velocity), NZ if any is moving.
;;  Input:
;;  Output: Z/NZ as above
;;  Modified: AF, B, DE, IX
gaim_all_still:
    ld ix, #entities+a_array
    ld b, #MAX_ENTITIES
gaim_still_loop:
    ld a, e_cmps(ix)
    and #c_cmp_movable
    ;; Every current entity (all 10 balls) has c_cmp_movable, so this gate
    ;; excludes nothing today. NudgeInc/NudgeDec (sys/collision.s) act on
    ;; whatever check_pair hands them, gated only by c_cmp_collider /
    ;; c_cmp_collisionable -- a future non-movable-but-collidable entity
    ;; could be nudged and evade this loop entirely. Not reachable now;
    ;; worth remembering if such an entity is ever added.
    jr z, gaim_still_next
    ld a, e_cflags(ix)
    or a
    ret nz                       ;; CF_PENDING/CF_ACTIVE nonzero: this ball's
                                 ;; position was touched by physics or a
                                 ;; collision separation nudge as of the last
                                 ;; pass, even with v=0 -- a nudge moves a
                                 ;; resting ball WITHOUT ever setting velocity,
                                 ;; so IsStill alone misses it (found in review:
                                 ;; two balls settled in contact can keep
                                 ;; sliding apart 1px/frame forever with
                                 ;; velocity staying zero the whole time)
    IsStill ix
    ret nz
gaim_still_next:
    ld de, #sizeof_e
    add ix, de
    djnz gaim_still_loop
    xor a
    ret

;;  Reads cursor left/right, steps gaim_index by 1 every N held frames, N
;;  staged down (AIM_TURN_T0..T3) as the key stays held -- precise single
;;  steps at first, fast spin if held (tools/turn_model.py). If both are
;;  held, left wins (checked first). Switching direction without releasing
;;  restarts the ramp (gaim_turn_dir), since that's a fresh adjustment, not
;;  a continuation of the spin that was building up.
;;  Input:
;;  Output:
;;  Modified: AF, BC, HL
gaim_read_turn_keys:
    ld hl, #Key_CursorLeft
    call cpct_isKeyPressed_asm
    jr nz, gaim_turn_want_left
    ld hl, #Key_CursorRight
    call cpct_isKeyPressed_asm
    jr nz, gaim_turn_want_right
    xor a
    ld (gaim_turn_tick), a
    ld (gaim_hold_frames), a
    ld (gaim_turn_dir), a
    ret
gaim_turn_want_left:
    ld a, #1
    call gaim_turn_note_dir
    call gaim_turn_tick_or_return
    ret nc
    ld a, (gaim_index)
    dec a
    and #63
    ld (gaim_index), a
    ret
gaim_turn_want_right:
    ld a, #2
    call gaim_turn_note_dir
    call gaim_turn_tick_or_return
    ret nc
    ld a, (gaim_index)
    inc a
    and #63
    ld (gaim_index), a
    ret

;; Input: A = 1 (left) or 2 (right), the direction about to be processed
;; this frame. Resets the ramp if that differs from last frame's.
;; Modified: AF
gaim_turn_note_dir:
    ld b, a
    ld a, (gaim_turn_dir)
    cp b
    ld a, b
    ld (gaim_turn_dir), a
    ret z
    xor a
    ld (gaim_turn_tick), a
    ld (gaim_hold_frames), a
    ret

;; Advances the hold counter (saturating so a very long hold can't wrap) and
;; the throttle tick against the CURRENT hold length's throttle. Carry SET =
;; time to step (caller acts on it), carry CLEAR = not yet (caller's `ret nc`
;; bails without touching the index).
;; Modified: AF, BC, HL
gaim_turn_tick_or_return:
    ld hl, #gaim_hold_frames
    ld a, (hl)
    cp #AIM_TURN_H3
    jr nc, gttor_hold_capped
    inc (hl)
gttor_hold_capped:
    ld a, (hl)
    call gaim_throttle_for
    ld b, a
    ld hl, #gaim_turn_tick
    inc (hl)
    ld a, (hl)
    cp b
    jr c, gttor_not_yet
    ld (hl), #0
    scf
    ret
gttor_not_yet:
    or a                    ;; clear carry (Z from this is unused)
    ret

;; Input: A = frames continuously held (0..AIM_TURN_H3)
;; Output: A = throttle (frames per step) for that hold length
;; Modified: AF
gaim_throttle_for:
    cp #AIM_TURN_H3
    jr c, gtf_below_h3
    ld a, #AIM_TURN_T3
    ret
gtf_below_h3:
    cp #AIM_TURN_H2
    jr c, gtf_below_h2
    ld a, #AIM_TURN_T2
    ret
gtf_below_h2:
    cp #AIM_TURN_H1
    jr c, gtf_below_h1
    ld a, #AIM_TURN_T1
    ret
gtf_below_h1:
    ld a, #AIM_TURN_T0
    ret

;;-----------------------------------------------------------------
;;
;; gaim_draw_line
;;
;;  XORs (or perfectly un-XORs, called again with the same inputs) the aim
;;  dashes. Pure function of its inputs and the current ball layout: the
;;  same index/cue position always produces the same dashes, which is what
;;  lets a later call with the same stored inputs erase exactly what an
;;  earlier call drew (see game_aim_update's timing invariant).
;;  Input: D = direction index (0-63), B = cue top-left x (px), C = cue top-left y (px)
;;  Output:
;;  Modified: AF, BC, DE, HL, IX, IY
;;
gaim_draw_line:
    ld a, d
    add a, a
    add a, a
    ld e, a
    ld d, #0
    ld hl, #shot_directions
    add hl, de
    ld e, (hl)
    inc hl
    ld d, (hl)
    ld (gdl_dx), de
    inc hl
    ld e, (hl)
    inc hl
    ld d, (hl)
    ld (gdl_dy), de

    ld a, b
    add a, #BALL_WIDTH_PX/2
    ld (gdl_cx), a
    ld a, c
    add a, #BALL_HEIGHT_PX/2
    ld (gdl_cy), a

    xor a
    ld (gdl_accx), a
    ld (gdl_accx+1), a
    ld (gdl_accy), a
    ld (gdl_accy+1), a
    ld a, #AIM_DASH_COUNT
    ld (gdl_count), a

gdl_step:
    ld hl, (gdl_accx)
    ld de, (gdl_dx)
    call gdl_scale_add
    ld (gdl_accx), hl
    ld hl, (gdl_accy)
    ld de, (gdl_dy)
    call gdl_scale_add
    ld (gdl_accy), hl

    ;; Candidate dash top-left, pixels. Signed high byte of a running 8.8
    ;; accumulator plus an unsigned pixel base is a plain 8-bit add; both
    ;; operands and the true (unwrapped) result stay within -128..255 for
    ;; every legal cue position and every direction at these constants
    ;; (checked by tools/aim_model.py's safety-margin report), so the
    ;; wrapped byte always compares the same way an unwrapped one would.
    ld a, (gdl_accx+1)
    ld hl, (gdl_cx)              ;; L = gdl_cx, H = gdl_cy (declared adjacent)
    add a, l
    sub #AIM_DASH_PX/2
    ld b, a                      ;; B = dash left x
    ld a, (gdl_accy+1)
    add a, h
    sub #AIM_DASH_PX/2
    ld c, a                      ;; C = dash top y

    call gdl_in_bounds
    ret z                        ;; out of the felt: stop the whole line here
    call gdl_overlaps_any_ball
    ret nz                       ;; would overlap a ball: stop the line here

    push bc
    ld a, (gaim_pattern)
    ld d, a                      ;; keep the pattern safe across getScreenPtr's clobbers
    ld a, c
    ld c, b
    srl c                        ;; mode 0: 2px/byte, byte column = x>>1
    ld b, a                      ;; B = Y px (cpct_getScreenPtr_asm: C=X bytes, B=Y px)
    ld a, d
    ld de, #0xC000
    push af
    call cpct_getScreenPtr_asm
    ex de, hl
    pop af
    ld c, #AIM_DASH_PX/2
    ;; sys_render_draw_box_xor always draws a full top row, a full bottom
    ;; row, and (input height - 1) "border" rows in between that XOR only
    ;; the left and right edge BYTES. At 1-byte width those two edges are
    ;; the SAME byte, so each middle row draws then immediately un-draws
    ;; itself -- a real gap in a 1-byte-wide box, confirmed on screen (a
    ;; visible row, a blank row, a visible row for height=AIM_DASH_PX=2).
    ;; height-1 keeps this to exactly top+bottom, both real, no middle.
    ld b, #AIM_DASH_PX-1
    call sys_render_draw_box_xor
    pop bc

    ld a, (gdl_count)
    dec a
    ld (gdl_count), a
    ret z
    jp gdl_step

;; HL += DE * AIM_STEP_MULT (16-bit two's complement; DE may be negative).
;; Preserves BC.
gdl_scale_add:
    push bc
    ld b, #AIM_STEP_MULT
gdl_scale_loop:
    add hl, de
    djnz gdl_scale_loop
    pop bc
    ret

;; Z if the (B,C) top-left pixel would put the AIM_DASH_PX square outside
;; the felt; NZ if it fits inside.
gdl_in_bounds:
    ld a, b
    cp #TABLE_WIDTH_PX-AIM_DASH_PX+1
    jr nc, gdl_ib_out
    ld a, c
    cp #TABLE_Y_PX
    jr c, gdl_ib_out
    cp #TABLE_Y_PX+TABLE_HEIGHT_PX-AIM_DASH_PX+1
    jr nc, gdl_ib_out
    or #1
    ret
gdl_ib_out:
    xor a
    ret

;; Z if the AIM_DASH_PXxAIM_DASH_PX box at (B,C) overlaps no ball's
;; BALL_WIDTH_PXxBALL_HEIGHT_PX box; NZ if it overlaps at least one (same
;; per-axis test as sys_collision_check_pair, generalized to two box sizes,
;; looped over the whole pool instead of one pair).
;; Input: B, C as above.
;; Output: Z = no overlap, NZ = overlap.
;; Modified: AF, DE, HL, IY
gdl_overlaps_any_ball:
    push bc
    ld iy, #entities+a_array
    ld d, #MAX_ENTITIES
gdl_ov_loop:
    ld a, x_cmps(iy)
    and #c_cmp_render
    jr z, gdl_ov_next
    ld a, b
    add a, #AIM_DASH_PX
    ld e, a
    ld a, e_x+1(iy)
    cp e
    jr nc, gdl_ov_next            ;; ball_x >= dash_right: no x overlap
    ld a, e_x+1(iy)
    add a, #BALL_WIDTH_PX
    cp b
    jr c, gdl_ov_next             ;; ball_right <= dash_left: no x overlap
    jr z, gdl_ov_next             ;; (cp only sets carry for strict <, need <=)
    ld a, c
    add a, #AIM_DASH_PX
    ld e, a
    ld a, e_y+1(iy)
    cp e
    jr nc, gdl_ov_next            ;; ball_y >= dash_bottom: no y overlap
    ld a, e_y+1(iy)
    add a, #BALL_HEIGHT_PX
    cp c
    jr c, gdl_ov_next             ;; ball_bottom <= dash_top: no y overlap
    jr z, gdl_ov_next             ;; (cp only sets carry for strict <, need <=)
    pop bc
    or #1
    ret
gdl_ov_next:
    push de                       ;; D is the loop counter; ADD IY,rr only takes
    ld de, #sizeof_e               ;; BC/DE/SP, so borrow DE and restore it after
    add iy, de
    pop de
    dec d
    jr nz, gdl_ov_loop
    pop bc
    xor a
    ret
