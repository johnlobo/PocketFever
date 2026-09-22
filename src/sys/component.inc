;; Generic entity-component mask definitions.
c_cmp_invalid       = 0x00
c_cmp_render        = 0x01
c_cmp_movable       = 0x02
c_cmp_input         = 0x04
c_cmp_behavior      = 0x08
c_cmp_ai            = c_cmp_behavior
c_cmp_animated      = 0x10
c_cmp_collider      = 0x20
c_cmp_collisionable = 0x40
c_cmp_projectile    = 0x80
c_cmp_default       = c_cmp_render | c_cmp_movable | c_cmp_collider

x_cmps = 0           ;; component mask is the first byte of an entity

