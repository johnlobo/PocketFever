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

.include "sys/array.h.s"
.include "cpctelera.h.s"
.include "globals.inc"

;;
;; Start of _DATA area 
;;  SDCC requires at least _DATA and _CODE areas to be declared, but you may use
;;  any one of them for any purpose. Usually, compiler puts _DATA area contents
;;  right after _CODE area contents.
;;
.area _DATA



;;
;; Start of _CODE area
;; 
.area _CODE

;;-----------------------------------------------------------------
;;
;; sys_array_init
;;
;;  Initializes an array while preserving its configured capacity and stride.
;;  Input: IX = array structure
;;  Output: array is empty; a_pend points to its first slot
;;  Modified: AF, HL
;;
sys_array_init::
    xor a
    ld a_count(ix), a           ;; Initialize the number of elements in the array

    ld__hl_ix                   ;; point hl to the start of the array 
    ld a, #a_array
    add_hl_a
    
    ld a_pend(ix), l            ;; load pointer to the end in hl
    ld a_pend+1(ix), h

    ld  (hl), #c_cmp_invalid   ;;ponemos el primer elemento del array con tipo invalido
    ret


;;-----------------------------------------------------------------
;;
;; sys_array_create_element
;;
;;  Appends one element copied from the template pointed to by HL. This is the
;;  generic array operation: byte zero of an element has no special meaning.
;;  Input:  IX = array structure, HL = template
;;  Output: HL = new element, carry clear on success; carry set when full
;;  Modified: AF, BC, DE, HL
;;
sys_array_create_element::
    ld b, #0
    ld a, a_component_size(ix)
    ld c, a
    jr sace_append

;;-----------------------------------------------------------------
;;
;; sys_array_create_reusable_element
;;
;;  Component-pool insertion. Before appending, scans allocated slots and
;;  reuses the first one whose component byte (offset zero) is invalid/zero.
;;
;;  Slots are recycled: entities destroyed at runtime set their component byte
;;  (offset 0) to c_cmp_invalid (0) but leave a_count untouched, because
;;  compacting the array mid-iteration would corrupt the callers looping over
;;  it. This routine therefore first scans [0, a_count) for such a dead slot and
;;  reuses it in place; only when none is free does it append and bump a_count.
;;  Without this the pool would leak one slot per destroyed entity and fill up.
;;
;;  Input:  IX = component-pool array, HL = template
;;  Output: HL = new or recycled element
;;          carry clear on success; carry set if the array is full
;;  Modified: AF, BC, DE, HL
;;
sys_array_create_reusable_element::
    ld b, #0                        ;; bc = component size (stride + LDIR count)
    ld a, a_component_size(ix)      ;;
    ld c, a                         ;;

    ;; --- Reuse pass: look for a dead slot (component byte == 0) ---
    ld a, a_count(ix)
    or a
    jr z, sace_append               ;; nothing allocated yet: append

    push hl                         ;; save template pointer
    push ix                         ;; hl = &element[0]
    pop hl
    ld de, #a_array                 ;;
    add hl, de                      ;;
    ld d, a                         ;; d = slots left to scan (a_count)
sace_scan:
    ld a, (hl)                      ;; component byte of this slot
    or a
    jr z, sace_reuse                ;; found a dead slot (hl points to it)
    add hl, bc                      ;; advance to next slot
    dec d
    jr nz, sace_scan

    pop hl                          ;; no free slot: restore template and append
    jr sace_append

sace_reuse:
    ex de, hl                       ;; de = dead slot (destination)
    pop hl                          ;; hl = template (source)
    push de                         ;; save slot for return value
    ldir                            ;; overwrite the dead slot with the template
    pop hl                          ;; hl = reused slot
    or a                            ;; carry clear: success
    ret

sace_append:
    ld a, a_count(ix)               ;; refuse to add past the array capacity
    cp a_max_count(ix)
    jr c, sace_has_capacity
    scf                             ;; carry set: no dead slot and no capacity
    ret

sace_has_capacity:

    ld a, c                         ;; component size
    ld (_create_size), a            ;; self modifying code to move the size of the entity to bc
    xor a                           ;; ld a, #0
    ld (_create_size+1), a          ;;

    ld e, a_pend(ix)                ;; Load the address of the next element in de
    ld d, a_pend+1(ix)              ;;
    push de                         ;; Store the address of the next element to return it at the end
    ldir                            ;; de=pend, bc=component_size, hl=pointer to the entity to be added

    inc a_count(ix)                 ;; increase the number of entities

    ld l, a_pend(ix)                ;; load in hl the pointer to the next entity
    ld h, a_pend+1(ix)
_create_size = .+1
    ld   bc, #00
    add  hl, bc

    ld   a_pend(ix), l              ;; update the pointer to the next entity
    ld   a_pend+1(ix), h            ;;

    pop hl                          ;; restore the new element address in hl
    or a                            ;; carry clear: success
    ret




;;-----------------------------------------------------------------
;;
;; sys_array_remove_element
;;
;;  Removes an element and compacts every following element one slot to the
;;  left. Do not call this while iterating the same array; invalidate/recycle
;;  component pools instead when removal must happen inside a callback.
;;  Input:  A = zero-based element index, IX = array structure
;;  Output: carry clear on success; carry set if index is outside [0,a_count)
;;  Modified: AF, BC, DE, HL
;;
sys_array_remove_element::
    call sys_array_get_element
    ret c                           ;; invalid index; array remains untouched

    push hl                         ;; destination = element[index]
    ld c, a_component_size(ix)
    ld b, #0
    add hl, bc                      ;; HL = source = element[index+1]

    ld e, a_pend(ix)
    ld d, a_pend+1(ix)              ;; DE = byte after last live element
    ld a, h
    cp d
    jr nz, sare_compact
    ld a, l
    cp e
    jr z, sare_update_header        ;; removing last element: nothing to copy

sare_compact:
    push hl                         ;; save source
    ex de, hl                       ;; HL = old pend, DE = source
    or a                            ;; clear carry before subtraction
    sbc hl, de                      ;; HL = bytes after removed element
    ld b, h
    ld c, l
    pop hl                          ;; HL = source
    pop de                          ;; DE = destination
    ldir
    jr sare_shrink

sare_update_header:
    pop hl                          ;; discard saved destination
sare_shrink:
    ld l, a_pend(ix)
    ld h, a_pend+1(ix)
    ld c, a_component_size(ix)
    ld b, #0
    or a
    sbc hl, bc                      ;; new pend = old pend - component size
    ld a_pend(ix), l
    ld a_pend+1(ix), h
    ld (hl), #c_cmp_invalid         ;; keep first free slot visibly invalid
    dec a_count(ix)
    or a                            ;; carry clear: success
    ret


;;-----------------------------------------------------------------
;;
;; sys_array_get_address_from_pointer
;;
;;  Retrieves element A from the array, then dereferences its p_p
;;  field and returns the pointed-to address in HL.
;;  Input:  A = element index, IX = array structure
;;  Output: HL = dereferenced pointer from p_p field, carry clear on success;
;;          HL = 0 and carry set when the index is invalid
;;  Modified: AF, BC, DE, HL, IX
;;
sys_array_get_address_from_pointer::
    call sys_array_get_element
    ret c
    ld__ix_hl
    ld l, p_p(ix)
    ld h, p_p+1(ix)
    ret

;;-----------------------------------------------------------------
;;
;; sys_array_get_element
;;
;;  Retrieves an element by index.
;;  Input:  A = zero-based index, IX = array structure
;;  Output: HL = element pointer and carry clear on success;
;;          HL = 0 and carry set when index >= a_count
;;  Modified: AF, BC, DE, HL
;;
sys_array_get_element::
    cp a_count(ix)
    jr nc, sage_invalid
    ld b, a
    push ix                     ;; load in hl the beginning of the array
    pop hl                      ;;
    ld de, #a_array
    add hl, de

    ld a, b
    or a
    jr z, sage_success

    ld d, #0                    ;; copy the size of an entity in de
    ld e, a_component_size(ix)  ;; 
_g_e_sum_loop:                  ;;
    add hl, de                  ;;  add de to hl until we reach the element
    djnz _g_e_sum_loop          ;;

sage_success:
    or a                        ;; carry clear
    ret
sage_invalid:
    ld hl, #0
    scf
    ret


;;-----------------------------------------------------------------
;;
;; sys_array_get_random_element
;;
;;  Retrieves a random element from [offset, a_count).
;;  Input:  IX = array structure, A = first eligible index (offset)
;;  Output: HL = element pointer, A = selected index, carry clear on success;
;;          HL = 0 and carry set if offset >= a_count
;;  Modified: AF, BC, DE, HL
;;
sys_array_get_random_element::
    cp a_count(ix)
    jr nc, sagre_invalid
    ld (SUB_OFFSET), a
    ld (ADD_OFFSET), a

    ld a, a_count(ix)               ;; load max number in a
    dec a
    SUB_OFFSET = . +1
    sub #0x00
    call sys_util_get_random_number
    ADD_OFFSET = . +1
    add #0x00
    ld (_r_e_output), a             ;; store the random number in the output variable
    call sys_array_get_element
_r_e_output = .+1
    ld a, #00
    or a                            ;; carry clear
    ret
sagre_invalid:
    ld hl, #0
    scf
    ret




;;-----------------------------------------------------------------
;;
;; sys_array_move_all_elements
;;
;;  Moves every element from one array into another. Arrays must have the same
;;  component size. If the destination fills, the remaining source elements
;;  stay untouched.
;;  Input:  HL = source array, DE = destination array
;;  Output: carry clear when all elements moved; carry set on size mismatch or
;;          insufficient destination capacity
;;  Modified: AF, BC, DE, HL, IX
;;
sys_array_move_all_elements::
    ld a, h
    cp d
    jr nz, same_distinct
    ld a, l
    cp e
    jr z, same_success              ;; moving an array to itself is a no-op
same_distinct:
    ld (FIRST_ARRAY), hl
    ld (THIRD_ARRAY), hl
    ld (FIRST_ARRAY_SIZE), hl
    ex de, hl
    ld (SECOND_ARRAY), hl
    ld (SECOND_ARRAY_SIZE), hl

FIRST_ARRAY_SIZE = .+2
    ld ix, #0000
    ld a, a_component_size(ix)
SECOND_ARRAY_SIZE = .+2
    ld ix, #0000
    cp a_component_size(ix)
    jr nz, same_error
_move_loop:
FIRST_ARRAY = .+2
    ld ix, #0000
    ld a, a_count(ix)
    or a
    jr z, same_success
    xor a
    call sys_array_get_element

SECOND_ARRAY = .+2
    ld ix, #0000
    call sys_array_create_element
    jr c, same_error                 ;; do not remove source when destination is full

THIRD_ARRAY = .+2
    ld ix, #0000
    xor a
    call sys_array_remove_element
    
    jr _move_loop
same_success:
    or a
    ret
same_error:
    scf
    ret

;;-----------------------------------------------------------------
;;
;; sys_array_execute_each
;;
;;  executes the routine pointed in HL for each element in the array pointed in IX
;;  Input:  hl: routine to execute on each
;;          ix: array to loop
;;  Output: 
;;  Modified: AF, BC, DE, HL
;;
sys_array_execute_each::
    ld a, a_count(ix)       ;; retrieve number of elements in the array
    or a                    ;; If no elements in arrary return
    ret z 

    ld b, a                 ;; move the number of elements to b for indexing djnz

    ld (routine), hl        ;; store routine in memory

    ld a, a_component_size(ix)  ;; store component_size in memory
    ld (comp_size), a       ;;    
    
    push ix                 ;; load start of array in hl
    pop hl                  ;;
    ld de, #a_array         ;;
    add hl, de              ;;
    
    push hl                 ;;
    pop ix                  ;;  load ix with the first element

loop_each:
    push bc                 ;; save index in stack
    ld hl, #return_point    ;;
    push hl                 ;; set the return point in the stack

    ld hl, (routine)        ;; Move routine to hl
    jp (hl)                 ;; jump to the routine

return_point:
    ld d, #0                ;; retrieve component_size
    ld a, (comp_size)       ;;
    ld e, a                 ;;

    add ix, de              ;; move ix to the next element

    pop bc                  ;; restore index
    djnz loop_each

    ret

routine: .dw #0000
routine_ix: .dw #0000
routine_iy: .dw #0000
comp_size: .db #0
pattern: .db #0

;;-----------------------------------------------------------------
;;
;; sys_array_execute_each_ix_matching
;;
;;  executes the routine pointed in HL for each element in the array pointed in IX
;;  Input:  hl: routine to execute on each
;;          ix: array to loop
;;          b: pattern to match
;;  Output: 
;;  Modified: AF, BC, DE, HL
;;
sys_array_execute_each_ix_matching::
    ld a, b                 ;; Save pattern for latter use
    ld (pattern), a         ;;

    ld a, a_count(ix)       ;; retrieve number of elements in the array
    or a                    ;; If no elements in arrary return
    ret z 

    ld b, a                 ;; move the number of elements to b for indexing djnz

    ld (routine_ix), hl        ;; store routine in memory

    ld a, a_component_size(ix)  ;; store component_size in memory
    ld (comp_size), a       ;;    
    
    push ix                 ;; load start of array in hl
    pop hl                  ;;
    ld de, #a_array         ;;
    add hl, de              ;;
    
    push hl                 ;;
    pop ix                  ;;  load ix with the first element

maeeixm_loop_each:
    push bc                 ;; save index in stack

    ld a, (pattern)
    ld b, a
    ld a, x_cmps(ix)
    and b
    cp b
    jr nz, maeeixm_return_point

    ld hl, #maeeixm_return_point    ;;
    push hl                 ;; set the return point in the stack

    ld hl, (routine_ix)        ;; Move routine to hl
    jp (hl)                 ;; jump to the routine

maeeixm_return_point:
    ld d, #0                ;; retrieve component_size
    ld a, (comp_size)       ;;
    ld e, a                 ;;

    add ix, de              ;; move ix to the next element

    pop bc                  ;; restore index
    djnz maeeixm_loop_each

    ret

;;-----------------------------------------------------------------
;;
;; sys_array_execute_each_iy_matching
;;
;;  executes the routine pointed in HL for each element in the array pointed in IY
;;  Input:  hl: routine to execute on each
;;          iy: array to loop
;;          b: pattern to match
;;  Output: 
;;  Modified: AF, BC, DE, HL
;;
sys_array_execute_each_iy_matching::
    ld a, b                 ;; Save pattern for latter use
    ld (pattern), a         ;;

    ld a, a_count(iy)       ;; retrieve number of elements in the array
    or a                    ;; If no elements in arrary return
    ret z 

    ld b, a                 ;; move the number of elements to b for indexing djnz

    ld (routine_iy), hl        ;; store routine in memory

    ld a, a_component_size(iy)  ;; store component_size in memory
    ld (comp_size), a       ;;    
    
    push iy                 ;; load start of array in hl
    pop hl                  ;;
    ld de, #a_array         ;;
    add hl, de              ;;
    
    push hl                 ;;
    pop iy                  ;;  load ix with the first element

maeeiym_loop_each:
    push bc                 ;; save index in stack

    ld a, (pattern)
    ld b, a
    ld a, x_cmps(iy)
    and b
    cp b
    jr nz, maeeiym_return_point

    ld hl, #maeeiym_return_point    ;;
    push hl                 ;; set the return point in the stack

    ld hl, (routine_iy)        ;; Move routine to hl
    jp (hl)                 ;; jump to the routine

maeeiym_return_point:
    ld d, #0                ;; retrieve component_size
    ld a, (comp_size)       ;;
    ld e, a                 ;;

    add iy, de              ;; move ix to the next element

    pop bc                  ;; restore index
    djnz maeeiym_loop_each

    ret
