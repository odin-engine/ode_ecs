/*
    2025 (c) Oleh, https://github.com/zm69
*/
#+build !js
#+build !freestanding
#+private
package ode_ecs

// Core
    import "core:testing"

    @(test)
    uni_bits__test :: proc(t: ^testing.T) {
        bb : Uni_Bits 
        uni_bits__add(&bb, 3)
        uni_bits__add(&bb, 2)
        uni_bits__add(&bb, 78)
        
        testing.expect(t, uni_bits__exists(&bb, 3))
        testing.expect(t, uni_bits__exists(&bb, 2))
        testing.expect(t, uni_bits__exists(&bb, 78))

        uni_bits__remove(&bb, 5)
        uni_bits__remove(&bb, 3)

        testing.expect(t, uni_bits__exists(&bb, 3) == false)
        testing.expect(t, uni_bits__exists(&bb, 5) == false)
        testing.expect(t, uni_bits__exists(&bb, 2))
        testing.expect(t, uni_bits__exists(&bb, 78))

        aa := bb // copy 

        testing.expect(t, uni_bits__exists(&aa, 2))
        testing.expect(t, uni_bits__exists(&aa, 78))
        testing.expect(t, uni_bits__eq(&bb, &aa))
    
        uni_bits__add(&aa, 55)
        testing.expect(t, uni_bits__eq(&bb, &aa) == false)
        testing.expect(t, uni_bits__exists(&aa, 55))
    
        uni_bits__clear(&bb)
        testing.expect(t, uni_bits__exists(&bb, 2) == false)
        testing.expect(t, uni_bits__exists(&bb, 78) == false)
    }

    @(test)
    uni_bits__intersects__test :: proc(t: ^testing.T) {
        a, b, c: Uni_Bits
        uni_bits__add(&a, 2)
        uni_bits__add(&a, 3)
        uni_bits__add(&b, 3)
        uni_bits__add(&b, 78)
        uni_bits__add(&c, 5)

        testing.expect(t, uni_bits__intersects(&a, &b))        // share bit 3
        testing.expect(t, uni_bits__no_intersection(&a, &b) == false)
        testing.expect(t, uni_bits__intersects(&a, &c) == false) // no shared bits
        testing.expect(t, uni_bits__no_intersection(&a, &c))

        empty: Uni_Bits
        testing.expect(t, uni_bits__intersects(&empty, &a) == false) // empty set intersects nothing
    }

    @(test)
    bits__test :: proc(t: ^testing.T) {
        bb : Bits 
        bits__add(&bb, 3)
        bits__add(&bb, 2)
        bits__add(&bb, 78)
        
        testing.expect(t, bits__exists(&bb, 3))
        testing.expect(t, bits__exists(&bb, 2))
        testing.expect(t, bits__exists(&bb, 78))

        bits__remove(&bb, 5)
        bits__remove(&bb, 3)

        testing.expect(t, bits__exists(&bb, 3) == false)
        testing.expect(t, bits__exists(&bb, 5) == false)
        testing.expect(t, bits__exists(&bb, 2))
        testing.expect(t, bits__exists(&bb, 78))

        aa := bb // copy 

        testing.expect(t, bits__exists(&aa, 2))
        testing.expect(t, bits__exists(&aa, 78))
        testing.expect(t, bits__eq(&bb, &aa))
    
        bits__add(&aa, 55)
        testing.expect(t, bits__eq(&bb, &aa) == false)
        testing.expect(t, bits__exists(&aa, 55))
    
        bits__clear(&bb)
        testing.expect(t, bits__exists(&bb, 2) == false)
        testing.expect(t, bits__exists(&bb, 78) == false)
    }

    @(test)
    bits_arr__test :: proc(t: ^testing.T) {
        bb : Bits_Arr(3) 
        bits_arr__add(&bb, 3)
        bits_arr__add(&bb, 2)
        bits_arr__add(&bb, 378)
        
        testing.expect(t, bits_arr__exists(&bb, 3))
        testing.expect(t, bits_arr__exists(&bb, 2))
        testing.expect(t, bits_arr__exists(&bb, 378))

        bits_arr__remove(&bb, 5)
        bits_arr__remove(&bb, 3)

        testing.expect(t, bits_arr__exists(&bb, 3) == false)
        testing.expect(t, bits_arr__exists(&bb, 5) == false)
        testing.expect(t, bits_arr__exists(&bb, 2))
        testing.expect(t, bits_arr__exists(&bb, 378))

        aa := bb // copy 

        testing.expect(t, bits_arr__exists(&aa, 2))
        testing.expect(t, bits_arr__exists(&aa, 378))
        testing.expect(t, bits_arr__eq(&bb, &aa))
    
        bits_arr__add(&aa, 259)
        testing.expect(t, bits_arr__eq(&bb, &aa) == false)
        testing.expect(t, bits_arr__exists(&aa, 259))
    
        bits_arr__clear(&bb)
        testing.expect(t, bits_arr__exists(&bb, 2) == false)
        testing.expect(t, bits_arr__exists(&bb, 378) == false)
    }
