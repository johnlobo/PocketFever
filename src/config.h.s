;; Project-level parameters consumed by reusable systems.

;; Felt 160x132 (2:1 on CRT 4:3), bottom-aligned. HUD 68 px above. Balls 4x6.
TABLE_WIDTH_PX  = 160
TABLE_HEIGHT_PX = 132
TABLE_X_BYTES   = 0
TABLE_Y_PX      = 68
HUD_Y_PX        = 0
HUD_HEIGHT_PX   = 68
BALL_WIDTH_PX    = 4
BALL_HEIGHT_PX   = 6
BALL_WIDTH_BYTES = 2
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
;; along the aimed direction (src/game/shot_table.s), stopping only at the
;; felt edge -- crossing over a ball is safe, since sys/entity.s skips
;; erase/draw for any settled ball, and the line is only ever shown while
;; every ball is settled (gaim_all_still). AIM_STEP_MULT/AIM_DASH_COUNT just
;; set the dash spacing and how far the guide reaches; tools/aim_model.py
;; sizes them relative to the felt, no longer relative to any ball's box.
AIM_STEP_MULT    = 40
AIM_DASH_COUNT   = 5
AIM_DASH_PX      = 2
AIM_PEN          = 15
;; Frames per direction step while a cursor key is held, staged: starts slow
;; (precise single-step aiming) and ramps to fast the longer the key stays
;; held, so a 64-step revolution doesn't take forever without sacrificing
;; fine control at the start. Sized and verified with tools/turn_model.py;
;; change there first. AIM_TURN_Hn = frames continuously held before that
;; stage's throttle (AIM_TURN_Tn) applies; ascending, last one is the floor.
AIM_TURN_T0 = 6              ;; 0-17 held frames:  1 step / 6 frames (~120 ms/step)
AIM_TURN_H1 = 18
AIM_TURN_T1 = 4              ;; 18-35:             1 step / 4 frames (~80 ms/step)
AIM_TURN_H2 = 36
AIM_TURN_T2 = 2              ;; 36-59:             1 step / 2 frames (~40 ms/step)
AIM_TURN_H3 = 60
AIM_TURN_T3 = 1              ;; 60+ (floor):       1 step / frame    (~20 ms/step)
;; Index into shot_directions (angle = index*360/64). 32 = 180 deg = left,
;; toward the rack, since the cue starts at the right (game/table.s).
AIM_DEFAULT_INDEX = 32
