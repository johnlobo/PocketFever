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

;; Folds a signed 16-bit pixel position into [_lo, _lo+_span] by mirror
;; reflection (a triangle wave), the same "clamp position, negate that
;; axis's velocity" rule sys/physics.s applies at a cushion, re-expressed as
;; a pure function of position instead of a stepped simulation. Assumes (and
;; tools/aim_model.py's check_single_wrap_margin() proves for these
;; constants) that HL - _lo never lands outside (-_period, _period), so a
;; single conditional add folds a negative value into range and a single
;; conditional subtract-from-period mirrors anything past the far wall --
;; never more than one of each, never a general modulo loop.
;; Input: HL = signed pixel position
;; Output: A = folded pixel position, always in [_lo, _lo+_span]
;; Modified: AF, DE, HL
.macro ReflectAxis _lo, _span, _period, ?skip_wrap, ?past_mid, ?done
    ld de, #(-(_lo)) & 0xFFFF
    add hl, de                    ;; HL = m = position - _lo
    bit 7, h
    jr z, skip_wrap
    ld de, #(_period)
    add hl, de                    ;; m was negative: fold up by one period
skip_wrap:
    ld a, h
    or a
    jr nz, past_mid                ;; h!=0 => m > 255 >= _span: past the midpoint
    ld a, l
    cp #(_span)+1
    jr nc, past_mid                ;; m > _span: past the midpoint
    jr done                        ;; 0 <= m <= _span: keep m as-is
past_mid:
    ex de, hl
    ld hl, #(_period)
    or a
    sbc hl, de                     ;; HL = _period - m: mirror across the far wall
done:
    ld a, l
    add a, #(_lo)                  ;; final = _lo + folded m
.endm

;;-----------------------------------------------------------------
;;
;; gaim_draw_line
;;
;;  XORs (or perfectly un-XORs, called again with the same inputs) the aim
;;  dashes. Pure function of its inputs and the current ball layout: the
;;  same index/cue position always produces the same dashes, which is what
;;  lets a later call with the same stored inputs erase exactly what an
;;  earlier call drew (see game_aim_update's timing invariant). Since V.016
;;  the line no longer stops at the felt edge -- it bounces, each axis
;;  reflecting independently off its own legal range (ReflectAxis above) --
;;  so it always places exactly AIM_DASH_COUNT dashes.
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

    ;; Dash CENTER on each axis: sign-extend the accumulator's integer pixel
    ;; offset (its high byte) to 16 bits, add the cue center's pixel
    ;; coordinate (zero-extended), then fold the result into the ball
    ;; center's legal range with a mirror reflection -- the line bounces off
    ;; a cushion the way sys/physics.s bounces the real ball, instead of
    ;; stopping at the felt edge. tools/aim_model.py's reflect() is the
    ;; reference; its check_single_wrap_margin() proves the offset here
    ;; never needs more than the ONE wrap ReflectAxis performs.
    ld a, (gdl_accx+1)
    ld l, a
    ld h, #0
    bit 7, l
    jr z, gdl_x_ext_ok
    ld h, #0xFF
gdl_x_ext_ok:
    ld a, (gdl_cx)
    ld e, a
    ld d, #0
    add hl, de                   ;; HL = signed pixel position, x axis
    ReflectAxis AIM_X_LO, AIM_X_SPAN, AIM_X_PERIOD
    sub #AIM_DASH_PX/2
    ld b, a                      ;; B = dash left x

    ld a, (gdl_accy+1)
    ld l, a
    ld h, #0
    bit 7, l
    jr z, gdl_y_ext_ok
    ld h, #0xFF
gdl_y_ext_ok:
    ld a, (gdl_cy)
    ld e, a
    ld d, #0
    add hl, de                   ;; HL = signed pixel position, y axis
    ReflectAxis AIM_Y_LO, AIM_Y_SPAN, AIM_Y_PERIOD
    sub #AIM_DASH_PX/2
    ld c, a                      ;; C = dash top y

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

;; Ball-overlap stopping was removed: the line only ever shows while
;; gaim_all_still holds for every entity, and sys_entity_erase_one/
;; sys_entity_draw_one (sys/entity.s) now skip a settled ball entirely --
;; so nothing touches a resting ball's pixels while the line is up, and
;; drawing a dash over one is exactly as safe as drawing it over plain
;; felt (both are undone perfectly by the matching erase). The dash still
;; shows the XOR of whatever pattern happens to sit there, which looks
;; like the aim colour over felt but some XOR mix over a ball -- accepted,
;; not a bug: reversibility never depended on the colour underneath.
