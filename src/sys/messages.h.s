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
;;  sys/messages.h.s — small centred banner window (ported from model01's
;;  src/sys/messages.s, trimmed down: no dynamic PRESS ANY KEY line, no
;;  auto-dismiss-with-delay mode, no elaborate geometry validation — this
;;  project's callers are a handful of known short strings, not arbitrary
;;  caller-supplied text, so the defensive bounds-checking model01 needs
;;  isn't earning its keep here).
;;
;;  sys_messages_init
;;    Zeroes the local 1024-byte capture buffer. Call once at startup
;;    before any show/close.
;;
;;  sys_messages_show
;;    Draws a centred banner for HL's string and returns immediately.
;;    Call sys_messages_close afterward to restore whatever was behind it.
;;==============================================================================

MSG_BUFFER_SIZE = 1024

MSG_H = 20        ;; px, box height (one text line + border/padding)
MSG_Y = 85        ;; px, box top — centred across the actor/HUD boundary
MSG_BORDER_PEN = 15  ;; white
MSG_FILL_PEN   = 2   ;; bright blue (was black — user direction)
