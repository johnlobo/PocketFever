;; Draws the 160x132 felt and seeds the 9-ball rack + cue.
.module game_table

.include "cpctelera.h.s"
.include "globals.inc"
.include "sys/entity.h.s"

.area _DATA

;; Cue at kitchen (x=36). Diamond rack, apex toward the cue, 9 in the centre.
ball_cue: DefineBall 0, 36, 63, 15
ball_1:   DefineBall 1, 108, 63, 8
ball_2:   DefineBall 2, 112, 57, 2
ball_3:   DefineBall 3, 112, 69, 4
ball_4:   DefineBall 4, 116, 51, 3
ball_9:   DefineBall 9, 116, 63, 5
ball_5:   DefineBall 5, 116, 75, 6
ball_6:   DefineBall 6, 120, 57, 11
ball_7:   DefineBall 7, 120, 69, 13
ball_8:   DefineBall 8, 124, 63, 1

ball_templates:
    .dw ball_cue, ball_1, ball_2, ball_3, ball_4
    .dw ball_9, ball_5, ball_6, ball_7, ball_8

.area _CODE

;;-----------------------------------------------------------------
;;
;; game_table_fill_felt
;;
;;  Fills 160x132 with FELT_PEN. Two 40-byte boxes (drawSolidBox width max 64).
;;  Input:
;;  Output:
;;  Modified: AF, BC, DE, HL
;;
game_table_fill_felt:
    ld h, #FELT_PEN
    ld l, #FELT_PEN
    call sys_render_pen_solid_byte
    ld a, l
    ld (gtff_pattern), a
    ld c, #0
    ld b, #TABLE_Y_PX
    ld de, #0xC000
    call cpct_getScreenPtr_asm
    ex de, hl
    ld c, #40
    ld b, #TABLE_HEIGHT_PX
gtff_pattern = . + 1
    ld a, #0
    call cpct_drawSolidBox_asm
    ld c, #40
    ld b, #TABLE_Y_PX
    ld de, #0xC000
    call cpct_getScreenPtr_asm
    ex de, hl
    ld a, (gtff_pattern)
    ld c, #40
    ld b, #TABLE_HEIGHT_PX
    jp cpct_drawSolidBox_asm

;;-----------------------------------------------------------------
;;
;; game_table_init
;;
;;  Paints the felt, creates the 10 balls, draws them.
;;  Input:
;;  Output:
;;  Modified: AF, BC, DE, HL, IX
;;
game_table_init::
    call game_table_fill_felt
    call sys_entity_init
    ld hl, #ball_templates
    ld b, #MAX_ENTITIES
gti_loop:
    push bc
    push hl
    ld e, (hl)
    inc hl
    ld d, (hl)
    ex de, hl
    call sys_entity_create
    pop hl
    inc hl
    inc hl
    pop bc
    djnz gti_loop
    jp sys_entity_draw_all
