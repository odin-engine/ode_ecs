/*
    Ported to Odin from ckdl (https://github.com/tjol/ckdl)
    Original C implementation Copyright (c) Thomas Jollans (MIT License)

    KDL value and number types. Ported from ckdl's include/kdl/value.h.
    Odin tagged unions replace the C manual type-discriminant + union pairs:
    the active union case *is* the type, so there's no separate `type` field
    to keep in sync.
*/
package kdl

///////////////////////////////////////////////////////////////////////////////
// Value

    // An arbitrary-precision KDL number. i64/f64 for numbers that fit; string for
    // the rest (kept as decimal text, matching ckdl's KDL_NUMBER_TYPE_STRING_ENCODED).
    Number :: union {
        i64,
        f64,
        string,
    }

    // A KDL value, with its optional type annotation. A nil `variant` (the union's
    // zero value) represents KDL's `#null`.
    Value :: struct {
        type_annotation: Maybe(string), // nil means no annotation (distinct from an empty-string annotation, e.g. `("")`)
        variant:         union {
            bool,
            Number,
            string,
        },
    }

    is_null :: #force_inline proc(v: Value) -> bool {
        return v.variant == nil
    }
