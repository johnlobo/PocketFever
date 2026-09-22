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

;;==============================================================================
;;  sys/render.h.s — minimal screen-clear helper
;;
;;  Only what's needed so far (game/map.s clears the screen before redrawing).
;;  Not model01's full render system (no entity queue/sort/restore-pass) —
;;  DeckTower has no moving sprites yet; expand this when it does.
;;==============================================================================

;; sys_render_clear_front_buffer
;;   Clears the front buffer (0xC000-0xFFFF) to black.
;;   Modified: AF, BC, DE, HL

;; sys_render_draw_box
;;   Draws a box outline (or filled box) — see sys/render.s for the full doc.
;;   Input: DE=video address, A=colour pattern, C=width(bytes), B=height(bytes), L=0/fill
;;   Modified: AF, BC, DE, HL
