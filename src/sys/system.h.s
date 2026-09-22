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

.module system_system


;;===============================================================================
;; PUBLIC VARIABLES
;;===============================================================================
.globl nInterrupt

;;===============================================================================
;; PUBLIC MACROS
;;===============================================================================
.mdelete m_inc_nInterrupt
.macro m_inc_nInterrupt
    ld a, (nInterrupt)
    inc a
    ld (nInterrupt), a 
.endm

.mdelete m_reset_nInterrupt
.macro m_reset_nInterrupt
    xor a
    ld (nInterrupt), a 
.endm


;;===============================================================================
;; PUBLIC METHODS
;;===============================================================================
.globl sys_system_disable_firmware