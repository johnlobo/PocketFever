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
;;  sys/input.h.s — generic key-table dispatcher (ported from model01/src/sys/input.s)
;;
;;  A caller builds a table of (key, handler) 4-byte pairs terminated by a
;;  null key, e.g.:
;;      game_map_key_actions:
;;          .dw Key_CursorLeft, game_map_cursor_prev
;;          .dw Key_CursorRight, game_map_cursor_next
;;          .dw Key_Space, game_map_confirm_move
;;          .dw 0
;;  sys_input_generic_update walks it once, calling every handler whose key is
;;  currently pressed (so several keys held at once all fire). Handlers must
;;  end in a plain `ret`. Debounce/"wait for release" (so a held key doesn't
;;  refire every frame) is the caller's responsibility — see how game/map.s's
;;  game_map_update wraps this.
;;==============================================================================

;; sys_input_generic_update
;;   Input:  IY = key-action table, IX = struct pointer passed through to
;;           handlers (handlers may ignore it if they don't need one)
;;   Output:
;;   Modified: IY, BC (and whatever each fired handler modifies)
