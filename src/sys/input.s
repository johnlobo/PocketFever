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

.module input_system

.include "cpctelera.h.s"
.include "sys/input.h.s"
.include "globals.inc"

.area _CODE

;;-----------------------------------------------------------------
;;
;; sys_input_generic_update
;;
;;  Ported from model01/src/sys/input.s — see sys/input.h.s for the table
;;  format and usage.
;;  Input:  IY = key-action table, IX = struct pointer passed through to handlers
;;  Output:
;;  Modified: IY, BC
;;
sys_input_generic_update::
    jr sys_input_giu_first_key
sys_input_giu_keys_loop:
    ld bc, #4
    add iy, bc
sys_input_giu_first_key:
    ld l, 0(iy)
    ld h, 1(iy)
    ld a, l
    or h
    ret z                            ;; null key: end of table
    call cpct_isKeyPressed_asm
    jr z, sys_input_giu_keys_loop
    ld hl, #sys_input_giu_keys_loop
    push hl                          ;; handler returns here, scan continues
    ld l, 2(iy)
    ld h, 3(iy)
    jp (hl)
