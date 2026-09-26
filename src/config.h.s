;; Project-level parameters consumed by reusable systems.

;; Felt 160x132 (2:1 on CRT 4:3), bottom-aligned. HUD 68 px above. Balls 6x6.
TABLE_WIDTH_PX  = 160
TABLE_HEIGHT_PX = 132
TABLE_X_BYTES   = 0
TABLE_Y_PX      = 68
HUD_Y_PX        = 0
HUD_HEIGHT_PX   = 68
BALL_WIDTH_PX    = 6
BALL_HEIGHT_PX   = 6
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

;; 1 = border shows main-loop phases (black idle, red erase+draw, yellow
;; physics, white collision). Debug only; toggling needs make clean && make.
PROFILE_RASTER = 0

;; game/shot.s test shot: hold SPACE to charge, release to fire in a random
;; direction. Power is a multiple of the 0.25 line/frame direction step:
;; MIN on a tap, +1 every SHOT_CHARGE_STEP frames held, capped at MIN+SPAN,
;; i.e. 2..4 raster lines per frame, full on the 49th held frame (~1 s). The top end
;; stays under BALL_HEIGHT_PX so no ball can jump through another in a frame.
SHOT_POWER_MIN   = 8
SHOT_POWER_SPAN  = 8
SHOT_CHARGE_STEP = 6

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
;; AIM_STEP_MULT/AIM_DASH_COUNT set the dash spacing and total reach (their
;; product is the arc length in raw 8.8 direction-vector units, +50% over
;; V.015's 40*5=200); tools/aim_model.py sizes them and checks the running
;; accumulator never overflows 16 bits for shot_table.s's widest direction.
AIM_STEP_MULT    = 50
AIM_DASH_COUNT   = 6
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
;; Index-units advanced per held frame while a cursor key is held, staged:
;; starts at 1 (the finest of the 256 directions, so a tap is always exactly
;; that precise) and grows the longer the key stays held, so a full 256-step
;; revolution doesn't take forever at that resolution. V.017 replaced the
;; old THROTTLE ramp (frames PER step, step always 1) with this STEP ramp (a
;; step every held frame, size grows) -- DIRECTIONS moved from 64 to 256 and
;; a flat step of 1 the whole way would have quadrupled full-turn time.
;; AIM_TURN_Hn = frames continuously held before that stage's step
;; (AIM_TURN_Sn) applies; ascending, last one is the ceiling -- 4, reached at
;; AIM_TURN_H2, is deliberately the same top angular speed (5.625 deg/frame)
;; the old ramp topped out at, so a long hold spins exactly as fast as
;; before; only the finer stages below are new. Sized and verified with
;; tools/turn_model.py; change there first.
AIM_TURN_S0 = 1               ;; 0-19 held frames: 1 index/frame  (1.406 deg/frame)
AIM_TURN_H1 = 20
AIM_TURN_S1 = 2                ;; 20-44:           2 index/frame  (2.812 deg/frame)
AIM_TURN_H2 = 45
AIM_TURN_S2 = 4                ;; 45+ (ceiling):   4 index/frame  (5.625 deg/frame)
;; Index into shot_directions (angle = index*360/256, DIRECTIONS=256,
;; tools/turn_model.py). 128 = 180 deg = left, toward the rack, since the
;; cue starts at the right (game/table.s).
AIM_DEFAULT_INDEX = 128
