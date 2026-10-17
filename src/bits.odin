/*
    2025 (c) Oleh, https://github.com/zm69
*/
#+private
package ode_ecs

// Core

///////////////////////////////////////////////////////////////////////////////
// Bits

    
    bits__clear :: proc "contextless" (self: ^Bits) {
        self^ = {}
    }

    bits__add :: #force_inline proc "contextless" (self: ^Bits, #any_int value: int) {
        self^ += {value}
    }

    bits__remove :: #force_inline proc "contextless" (self: ^Bits, #any_int value: int) {
        self^ -= {value}
    }
    
    bits__exists :: #force_inline proc "contextless" (self: ^Bits, #any_int value: int) -> bool {
        return value in self 
    }

    bits__eq :: #force_inline proc "contextless" (a: ^Bits, b: ^Bits) -> bool {
        return a^ == b^ 
    }

    bits__is_subset ::  #force_inline proc "contextless" (a: ^Bits, b: ^Bits) -> bool {
        return a^ <= b^
    }

    bits__no_intersection :: #force_inline proc "contextless" (a: ^Bits, b: ^Bits) -> bool {
        return a^ & b^ == {}
    }

    bits__intersects :: #force_inline proc "contextless" (a: ^Bits, b: ^Bits) -> bool {
        return a^ & b^ != {}
    }

///////////////////////////////////////////////////////////////////////////////
// Bits_Arr

    Bits_Arr :: struct($N: int) {
        value: [N]bit_set[0..<BIT_SET_VALUES_CAP]
    }

    bits_arr__clear :: proc "contextless" (self: ^Bits_Arr($N)) {
        for i := 0; i < N; i += 1 do self.value[i] = {}
    }
    
    bits_arr__add :: proc "contextless" (self: ^Bits_Arr($N), #any_int value: int) {
        self.value[value / BIT_SET_VALUES_CAP] += {value % BIT_SET_VALUES_CAP}
    }

    bits_arr__remove :: proc "contextless" (self: ^Bits_Arr($N), #any_int value: int) {
        self.value[value / BIT_SET_VALUES_CAP] -= {value % BIT_SET_VALUES_CAP}
    }

    bits_arr__exists :: proc "contextless" (self: ^Bits_Arr($N), #any_int value: int) -> bool {
        return (value % BIT_SET_VALUES_CAP) in self.value[value / BIT_SET_VALUES_CAP]
    }

    bits_arr__eq :: proc (a: ^Bits_Arr($N), b: ^Bits_Arr($S)) -> bool {
        assert(N == S)
        for i:=0; i < N; i += 1 {
            if a.value[i] != b.value[i] do return false
        }

        return true
    }

    bits_arr__is_subset ::  #force_inline proc(a: ^Bits_Arr($N), b: ^Bits_Arr($S)) -> bool {
        assert(N == S)
        for i:=0; i < N; i += 1 {
            if !(a.value[i] <= b.value[i]) do return false
        }

        return true
    }

    bits_arr__no_intersection :: #force_inline proc (a: ^Bits_Arr($N), b: ^Bits_Arr($S)) -> bool {
        assert(N == S)
        for i:=0; i < N; i += 1 {
            if (a.value[i] & b.value[i]) != {} do return false
        }

        return true
    }

    bits_arr__intersects :: #force_inline proc (a: ^Bits_Arr($N), b: ^Bits_Arr($S)) -> bool {
        assert(N == S)
        for i:=0; i < N; i += 1 {
            if (a.value[i] & b.value[i]) != {} do return true
        }

        return false
    }

///////////////////////////////////////////////////////////////////////////////
// Uni_Bits

    when TABLES_MULT == 1 {
        Uni_Bits :: Bits
    } else {
        Uni_Bits :: Bits_Arr(TABLES_MULT)
    }   

    uni_bits__clear :: proc {
        bits__clear, 
        bits_arr__clear, 
    }

    uni_bits__add :: proc {
        bits__add,
        bits_arr__add,
    }

    uni_bits__remove :: proc {
        bits__remove,
        bits_arr__remove,
    }

    uni_bits__exists :: proc {
        bits__exists,
        bits_arr__exists,
    }

    uni_bits__eq :: proc {
        bits__eq,
        bits_arr__eq,
    }

    // a <= b
    uni_bits__is_subset :: proc {
        bits__is_subset,
        bits_arr__is_subset,
    }

    // a^ & b^ == {}
    uni_bits__no_intersection :: proc {
        bits__no_intersection,
        bits_arr__no_intersection,
    }

    // a^ & b^ != {}
    uni_bits__intersects :: proc {
        bits__intersects,
        bits_arr__intersects,
    }
