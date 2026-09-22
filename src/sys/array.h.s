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
.module array_manager

.include "globals.inc"
.include "sys/component.inc"
.include "sys/struct.inc"

;;===============================================================================
;; PUBLIC VARIABLES
;;===============================================================================


;;===============================================================================
;; PUBLIC METHODS
;;===============================================================================

;;===============================================================================
;; COMPONENT DEFINITION MACRO
;;===============================================================================


.macro DefineArrayStructure _Tname, _N, _ComponentSize
      _Tname'_count::               .db 0
      _Tname'_max_count::           .db _N
      _Tname'_component_size::      .db _ComponentSize
      _Tname'_pend::                .dw _Tname'_array 
      _Tname'_selected::            .db 0
      _Tname'_pselected::          .db 0
      _Tname'_array::
            .ds _N * _ComponentSize
.endm

;;===============================================================================
;; DATA ARRAY STRUCTURE CREATION
;;===============================================================================
BeginStruct a
Field a, count , 1
Field a, max_count , 1
Field a, component_size , 1
Field a, pend , 2
Field a, selected , 1
Field a, pselected , 1
Field a, array , 1
EndStruct a

;;===============================================================================
;; POINTER ARRAY STRUCTURE CREATION
;;===============================================================================
BeginStruct p
Field p, cpms , 1
Field p, status , 1
Field p, p , 2
EndStruct p
