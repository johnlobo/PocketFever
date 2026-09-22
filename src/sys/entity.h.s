;; Ball entity pool. Generic enough to grow; sized for 9-ball + cue.
.module entity_system

.include "globals.inc"
.include "sys/component.inc"
.include "sys/struct.inc"

.macro DefineBall _id, _x, _y, _pen
    .db c_cmp_render
    .db _x
    .db _y
    .db _id
    .db _pen
.endm

BeginStruct e
Field e, cmps, 1
Field e, x, 1
Field e, y, 1
Field e, id, 1
Field e, color, 1
EndStruct e
