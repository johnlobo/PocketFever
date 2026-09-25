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
