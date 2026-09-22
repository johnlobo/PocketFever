;;-----------------------------LICENSE NOTICE------------------------------------
;;
;;  This program is free software: you can redistribute it and/or modify
;;  it under the terms of the GNU Lesser General Public License as published by
;;  the Free Software Foundation, either version 3 of the License, or
;;  (at your option) any later version.
;;
;;  This program is distributed in the hope that it will be useful,
;;  but WITHOUT ANY WARRANTY; without even the implied warranty of
;;  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;  GNU Lesser General Public License for more details.
;;
;;  You should have received a copy of the GNU Lesser General Public License
;;  along with this program.  If not, see <http://www.gnu.org/licenses/>.
;;-------------------------------------------------------------------------------

.module messages_system

.include "sys/messages.h.s"
.include "cpctelera.h.s"
.include "globals.inc"

;;
;; Start of _DATA area
;;
.area _DATA

_msg_w:  .db 0
_msg_x:  .db 0
_msg_buffer: .ds MSG_BUFFER_SIZE

;;
;; Start of _CODE area
;;
.area _CODE

;;-----------------------------------------------------------------
;;
;; sys_messages_init
;;
;;  Zeroes the _scratch_buf scratch area. Safe to call multiple times.
;;  Must be called before any sys_messages_show/sys_messages_close
;;  if the buffer lives at an address that the AMSDOS loader does not
;;  initialise in the loaded .bin (e.g. absolute areas above the
;;  continuous load image).
;;  Input:
;;  Output:
;;  Modified: AF, BC, DE, HL
;;
sys_messages_init::
    ld hl, #_msg_buffer
    ld de, #_msg_buffer+1
    ld bc, #MSG_BUFFER_SIZE-1
    ld (hl), #0
    ldir
    ret

;;-----------------------------------------------------------------
;;
;; sys_messages_show
;;
;;  Captures the screen area a banner is about to cover, draws a bordered
;;  box (sys_render_draw_box) and centres HL's string inside it, then
;;  returns immediately — it does not hold or wait. Width is computed from
;;  the string's length (bounded scan, max 40 chars — plenty for this
;;  project's short banners) and horizontally centred; height/y are fixed
;;  (MSG_H/MSG_Y, messages.h.s).
;;  Input:  HL = zero-terminated string
;;  Output:
;;  Modified: AF, BC, DE, HL
;;
sys_messages_show::
    ld (sms_string), hl
    ld b, #0
sms_strlen:
    ld a, (hl)
    or a
    jr z, sms_strlen_done
    inc hl
    inc b
    ld a, b
    cp #40
    jr nz, sms_strlen
sms_strlen_done:
    ld a, b
    add a, a                        ;; *2 — FONT_WIDTH bytes/char
    add a, #8                       ;; border + padding
    ld (_msg_w), a

    ld a, #80
    ld c, a
    ld a, (_msg_w)
    ld b, a
    ld a, c
    sub b
    srl a
    ld (_msg_x), a

    ;; capture the background under the box — MSG_H+1 rows, not MSG_H:
    ;; sys_render_draw_box does an internal "inc b" and draws that many
    ;; rows, so the box's actual bottom border lands one row past MSG_H.
    ;; Capturing only MSG_H left that row un-restorable — sys_messages_
    ;; close could never put it back, so the border's last line stayed on
    ;; screen after closing (user-reported bug).
    ld a, (_msg_x)
    ld c, a
    ld b, #MSG_Y
    ld de, #0xC000
    call cpct_getScreenPtr_asm      ;; hl = screen src address
    ld de, #_msg_buffer
    ld a, (_msg_w)
    ld c, a
    ld b, #(MSG_H+1)
    call cpct_getScreenToSprite_asm ;; hl=screen src, de=dst buffer, c=w, b=h

    ;; fill colour pattern — compute BEFORE touching width/height/pos
    ;; (cpct_px2byteM0_asm clobbers AF/BC/DE/HL, a real gotcha hit before
    ;; in this codebase, see map.s)
    ld h, #MSG_FILL_PEN
    ld l, #MSG_FILL_PEN
    call sys_render_pen_solid_byte
    ld a, l
    ld (sms_fill_pattern), a

    ld a, (_msg_x)
    ld c, a
    ld b, #MSG_Y
    ld de, #0xC000
    call cpct_getScreenPtr_asm
    ex de, hl
    ld a, (_msg_w)
    ld c, a
    ld b, #(MSG_H+1)
sms_fill_pattern = . + 1
    ld a, #0                        ;; sys_render_draw_box's own fill is
    call cpct_drawSolidBox_asm      ;; always black — fill ourselves first
                                     ;; with the real colour, then border-
                                     ;; only on top (per user direction:
                                     ;; blue background instead of black)

    ld h, #MSG_BORDER_PEN
    ld l, #MSG_BORDER_PEN
    call sys_render_pen_solid_byte
    ld a, l
    ld (sms_border_pattern), a

    ld a, (_msg_x)
    ld c, a
    ld b, #MSG_Y
    ld de, #0xC000
    call cpct_getScreenPtr_asm
    ex de, hl
    ld a, (_msg_w)
    ld c, a
    ld b, #MSG_H
sms_border_pattern = . + 1
    ld a, #0
    ld l, #0                        ;; border only — fill already done above
    call sys_render_draw_box

    ;; centred text — 4px/2byte left padding from the border, vertically
    ;; centred in MSG_H (font is 9px tall)
    ld a, (_msg_x)
    add a, #4
    ld c, a
    ld b, #(MSG_Y + (MSG_H-9)/2)
    ld de, #0xC000
    call cpct_getScreenPtr_asm
    ex de, hl
sms_string = . + 1
    ld hl, #0
    ld c, #0                        ;; colour index 0 = white
    jp sys_text_draw_string

;;-----------------------------------------------------------------
;;
;; sys_messages_close
;;
;;  Restores whatever sys_messages_show last captured. No-op-safe to call
;;  even if show was never called (draws whatever garbage/zeros sit in
;;  _scratch_buf at the last-used _msg_x/_msg_w — callers only ever call
;;  this after a matching show, so that's never actually exercised).
;;  Input:
;;  Output:
;;  Modified: AF, BC, DE, HL
;;
sys_messages_close::
    ld a, (_msg_x)
    ld c, a
    ld b, #MSG_Y
    ld de, #0xC000
    call cpct_getScreenPtr_asm
    ex de, hl
    ld hl, #_msg_buffer
    ld a, (_msg_w)
    ld c, a
    ld b, #(MSG_H+1)
    jp cpct_drawSprite_asm
