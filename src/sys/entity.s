;; Fixed-capacity entity pool for table balls.
.module entity_system

.include "cpctelera.h.s"
.include "sys/array.h.s"
.include "sys/entity.h.s"
.include "globals.inc"

.area _DATA

entities::
DefineArrayStructure entity, MAX_ENTITIES, sizeof_e

;; Felt fill pattern (both mode-0 sub-pixels = FELT_PEN), computed once here
;; rather than read from game/table.s's own copy (gtff_pattern): sys/ must
;; not reference game/, and this is exactly the kind of project-constant
;; sys/entity.s's own ball-blit pattern cache (e_pat_full/l/r,
;; sys_entity_create) needs at ball-creation time, which runs from here
;; (game_table_init calls sys_entity_init before any sys_entity_create).
FELT_PATTERN:: .db 0

.area _CODE

;;-----------------------------------------------------------------
;;
;; sys_entity_init
;;
;;  Initializes the entity pool and computes FELT_PATTERN once.
;;  Input:
;;  Output:
;;  Modified: AF, HL, IX
;;
sys_entity_init::
    push ix
    ld h, #FELT_PEN
    ld l, #FELT_PEN
    call sys_render_pen_solid_byte
    ld a, l
    ld (FELT_PATTERN), a
    pop ix
    ld ix, #entities
    jp sys_array_init

;;-----------------------------------------------------------------
;;
;; sys_entity_create
;;
;;  Allocates or recycles a slot and copies HL's template into it.
;;  Input: HL = entity template
;;  Output: IX = entity, carry clear on success; carry set if the pool is full
;;  Modified: AF, BC, DE, HL, IX
;;
sys_entity_create::
    ld ix, #entities
    call sys_array_create_reusable_element
    ret c
    ld__ix_hl

    ;; Precompute this ball's blit patterns once, here, rather than every
    ;; erase/draw call (sys_render_pen_solid_byte -> cpct_pens2pixelPattern
    ;; PairM0_asm is a real cost paid twice per ball per frame today; a ball's
    ;; colour never changes after creation, so this only ever needs doing
    ;; once). Mode 0 packs 2 pixels/byte: LEFT sub-pixel's bits are 0xAA,
    ;; RIGHT sub-pixel's are 0x55 (standard CPC mode-0 bit interleave, used
    ;; here rather than re-derived: bit7/5/3/1 = pixel 0, bit6/4/2/0 = pixel
    ;; 1). e_pat_l/r are for the rounded-corner bytes tools/gen_ball_blit.py
    ;; generates: felt on one sub-pixel, ball ink on the other.
    ld h, e_color(ix)
    ld l, h
    call sys_render_pen_solid_byte      ;; L = this ball's solid-colour byte
    ld e_pat_full(ix), l

    ld a, l
    and #0x55
    ld b, a                              ;; B = ball ink, right sub-pixel only
    ld a, (FELT_PATTERN)
    and #0xAA
    or b
    ld e_pat_l(ix), a                    ;; felt left, ball right

    ld a, l
    and #0xAA
    ld b, a                              ;; B = ball ink, left sub-pixel only
    ld a, (FELT_PATTERN)
    and #0x55
    or b
    ld e_pat_r(ix), a                    ;; ball left, felt right

    or a
    ret

;;-----------------------------------------------------------------
;;
;; sys_entity_erase_all
;;
;;  Restores felt under every live ball at its last drawn pixel.
;;  Input:
;;  Output:
;;  Modified: AF, BC, DE, HL, IX
;;
;;  Direct IX-stepping loop, not sys_array_execute_each: that helper stores
;;  the routine pointer and component size to memory once, then per element
;;  pushes a manual return address and `jp (hl)`s into the routine instead
;;  of a plain `call` -- generic, but paid 10 times a frame for a fixed,
;;  known-at-build-time element size. `call`/`ret` do the exact same job
;;  with less indirection.
sys_entity_erase_all::
    ld ix, #entities
    ld a, a_count(ix)
    or a
    ret z
    ld b, a
    push ix
    pop hl
    ld de, #a_array
    add hl, de
    push hl
    pop ix
seea_loop:
    push bc
    call sys_entity_erase_one
    pop bc
    ld de, #sizeof_e
    add ix, de
    djnz seea_loop
    ret

;;-----------------------------------------------------------------
;;
;; sys_entity_draw_all
;;
;;  Draws every live entity as a solid BALL_WIDTH_PXxBALL_HEIGHT_PX mode-0 box.
;;  Input:
;;  Output:
;;  Modified: AF, BC, DE, HL, IX
;;
;;  Same direct-loop rationale as sys_entity_erase_all above.
sys_entity_draw_all::
    ld ix, #entities
    ld a, a_count(ix)
    or a
    ret z
    ld b, a
    push ix
    pop hl
    ld de, #a_array
    add hl, de
    push hl
    pop ix
seda_loop:
    push bc
    call sys_entity_draw_one
    pop bc
    ld de, #sizeof_e
    add ix, de
    djnz seda_loop
    ret

;;-----------------------------------------------------------------
;;
;; sys_entity_screen_ptr
;;
;;  Computes the video address of (e_x+1(ix), e_y+1(ix))'s top-left byte via
;;  felt_row_addr (tools/gen_row_table.py) instead of cpct_getScreenPtr_asm's
;;  runtime divide/shift chain -- the row lookup is a single table read.
;;  Input: IX = entity
;;  Output: DE = video address
;;  Modified: AF, DE, HL
;;
sys_entity_screen_ptr:
    ld a, e_y+1(ix)
    sub #TABLE_Y_PX
    add a, a                    ;; row index * 2 (word table)
    ld l, a
    ld h, #0
    ld de, #felt_row_addr
    add hl, de
    ld e, (hl)
    inc hl
    ld d, (hl)                  ;; DE = start of this row (x_byte=0)
    ld a, e_x+1(ix)
    srl a                       ;; x_byte = x_px / 2
    add a, e
    ld e, a
    ret nc
    inc d
    ret

sys_entity_erase_one:
    ld a, e_cmps(ix)
    or a
    ret z
    SkipIfSettled ix
    ld l, e_old_ptr(ix)
    ld h, e_old_ptr+1(ix)       ;; HL = exactly where sys_entity_draw_one left
                                 ;; it last time drawn -- no recomputation
    ld a, (FELT_PATTERN)
    ld e, a
    jp sys_ball_blit_erase

sys_entity_draw_one:
    ld a, e_cmps(ix)
    or a
    ret z
    SkipIfSettled ix
    call sys_entity_screen_ptr
    ld e_old_ptr(ix), e
    ld e_old_ptr+1(ix), d       ;; remembered for the NEXT frame's erase
    ex de, hl                   ;; HL = pointer (sys_ball_blit_draw's input)
    ld b, e_pat_full(ix)
    ld c, e_pat_l(ix)
    ld d, e_pat_r(ix)
    jp sys_ball_blit_draw
