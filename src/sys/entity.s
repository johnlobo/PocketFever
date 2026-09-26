;; Fixed-capacity entity pool for table balls.
.module entity_system

.include "cpctelera.h.s"
.include "sys/array.h.s"
.include "sys/entity.h.s"
.include "globals.inc"

.area _DATA

entities::
DefineArrayStructure entity, MAX_ENTITIES, sizeof_e

.area _CODE

;;-----------------------------------------------------------------
;;
;; sys_entity_init
;;
;;  Initializes the entity pool.
;;  Input:
;;  Output:
;;  Modified: AF, HL, IX
;;
sys_entity_init::
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
sys_entity_erase_all::
    ld ix, #entities
    ld hl, #sys_entity_erase_one
    jp sys_array_execute_each

;;-----------------------------------------------------------------
;;
;; sys_entity_draw_all
;;
;;  Draws every live entity as a solid 4x6 mode-0 box.
;;  Input:
;;  Output:
;;  Modified: AF, BC, DE, HL, IX
;;
sys_entity_draw_all::
    ld ix, #entities
    ld hl, #sys_entity_draw_one
    jp sys_array_execute_each

;;-----------------------------------------------------------------
;;
;; sys_entity_blit_box
;;
;;  Input: IX = entity, A = pattern, C = x px, B = y px
;;  Output:
;;  Modified: AF, BC, DE, HL
;;
sys_entity_blit_box:
    push af
    ld a, c
    srl a
    ld c, a
    ld de, #0xC000
    call cpct_getScreenPtr_asm
    ex de, hl
    ld c, #BALL_WIDTH_BYTES
    ld b, #BALL_HEIGHT_PX
    pop af
    jp cpct_drawSolidBox_asm

sys_entity_erase_one:
    ld a, e_cmps(ix)
    or a
    ret z
    SkipIfSettled ix
    ld h, #FELT_PEN
    ld l, #FELT_PEN
    call sys_render_pen_solid_byte
    ld a, l
    ld c, e_old_x(ix)
    ld b, e_old_y(ix)
    jp sys_entity_blit_box

sys_entity_draw_one:
    ld a, e_cmps(ix)
    or a
    ret z
    SkipIfSettled ix
    ld h, e_color(ix)
    ld l, h
    call sys_render_pen_solid_byte
    ld a, l
    ld c, e_x+1(ix)
    ld b, e_y+1(ix)
    ld e_old_x(ix), c
    ld e_old_y(ix), b
    jp sys_entity_blit_box
