;; Gameplay-FEEL constants -- the numbers worth iterating on for how the
;; game plays (shot power, friction, turning speed, collision punch),
;; separate from config.h.s's screen/entity/rendering layout. Change these
;; first when something feels off; rebuild (`make clean && make` if you
;; only touched a .h.s -- the Makefile doesn't track header dependencies)
;; and run the relevant test (see each constant's own comment) before
;; touching anything else. Included from globals.inc right after
;; config.h.s (and includes config.h.s itself, not globals.inc -- this
;; file IS one of globals.inc's own includes, so including that back would
;; be circular; every .h.s in this project gets assembled standalone as
;; well as via inclusion, so it needs BALL_HEIGHT_PX available on its own).
.include "config.h.s"

;; sys/physics.s: linear friction along the direction of travel, in 1/256 px
;; per frame per frame. tools/friction_model.py models this exact code and
;; is the reference tests/physics_test.py checks the real build against --
;; change the value there first, then here.
PHYS_FRICTION = 4

;; game/shot.s: hold SPACE to charge, release to fire. Power is MIN on a
;; tap, +1 every CHARGE_STEP frames held, capped at MIN+SPAN. Keep the top
;; end (MIN+SPAN, times shot_table.s's peak per-power-unit velocity) under
;; MAX_BALL_SPEED_8_8 below or a ball can jump through another in a frame;
;; tests/shot_test.py exercises hold times up to the cap.
SHOT_POWER_MIN   = 8
SHOT_POWER_SPAN  = 10
SHOT_CHARGE_STEP = 6

;; sys/collision.s: on a hit, velocities aren't just swapped (which is
;; already physically exact for an equal-mass elastic collision -- a full
;; hit stops the cue ball dead and sends the object ball off at exactly the
;; cue's speed) -- each is also boosted by (1 / 2^RESTITUTION_SHIFT), for a
;; more arcade "punch" than real physics gives. RESTITUTION_SHIFT=3 is
;; +12.5% per hit; smaller = bigger boost (2 -> +25%, 1 -> +50%, 0 -> +100%,
;; a full doubling every hit). sys_collision_amplify clamps the result to
;; MAX_BALL_SPEED_8_8 regardless of this value, so cranking it up can never
;; reintroduce the tunnelling risk the SHOT_POWER comment above warns
;; about, even after several compounding hits in one break -- but a very
;; aggressive value will still feel wrong (everything ends up pinned at the
;; speed limit), so treat the clamp as a safety net, not a licence to skip
;; retesting tests/collision_test.py after changing this.
RESTITUTION_SHIFT = 3

;; sys/collision.s's speed clamp (see RESITUTION_SHIFT above) and the
;; general "don't let a ball outrun its own width in one frame" tunnelling
;; limit. One px under BALL_HEIGHT_PX (config.h.s), the smaller of the
;; ball's two on-screen dimensions, so a full-speed ball can never clear
;; another ball's hitbox in a single physics step from any angle.
MAX_BALL_SPEED_8_8 = (BALL_HEIGHT_PX-1)*256

;; game/aim.s: cursor-key turn ramp, staged so a tap lands on exactly 1 of
;; the 256 directions (precise) while a long hold still spins at a usable
;; speed. tools/turn_model.py is the reference tests/turn_test.py checks
;; the real build against -- change the stages there first, then here.
;; AIM_TURN_Hn = frames continuously held before that stage's step
;; (AIM_TURN_Sn) applies; ascending, last one is the ceiling.
AIM_TURN_S0 = 1               ;; 0-19 held frames: 1 index/frame  (1.406 deg/frame)
AIM_TURN_H1 = 20
AIM_TURN_S1 = 2                ;; 20-44:           2 index/frame  (2.812 deg/frame)
AIM_TURN_H2 = 45
AIM_TURN_S2 = 4                ;; 45+ (ceiling):   4 index/frame  (5.625 deg/frame)

;; game/aim.s XOR trajectory line: dash spacing and total reach (their
;; product is the arc length in raw 8.8 direction-vector units).
;; tools/aim_model.py sizes these and checks the running accumulator never
;; overflows 16 bits for shot_table.s's widest direction -- re-run it after
;; changing either.
AIM_STEP_MULT    = 50
AIM_DASH_COUNT   = 6
