;; Project-level parameters consumed by reusable systems.

;; Felt 160x132 (2:1 on CRT 4:3), bottom-aligned. HUD 68 px above. Balls 6x6.
TABLE_WIDTH_PX  = 160
TABLE_HEIGHT_PX = 132
TABLE_X_BYTES   = 0
TABLE_Y_PX      = 68
HUD_Y_PX        = 0
HUD_HEIGHT_PX   = 68
BALL_WIDTH_PX    = 6
BALL_HEIGHT_PX   = 8
BALL_WIDTH_BYTES = 3
MAX_ENTITIES     = 10
FELT_PEN         = 10
FELT_WIDTH_BYTES = 80

;; Legal top-left pixel of a ball on the felt. Shared by physics and collision.
TABLE_X_MAX = TABLE_WIDTH_PX-BALL_WIDTH_PX
TABLE_Y_MAX = TABLE_Y_PX+TABLE_HEIGHT_PX-BALL_HEIGHT_PX

;; sys/text.s small-digit HUD font. Width in BYTES.
S_SMALL_NUMBERS_WIDTH  = 2
S_SMALL_NUMBERS_HEIGHT = 5

;; sys/text.s regular font. Width in BYTES. Moved here (was a local constant
;; in text.s) so other modules can size things against it at assemble time
;; without including text.s itself -- game/hud.s needs it to erase a fixed-
;; width number field before redrawing (see hud.s's own comment on why).
FONT_WIDTH  = 2
FONT_HEIGHT = 9

;; 1 = border shows main-loop phases (black idle, red erase+draw, yellow
;; physics, white collision). Debug only; toggling needs make clean && make.
PROFILE_RASTER = 0

;; game/shot.s test shot: hold SPACE to charge, release to fire in a random
;; direction. SHOT_POWER_MIN/SPAN/CHARGE_STEP now live in tuning.h.s (a
;; gameplay-feel knob, not layout) -- MIN on a tap, +1 every CHARGE_STEP
;; frames held, capped at MIN+SPAN raster lines per frame.

;; HUD charge bar: one 2-byte segment per power level, SHOT_POWER_SPAN+1 max.
SHOT_BAR_X_BYTES = 2
SHOT_BAR_Y_PX    = 40
SHOT_BAR_HEIGHT  = 6
SHOT_BAR_PEN     = 15

;; game/aim.s XOR trajectory line. Dashes step out from the cue ball's CENTER
;; along the aimed direction (src/game/shot_table.s). Since V.016 the line
;; no longer stops at the felt edge: each axis of the running center
;; position bounces off its own legal range independently (a triangle-wave
;; reflection, gaim_reflect_axis), the same clamp-and-negate cushion rule
;; sys/physics.s applies to a real launched ball, so the guide shows where
;; the shot will actually go including rebounds. Crossing over a ball is
;; still safe, since sys/entity.s skips erase/draw for any settled ball, and
;; the line is only ever shown while every ball is settled (gaim_all_still).
;; AIM_STEP_MULT/AIM_DASH_COUNT (dash spacing and total reach) moved to
;; tuning.h.s -- a gameplay-feel knob, not layout.
AIM_DASH_PX      = 2
AIM_PEN          = 15
;; Legal range of the cue ball's CENTER on each axis -- same clearance from
;; the felt edge as TABLE_X_MAX/TABLE_Y_MAX (corner-based), re-expressed
;; around the center gaim_draw_line actually steps from. SPAN/PERIOD are the
;; triangle-wave reflection's span and period (gaim_reflect_axis, aim.s);
;; tools/aim_model.py's reflect() is the reference and asserts the running
;; per-dash offset never exceeds one PERIOD, which is what lets the Z80
;; routine fold with a single conditional add/subtract instead of a general
;; modulo loop.
AIM_X_LO     = BALL_WIDTH_PX/2
AIM_X_HI     = TABLE_WIDTH_PX-BALL_WIDTH_PX/2
AIM_X_SPAN   = AIM_X_HI-AIM_X_LO
AIM_X_PERIOD = 2*AIM_X_SPAN
AIM_Y_LO     = TABLE_Y_PX+BALL_HEIGHT_PX/2
AIM_Y_HI     = TABLE_Y_PX+TABLE_HEIGHT_PX-BALL_HEIGHT_PX/2
AIM_Y_SPAN   = AIM_Y_HI-AIM_Y_LO
AIM_Y_PERIOD = 2*AIM_Y_SPAN
;; AIM_TURN_S0..S2/H1/H2 (the turn ramp) moved to tuning.h.s.
;; Index into shot_directions (angle = index*360/256, DIRECTIONS=256,
;; tools/turn_model.py). 128 = 180 deg = left, toward the rack, since the
;; cue starts at the right (game/table.s).
AIM_DEFAULT_INDEX = 128

;; game/hud.s: live ANGLE/POWER readout, one row below the charge bar
;; (SHOT_BAR_Y_PX+SHOT_BAR_HEIGHT=46). Both labels and numbers use the
;; regular font (FONT_WIDTH bytes/char) via sys_text_draw_string -- byte
;; offsets are hand-placed to leave no gap narrower than one digit's width,
;; not computed from the label text length (sys_text_draw_string doesn't
;; expose one). Numbers are always exactly 3 digits (HUD_NUM_WIDTH_BYTES),
;; zero-padded, so the solid-box erase game/hud.s does before every redraw
;; (sys_text_draw_char's mask only ever paints "ink", never clears old ink
;; a shorter/different number left behind) always covers the same field.
HUD_ROW_Y_PX        = 50
HUD_ANGLE_LABEL_X_BYTES = 0     ;; "ANGLE:" (6 chars * FONT_WIDTH = 12 bytes)
HUD_ANGLE_NUM_X_BYTES   = 12    ;; 3 digits (0-359)
HUD_POWER_LABEL_X_BYTES = 22    ;; "POWER:" (6 chars * FONT_WIDTH = 12 bytes)
HUD_POWER_NUM_X_BYTES   = 34    ;; 3 digits, zero-padded (SHOT_POWER_MIN..MIN+SPAN)
HUD_NUM_WIDTH_BYTES     = 6     ;; 3 chars * FONT_WIDTH
;; sys_text_draw_string's colour input is an INDEX into sys/text.s's
;; _swapColors table (0=White, 1=Magenta, ... 14=Pink -- 15 named colours,
;; NOT a raw 0-15 CPC pen number), unlike sys_text_draw_small_char_number's
;; colour input, which IS a raw pen. Passing 15 here (as if it meant "pen
;; 15 = white") reads one row PAST the table's last entry (14), landing on
;; _char_buffer's leftover bytes from whatever drew last and using THAT as
;; the swap pattern -- found the hard way: game/hud.s's numbers rendered as
;; a garbled mix of two glyphs until this was traced back to the wrong unit
;; for this constant. 0 = White in the colour-index scheme, matching what
;; sys_text_draw_string already uses for the version/hint strings.
HUD_TEXT_COLOUR_WHITE = 0
