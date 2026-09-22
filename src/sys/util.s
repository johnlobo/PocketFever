;;-----------------------------LICENSE NOTICE------------------------------------
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

.module sys_util

.include "cpctelera.h.s"
.include "globals.inc"

SCORE_NUM_BYTES = 4

;;
;; Start of _DATA area 
;;  SDCC requires at least _DATA and _CODE areas to be declared, but you may use
;;  any one of them for any purpose. Usually, compiler puts _DATA area contents
;;  right after _CODE area contents.
;;
.area _DATA


string_buffer:: .asciz "          "
;; Registros
H_CHARACTERS = 01
H_ADJUST     = 02
V_ADJUST     = 05
V_LINES      = 06
V_SYNC       = 07


;;
;; Start of _CODE area
;; 
.area _CODE

;;-----------------------------------------------------------------
;;
;; sys_util_h_times_e
;;
;;  Multiplies two unsigned 8-bit values without using a general multiplier.
;;  Input: H = multiplicand; E = multiplier
;;  Output: HL = product; D = 0; A, BC and E preserved
;;  Modified: F, D, H, L
;;
;; 36 bytes
;; min: 190cc
;; max: 242cc
;; avg: 216cc
;; Credits:
;;  Z80Heaven (http://z80-heaven.wikidot.com/advanced-math#toc9)

sys_util_h_times_e::
  ld d,#0
  ld l,d
  sla h 
  jr nc,.+3 
  ld l,e
  add hl,hl 
  jr nc,.+3 
  add hl,de
  add hl,hl 
  jr nc,.+3 
  add hl,de
  add hl,hl 
  jr nc,.+3 
  add hl,de
  add hl,hl 
  jr nc,.+3 
  add hl,de
  add hl,hl 
  jr nc,.+3 
  add hl,de
  add hl,hl 
  jr nc,.+3 
  add hl,de
  add hl,hl 
  ret nc 
  add hl,de
  ret

;;-----------------------------------------------------------------
;;
;; sys_util_hl_div_c
;;
;;  Divides HL by C using 16-step binary long division.
;;  Input:  HL = numerator, C = denominator
;;  Output: HL = quotient, A = remainder, B = 0, C unchanged, DE unchanged
;;  Modified: AF, B, HL
;;
sys_util_hl_div_c::
       ld b,#16
       xor a
         add hl,hl
         rla
         cp c
         jr c,.+4
           inc l
           sub c
         djnz .-7
       ret

;;-----------------------------------------------------------------
;;
;; sys_util_BCD_GetEnd
;;
;;  
;;  Input:  b: number of bytes of the bcd number
;;          de: source for the first bcd bnumber
;;          hl: source for the second bcd number
;;  Output:
;;  Modified: af, bc,de, hl
;;
;;  Chibi Akumas BCD code (https://www.chibiakumas.com/z80/advanced.php#LessonA1)
;;
sys_util_BCD_GetEnd::
;Some of our commands need to start from the most significant byte
;This will shift HL and DE along b bytes
	push bc
	ld c,b	;We want to add BC, but we need to add one less than the number of bytes
	dec c
	ld b,#0
	add hl,bc
	ex de, hl	;We've done HL, but we also want to do DE
	add hl,bc
	ex de, hl
	pop bc
	ret

;;-----------------------------------------------------------------
;;
;; BCD_Add
;;
;;   Add two BCD numbers
;;  Input:  hl: Number to add to de
;;          de: Number to store the sum 
;;  Output:
;;  Modified: af, bc,de, hl
;;
;;  Chibi Akumas BCD code (https://www.chibiakumas.com/z80/advanced.php#LessonA1)
;;
;;-----------------------------------------------------------------
;;
;; sys_util_BCD_Add
;;
;;  Adds one little-endian packed-BCD value into another.
;;  Input: HL = source BCD; DE = destination BCD; B = byte count
;;  Output: DE contains the sum
;;  Modified: AF, B, DE, HL
;;
sys_util_BCD_Add::
    or a
BCD_Add_Again:
    ld a, (de)
    adc (hl)
    daa
    ld (de), a
    inc de
    inc hl
    djnz BCD_Add_Again
    ret
  
;;-----------------------------------------------------------------
;;
;; sys_util_BCD_Compare
;;
;;  Compare two BCD numbers
;;  Input:  hl: BCD Number 1
;;          de: BCD Number 2
;;  Output:
;;  Modified: af, bc,de, hl
;;
;;  Chibi Akumas BCD code (https://www.chibiakumas.com/z80/advanced.php#LessonA1)
;;
sys_util_BCD_Compare::
  ld b, #SCORE_NUM_BYTES
  call sys_util_BCD_GetEnd
BCD_cp_direct:
  ld a, (de)
  cp (hl)
  ret c
  ret nz
  dec de
  dec hl
  djnz BCD_cp_direct
  or a                    ;; Clear carry
  ret

;;-----------------------------------------------------------------
;;
;; sys_util_seed_random
;;
;;  Seeds the engine's Marsaglia XOR-shift PRNG (cpct_getRandom_mxor_u8_asm,
;;  what sys_util_get_random_number below is built on) with real per-boot
;;  entropy. Without this, cpct_mxor32_seed starts at its fixed link-time
;;  default and never changes unless seeded — any run that calls random the
;;  same number of times in the same order before a given point (e.g. map
;;  generation always makes the same calls at boot, then the first combat
;;  reached via the same path) reproduces the EXACT same "random" sequence
;;  every single boot (real bug hit in testing: the first reward always
;;  offered the same 3 cards). Mixes the Z80 R register (increments on every
;;  instruction fetch, including during interrupt service — its value at any
;;  sampled point drifts with real interrupt-timing jitter, not fully
;;  reproducible run to run) with nInterrupt (sys/system.s). Not
;;  cryptographic, just enough to stop the game replaying identically.
;;  Call once, as early as possible in game_app_init, before anything else
;;  calls sys_util_get_random_number.
;;  Input:
;;  Output:
;;  Modified: AF, BC, DE, HL
;;
sys_util_seed_random::
  ld a, r
  ld d, a
  ld a, (nInterrupt)
  ld e, a
  ld a, r
  xor #0x5A
  ld h, a
  ld a, (nInterrupt)
  cpl
  ld l, a
  ld a, d
  or e
  or h
  or l
  jr nz, susr_ok            ;; seed must never be all-zero (cpct_setSeed_
  ld l, #1                  ;; mxor's own documented restriction)
susr_ok:
  jp cpct_setSeed_mxor_asm

;;-----------------------------------------------------------------
;;
;; sys_util_get_random_number
;;
;;  Returns a random number between 0 and <end>
;;  Input:  a: <end>
;;  Output: a: random number
;;  Modified: af, bc,de, hl

sys_util_get_random_number::
  inc a                               ;; Increment a to make the modulus calculation work
  ld (#random_max_number), a
  call cpct_getRandom_mxor_u8_asm
  ld a, l                             ;; Calculates a pseudo modulus of max number
  ld h,#0                             ;; Load hl with the random number
random_max_number = .+1
  ld c, #0                            ;; Load c with the max number
  ld b, #0
_random_mod_loop:
  or a                                ;; reset carry
  sbc hl,bc                           ;; hl = hl - bc
  jp p, _random_mod_loop              ;; Jump back if hl > 0
  add hl,bc                           ;; Adds max number to hl back to get back to positive values
  ld a,l                              ;; loads the normalized random number in a
ret

;;-----------------------------------------------------------------
;;
;; sys_util_delay
;;
;;  Waits a determined number of frames 
;;  Input:  b: number of frames
;;  Output:
;;  Modified: af, bc
;;
sys_util_delay::
  push bc
  call cpct_waitVSYNCStart_asm
  pop bc
  djnz sys_util_delay
  ret

;;-----------------------------------------------------------------
;;
;; CRTC_V_auto
;;
;;  Writes DE to CRTC register V_LINES, controlling the number of
;;  visible character rows (used for fade effects).
;;  Input:  DE = value to write to V_LINES register
;;  Output:
;;  Modified: AF, BC, HL
;;
CRTC_V_auto:
	ld bc, #0xBC00 + V_LINES
	out (c), c
	ld hl, #0xBD00
	add hl, de
	ld b, h
	ld c, l
	out (c), c
	ret

;;-----------------------------------------------------------------
;;
;; CRTC_H_auto
;;
;;  Writes DE to CRTC register H_ADJUST, shifting the horizontal
;;  display position (used for screen-shake effects).
;;  Input:  DE = value to write to H_ADJUST register
;;  Output:
;;  Modified: AF, BC, HL
;;
CRTC_H_auto:
	ld bc, #0xBC00 + H_ADJUST
	out (c), c
	ld hl, #0xBD00
	add hl, de
	ld b, h
	ld c, l
	out (c), c
	ret

;;-----------------------------------------------------------------
;;
;; sys_util_fadeOut
;;
;;  Animates a vertical wipe-out by shrinking the visible screen
;;  height from 25 rows down to 0 via CRTC V_LINES.
;;  Input:
;;  Output:
;;  Modified: AF, BC, DE, HL
;;
sys_util_fadeOut::
	ld de, #25
height_out:
    ld a, #12
	call crt_delay
	call CRTC_V_auto
	dec e
	jp nz, height_out
	call CRTC_V_auto
	ret

;;-----------------------------------------------------------------
;;
;; sys_util_fadeIn
;;
;;  Animates a vertical reveal by expanding the visible screen
;;  height from 0 up to 25 rows via CRTC V_LINES.
;;  Input:
;;  Output:
;;  Modified: AF, BC, DE, HL
;;
sys_util_fadeIn::
	ld de, #0
height_in:
    ld a, #12
	call crt_delay 
	call CRTC_V_auto
	inc e
	ld a, e
	cp #26
	jp nz, height_in
	ret

;;-----------------------------------------------------------------
;;
;; sys_util_temblor
;;
;;  Screen-shake effect: rapidly shifts the horizontal display
;;  position left and right via CRTC H_ADJUST.
;;  Input:
;;  Output:
;;  Modified: AF, BC, DE, HL
;;
sys_util_temblor::
	ld de, #47
	call CRTC_H_auto
	ld de, #45
    ld a, #9
	call crt_delay
	call CRTC_H_auto
	ld de, #46
    ld a, #9
	call crt_delay 
	call CRTC_H_auto
	ret

;;-----------------------------------------------------------------
;;
;; crt_delay
;;
;;  Busy-waits for A frames using HALT, then returns.
;;  Input:  A = number of frames to wait
;;  Output:
;;  Modified: AF
;;
crt_delay:
	halt
	dec a
	jr nz, crt_delay
	ret

; Z80 Assembly Routine: Count Set Bits (1s)
;
; Description: Counts the number of '1' bits in an 8-bit binary number.
;
; Input:
;   Register A: The 8-bit number to be analyzed.
;
; Output:
;   Register B: Contains the count of '1's found in the input number.
;
; Affected Registers:
;   A, B, C, F (Flags)

;;-----------------------------------------------------------------
;;
;; sys_util_count_set_bits
;;
;;  Counts set bits in an 8-bit value; B must be zero on entry.
;;  Input: A = value; B = 0
;;  Output: B = population count of the input value; C = 0
;;  Modified: AF, B, C
;;
sys_util_count_set_bits::
    XOR B           ; B must be 0: preserve A and clear carry before rotating.
    LD C, #8         ; Initialize bit counter (register C) to 8 (for 8 bits).

BIT_LOOP:
    RLA             ; Rotate Accumulator A left. The Most Significant Bit (MSB)
                    ; moves into the Carry Flag (CF). The previous CF moves into the Least Significant Bit (LSB).
    JR NC, NEXT_BIT ; If Carry Flag is CLEAR (the bit was 0), jump to NEXT_BIT.
    INC B           ; If Carry Flag is SET (the bit was 1), increment the '1's counter.

NEXT_BIT:
    DEC C           ; Decrement the bit counter.
    JR NZ, BIT_LOOP ; If C is not zero, more bits to check, loop again.

    RET             ; Return from the routine. The result is in B.

;;-----------------------------------------------------------------
;;
;; sys_utiL_reduce_a
;;
;;  Moves A one step toward zero: decrements if positive, increments
;;  if negative, does nothing if zero. Used to apply friction.
;;  Input:  A = signed speed value
;;  Output: A = speed value with magnitude reduced by 1
;;  Modified: AF
;;
sys_utiL_reduce_a:
  or a            ; 1. Actualiza las banderas (S y Z) sin cambiar el valor de A.
  ret z           ; 2. Si es CERO (Flag Z=1), no hacemos nada. Saltamos al final.
  jp M, es_neg    ; 3. Si es NEGATIVO (Flag S=1/Minus), saltamos a sumar.
; --- Caso Positivo ---
  dec a           ; Si es positivo (ej: 5), restamos 1 (queda 4).
  ret             ; Retornamos para no ejecutar la parte negativa.
es_neg:
; --- Caso Negativo ---
  inc A           ; Si es negativo (ej: -5), sumamos 1 (queda -4).
                  ; Al sumar 1 a un negativo, reducimos su magnitud.
	ret
