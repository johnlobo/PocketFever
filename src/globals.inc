;; Central declaration registry. One entry per external symbol.
.include "config.h.s"

;; CPCtelera
.globl cpct_disableFirmware_asm
.globl cpct_setInterruptHandler_asm
.globl cpct_scanKeyboard_if_asm
.globl cpct_waitVSYNC_asm
.globl cpct_waitVSYNCStart_asm
.globl cpct_setVideoMode_asm
.globl cpct_setPalette_asm
.globl cpct_drawSolidBox_asm
.globl cpct_getRandom_mxor_u8_asm
.globl cpct_setSeed_mxor_asm
.globl cpct_getScreenPtr_asm
.globl cpct_drawSprite_asm
.globl cpct_isKeyPressed_asm
.globl cpct_isAnyKeyPressed_asm
.globl cpct_drawSpriteMaskedAlignedTable_asm
.globl cpct_pens2pixelPatternPairM0_asm
.globl cpct_getScreenToSprite_asm
.globl _cpct_keyboardStatusBuffer

;; main.s
.globl transparency_table

;; generated assets
.globl _g_palette0
.globl _s_font_0
.globl _s_small_numbers_00

;; sys/util.s
.globl string_buffer
.globl sys_util_h_times_e
.globl sys_util_hl_div_c
.globl sys_util_BCD_GetEnd
.globl sys_util_BCD_Add
.globl sys_util_BCD_Compare
.globl sys_util_get_random_number
.globl sys_util_seed_random
.globl sys_util_delay
.globl sys_util_fadeOut
.globl sys_util_fadeIn
.globl sys_util_temblor
.globl sys_util_count_set_bits

;; sys/system.s
.globl nInterrupt
.globl sys_system_disable_firmware

;; sys/input.s
.globl sys_input_generic_update

;; sys/render.s
.globl sys_render_clear_front_buffer
.globl sys_render_draw_box
.globl sys_render_draw_box_xor
.globl sys_render_pen_solid_byte
.globl sys_render_drawSpriteMaskedAlignedColorizeM0_asm

;; sys/messages.s
.globl sys_messages_init
.globl sys_messages_show
.globl sys_messages_close

;; sys/array.s
.globl sys_array_init
.globl sys_array_create_element
.globl sys_array_create_reusable_element
.globl sys_array_get_element
.globl sys_array_remove_element
.globl sys_array_get_random_element
.globl sys_array_get_address_from_pointer
.globl sys_array_move_all_elements
.globl sys_array_execute_each
.globl sys_array_execute_each_ix_matching
.globl sys_array_execute_each_iy_matching

;; sys/entity.s
.globl entities
.globl sys_entity_init
.globl sys_entity_create
.globl sys_entity_draw_all

;; game/table.s
.globl game_table_init

;; sys/text.s
.globl aux_txt
.globl sys_text_init
.globl sys_text_str_length
.globl sys_text_str_copy
.globl sys_text_str_cmp
.globl sys_text_draw_char
.globl sys_text_draw_string
.globl sys_text_draw_small_char_number
.globl sys_text_draw_big_char_number
.globl _char_buffer
