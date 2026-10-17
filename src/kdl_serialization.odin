/*
    2026 (c) Oleh, https://github.com/zm69

    Human-readable KDL snapshot of a whole Database: a folder with one .kdl
    file per table plus _snapshot.kdl, the manifest listing every file that
    belongs to the snapshot. Component fields are written by reflection and
    matched by name on load (any order; a missing field loads as zero).

    Loading transcodes the folder into the binary snapshot format and hands
    it to database__deserialize, so both formats share one validation and
    apply path, with the same schema rules as serialization.odin.

    Native only: snapshots are folders on disk, and core:os doesn't exist on
    js/wasm.
*/
#+build !js
package ode_ecs

// Base
    import "base:runtime"

// Core
    import "core:math"
    import "core:mem/virtual"
    import "core:os"
    import "core:slice"
    import "core:strconv"
    import "core:strings"
    import "core:unicode/utf8"

// ODE
    import kdl "ode_kdl/src"

///////////////////////////////////////////////////////////////////////////////
// Format

    @(private)
    KDL_SNAPSHOT_VERSION :: i64(1)

    @(private)
    KDL_SNAPSHOT_MANIFEST :: "_snapshot.kdl"

    @(private)
    KDL_SNAPSHOT_ENTITIES :: "entities"

    @(private)
    KDL_SNAPSHOT_RELATIONS :: "relations"

    @(private)
    KDL_SNAPSHOT_EXT :: ".kdl"

    @(private)
    Kdl_File_Kind :: enum {
        Entities,
        Relations,
        Table,
        Tag,
        Pairs,
    }

    @(private)
    Kdl_File :: struct {
        kind: Kdl_File_Kind,
        id:   int,
        base: string,
        name: string,
    }

    @(private)
    Kdl_Manifest :: struct {
        entities_cap: int,
        files:        [dynamic]string,
    }

///////////////////////////////////////////////////////////////////////////////
// Document tree

    @(private)
    Kdl_Prop :: struct {
        name:  string,
        value: kdl.Value,
    }

    @(private)
    Kdl_Node :: struct {
        name:            string,
        type_annotation: Maybe(string),
        args:            [dynamic]kdl.Value,
        props:           [dynamic]Kdl_Prop,
        children:        [dynamic]^Kdl_Node,
    }

    @(private)
    kdl_snap__clone_value :: proc(v: kdl.Value, allocator: runtime.Allocator) -> kdl.Value {
        res: kdl.Value
        if ta, ok := v.type_annotation.?; ok do res.type_annotation = strings.clone(ta, allocator)

        switch x in v.variant {
            case bool:
                res.variant = x
            case kdl.Number:
                switch n in x {
                    case i64:    res.variant = kdl.Number(n)
                    case f64:    res.variant = kdl.Number(n)
                    case string: res.variant = kdl.Number(strings.clone(n, allocator))
                }
            case string:
                res.variant = strings.clone(x, allocator)
        }
        return res
    }

    @(private)
    kdl_snap__parse :: proc(text: string, allocator: runtime.Allocator) -> (nodes: [dynamic]^Kdl_Node, err: Error) {
        parser: kdl.Parser
        kdl.init(&parser, text, allocator = allocator)
        defer kdl.destroy(&parser)

        nodes = make([dynamic]^Kdl_Node, allocator)
        stack := make([dynamic]^Kdl_Node, allocator)

        for {
            ev := kdl.next_event(&parser)
            switch ev.type {
                case .EOF:
                    if len(stack) != 0 do return nodes, API_Error.Snapshot_Invalid
                    return nodes, nil
                case .Parse_Error:
                    return nodes, API_Error.Snapshot_Invalid
                case .Start_Node:
                    node := new(Kdl_Node, allocator)
                    node.name = strings.clone(ev.name, allocator)
                    if ta, ok := ev.value.type_annotation.?; ok do node.type_annotation = strings.clone(ta, allocator)
                    node.args = make([dynamic]kdl.Value, allocator)
                    node.props = make([dynamic]Kdl_Prop, allocator)
                    node.children = make([dynamic]^Kdl_Node, allocator)

                    if len(stack) > 0 {
                        append(&stack[len(stack) - 1].children, node)
                    } else {
                        append(&nodes, node)
                    }
                    append(&stack, node)
                case .End_Node:
                    if len(stack) == 0 do return nodes, API_Error.Snapshot_Invalid
                    pop(&stack)
                case .Argument:
                    if len(stack) == 0 do return nodes, API_Error.Snapshot_Invalid
                    append(&stack[len(stack) - 1].args, kdl_snap__clone_value(ev.value, allocator))
                case .Property:
                    if len(stack) == 0 do return nodes, API_Error.Snapshot_Invalid
                    append(&stack[len(stack) - 1].props, Kdl_Prop{
                        name  = strings.clone(ev.name, allocator),
                        value = kdl_snap__clone_value(ev.value, allocator),
                    })
                case .Comment:
            }
        }
    }

    @(private)
    kdl_snap__read_file :: proc(folder, name: string, allocator: runtime.Allocator) -> (nodes: [dynamic]^Kdl_Node, err: Error) {
        path := kdl_snap__path(folder, name, allocator) or_return
        data, rerr := os.read_entire_file(path, allocator)
        if rerr != nil do return nodes, API_Error.File_Error
        return kdl_snap__parse(string(data), allocator)
    }

    @(private)
    kdl_snap__prop :: proc(node: ^Kdl_Node, name: string) -> (kdl.Value, bool) {
        #reverse for p in node.props {
            if p.name == name do return p.value, true
        }
        return {}, false
    }

    @(private)
    kdl_snap__value_i64 :: proc(v: kdl.Value) -> (res: i64, ok: bool) {
        n := v.variant.(kdl.Number) or_return
        return n.(i64)
    }

    @(private)
    kdl_snap__value_str :: proc(v: kdl.Value) -> (string, bool) {
        return v.variant.(string)
    }

    @(private)
    kdl_snap__prop_i64 :: proc(node: ^Kdl_Node, name: string) -> (res: i64, ok: bool) {
        v := kdl_snap__prop(node, name) or_return
        return kdl_snap__value_i64(v)
    }

    @(private)
    kdl_snap__prop_str :: proc(node: ^Kdl_Node, name: string) -> (res: string, ok: bool) {
        v := kdl_snap__prop(node, name) or_return
        return kdl_snap__value_str(v)
    }

    @(private)
    kdl_snap__arg_eid :: proc(node: ^Kdl_Node, first: int) -> (eid: entity_id, ok: bool) {
        if len(node.args) < first + 2 do return
        ix := kdl_snap__value_i64(node.args[first]) or_return
        gen := kdl_snap__value_i64(node.args[first + 1]) or_return
        if ix < 0 || ix > i64(max(i32)) do return
        if gen < 0 || gen > i64(max(u32)) do return
        eid.ix = int(ix)
        eid.gen = uint(gen)
        return eid, true
    }

    @(private)
    kdl_snap__is_disabled_row :: proc(node: ^Kdl_Node) -> (disabled: bool, ok: bool) {
        ta, has := node.type_annotation.?
        if !has do return false, true
        return true, ta == "disabled"
    }

///////////////////////////////////////////////////////////////////////////////
// Output helpers

    @(private)
    kdl_snap__i64 :: #force_inline proc(v: i64) -> kdl.Value {
        return kdl.Value{ variant = kdl.Number(v) }
    }

    @(private)
    kdl_snap__str :: #force_inline proc(v: string) -> kdl.Value {
        return kdl.Value{ variant = v }
    }

    @(private)
    kdl_snap__bool :: #force_inline proc(v: bool) -> kdl.Value {
        return kdl.Value{ variant = v }
    }

    @(private)
    kdl_snap__emit_eid :: proc(em: ^kdl.Emitter, eid: entity_id) {
        kdl.emit_arg(em, kdl_snap__i64(i64(eid.ix)))
        kdl.emit_arg(em, kdl_snap__i64(i64(eid.gen)))
    }

    @(private)
    kdl_snap__row_node :: proc(em: ^kdl.Emitter, name: string, disabled: bool) {
        if disabled {
            kdl.emit_node_with_type(em, "disabled", name)
        } else {
            kdl.emit_node(em, name)
        }
    }

    @(private)
    kdl_snap__path :: proc(folder, name: string, allocator: runtime.Allocator) -> (string, Error) {
        path, err := os.join_path({folder, name}, allocator)
        if err != nil do return "", err
        return path, nil
    }

///////////////////////////////////////////////////////////////////////////////
// Names

    @(private)
    kdl_snap__short_name :: proc(ti: ^runtime.Type_Info) -> string {
        if ti == nil do return ""
        named, ok := ti.variant.(runtime.Type_Info_Named)
        if !ok do return ""
        return named.name
    }

    @(private)
    kdl_snap__full_name :: proc(ti: ^runtime.Type_Info, allocator: runtime.Allocator) -> string {
        if ti == nil do return ""
        named, ok := ti.variant.(runtime.Type_Info_Named)
        if !ok || len(named.name) == 0 do return ""
        if len(named.pkg) == 0 do return named.name
        return strings.concatenate({named.pkg, ".", named.name}, allocator)
    }

    // A missing or unnamed side matches, like snapshot__name_matches.
    @(private)
    kdl_snap__name_matches :: proc(node: ^Kdl_Node, prop: string, ti: ^runtime.Type_Info, allocator: runtime.Allocator) -> bool {
        name, has := kdl_snap__prop(node, prop)
        if !has do return true
        s, is_str := kdl_snap__value_str(name)
        if !is_str do return false
        expected := kdl_snap__full_name(ti, allocator)
        return len(expected) == 0 || len(s) == 0 || s == expected
    }

    @(private)
    kdl_snap__is_upper :: #force_inline proc(c: byte) -> bool { return c >= 'A' && c <= 'Z' }

    @(private)
    kdl_snap__is_lower_or_digit :: #force_inline proc(c: byte) -> bool { return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') }

    // File_Info -> file_infos, HTTPServer -> http_servers
    @(private)
    kdl_snap__snake_plural :: proc(name: string, allocator: runtime.Allocator) -> string {
        b := strings.builder_make(allocator)

        for i in 0..<len(name) {
            c := name[i]
            if kdl_snap__is_upper(c) {
                if i > 0 && name[i - 1] != '_' {
                    prev := name[i - 1]
                    next_lower := i + 1 < len(name) && name[i + 1] >= 'a' && name[i + 1] <= 'z'
                    if kdl_snap__is_lower_or_digit(prev) || (kdl_snap__is_upper(prev) && next_lower) {
                        strings.write_byte(&b, '_')
                    }
                }
                strings.write_byte(&b, c + ('a' - 'A'))
            } else if kdl_snap__is_lower_or_digit(c) || c == '_' || c >= 0x80 {
                strings.write_byte(&b, c)
            } else {
                strings.write_byte(&b, '_')
            }
        }

        s := strings.to_string(b)
        switch {
            case len(s) == 0:
                return "tables"
            case strings.has_suffix(s, "s"), strings.has_suffix(s, "x"), strings.has_suffix(s, "z"),
                 strings.has_suffix(s, "ch"), strings.has_suffix(s, "sh"):
                strings.write_string(&b, "es")
            case len(s) >= 2 && s[len(s) - 1] == 'y' && !strings.contains_rune("aeiou_", rune(s[len(s) - 2])):
                strings.pop_byte(&b)
                strings.write_string(&b, "ies")
            case:
                strings.write_byte(&b, 's')
        }
        return strings.to_string(b)
    }

    @(private)
    kdl_snap__is_reserved_base :: proc(base: string) -> bool {
        return base == KDL_SNAPSHOT_ENTITIES || base == KDL_SNAPSHOT_RELATIONS || base == "_snapshot"
    }

    // Plain *.kdl name inside the folder; keeps overwrite from deleting anything outside it.
    @(private)
    kdl_snap__is_safe_file_name :: proc(name: string) -> bool {
        if len(name) <= len(KDL_SNAPSHOT_EXT) do return false
        if !strings.has_suffix(name, KDL_SNAPSHOT_EXT) do return false
        if name == KDL_SNAPSHOT_MANIFEST do return false
        if name[0] == '.' do return false
        for i in 0..<len(name) {
            c := name[i]
            if c == '/' || c == '\\' || c == ':' || c < 0x20 do return false
        }
        return true
    }

    @(private)
    kdl_snap__table_type_name :: proc(type: Table_Type) -> string {
        switch type {
            case .Auto:          return "Auto"
            case .Table:         return "Table"
            case .Tiny_Table:    return "Tiny_Table"
            case .Compact_Table: return "Compact_Table"
            case .Tag_Table:     return "Tag_Table"
            case .Arch_Table:    return "Arch_Table"
            case .Flags_Table:   return "Flags_Table"
        }
        return ""
    }

    @(private)
    kdl_snap__table_type_parse :: proc(s: string) -> (Table_Type, bool) {
        for type in Table_Type {
            if type != .Auto && kdl_snap__table_type_name(type) == s do return type, true
        }
        return .Auto, false
    }

    @(private)
    kdl_snap__plan_files :: proc(self: ^Database, allocator: runtime.Allocator) -> [dynamic]Kdl_File {
        files := make([dynamic]Kdl_File, allocator)

        if self.owns_overbase {
            append(&files, Kdl_File{ kind = .Entities, base = KDL_SNAPSHOT_ENTITIES, name = KDL_SNAPSHOT_ENTITIES + KDL_SNAPSHOT_EXT })
        }

        for table in self.tables.items {
            if table == nil do continue
            base: string
            if table.type == .Arch_Table {
                base = "archetypes"
            } else if table.type == .Flags_Table {
                base = "flags"
            } else {
                base = kdl_snap__snake_plural(kdl_snap__short_name(shared_table__type_info(table)), allocator)
            }
            append(&files, Kdl_File{ kind = .Table, id = int(table.id), base = base })
        }

        for tag in self.tag_tables.items {
            if tag == nil do continue
            append(&files, Kdl_File{ kind = .Tag, id = int(tag.id), base = "tags" })
        }

        for pt in self.pair_tables.items {
            if pt == nil do continue
            base := "pairs"
            short := kdl_snap__short_name(pt.data_type_info)
            if pt.data_type_info.size > 0 && len(short) > 0 do base = kdl_snap__snake_plural(short, allocator)
            append(&files, Kdl_File{ kind = .Pairs, id = int(pt.id), base = base })
        }

        if self.relations != nil && self.relations.state == Object_State.Normal {
            append(&files, Kdl_File{ kind = .Relations, base = KDL_SNAPSHOT_RELATIONS, name = KDL_SNAPSHOT_RELATIONS + KDL_SNAPSHOT_EXT })
        }

        counts := make(map[string]int, allocator)
        for f in files {
            if f.kind == .Table || f.kind == .Tag || f.kind == .Pairs do counts[f.base] += 1
        }

        seen := make(map[string]int, allocator)
        for &f in files {
            if len(f.name) > 0 do continue
            if counts[f.base] > 1 || kdl_snap__is_reserved_base(f.base) {
                seen[f.base] += 1
                buf: [32]byte
                num := strconv.write_int(buf[:], i64(seen[f.base]), 10)
                f.name = strings.concatenate({f.base, num, KDL_SNAPSHOT_EXT}, allocator)
            } else {
                f.name = strings.concatenate({f.base, KDL_SNAPSHOT_EXT}, allocator)
            }
        }

        return files
    }

///////////////////////////////////////////////////////////////////////////////
// Value reflection

    @(private)
    Kdl_Kind :: enum {
        Single,     // one KDL value: integer, float, bool, rune, enum
        Hex,        // one KDL value, (hex)"..." bytes: unions, complex, matrix, simd, raw unions
        Struct,     // child node: fields as properties / child nodes
        Bit_Field,  // child node: fields as properties
        Array,      // child node: scalar elements as args, compound elements as `item` children
        Bit_Set,    // child node: members as args
    }

    @(private)
    kdl_snap__kind :: proc(ti: ^runtime.Type_Info) -> Kdl_Kind {
        #partial switch v in runtime.type_info_base(ti).variant {
            case runtime.Type_Info_Integer, runtime.Type_Info_Float, runtime.Type_Info_Boolean,
                 runtime.Type_Info_Rune, runtime.Type_Info_Enum:
                return .Single
            case runtime.Type_Info_Struct:
                if .raw_union in v.flags || v.soa_kind != .None do return .Hex
                return .Struct
            case runtime.Type_Info_Bit_Field:
                return .Bit_Field
            case runtime.Type_Info_Array, runtime.Type_Info_Enumerated_Array:
                return .Array
            case runtime.Type_Info_Bit_Set:
                return .Bit_Set
        }
        return .Hex
    }

    @(private)
    kdl_snap__is_single :: #force_inline proc(ti: ^runtime.Type_Info) -> bool {
        k := kdl_snap__kind(ti)
        return k == .Single || k == .Hex
    }

    @(private)
    kdl_snap__is_big_endian :: proc(ti: ^runtime.Type_Info) -> bool {
        e := runtime.Platform_Endianness.Platform
        #partial switch v in runtime.type_info_base(ti).variant {
            case runtime.Type_Info_Integer: e = v.endianness
            case runtime.Type_Info_Float:   e = v.endianness
            case runtime.Type_Info_Enum:    return kdl_snap__is_big_endian(v.base)
        }
        return e == .Big || (e == .Platform && ODIN_ENDIAN == .Big)
    }

    @(private)
    kdl_snap__is_signed :: proc(ti: ^runtime.Type_Info) -> bool {
        #partial switch v in runtime.type_info_base(ti).variant {
            case runtime.Type_Info_Integer: return v.signed
            case runtime.Type_Info_Rune:    return true
            case runtime.Type_Info_Enum:    return kdl_snap__is_signed(v.base)
        }
        return false
    }

    @(private)
    kdl_snap__read_uint :: proc(ptr: rawptr, size: int, big: bool) -> u128 {
        b := ([^]byte)(ptr)
        x: u128
        for i in 0..<size {
            x = (x << 8) | u128(big ? b[i] : b[size - 1 - i])
        }
        return x
    }

    @(private)
    kdl_snap__write_uint :: proc(ptr: rawptr, size: int, big: bool, x: u128) {
        b := ([^]byte)(ptr)
        for i in 0..<size {
            v := byte(x >> uint(8 * i))
            if big {
                b[size - 1 - i] = v
            } else {
                b[i] = v
            }
        }
    }

    @(private)
    kdl_snap__mask :: #force_inline proc(bits: int) -> u128 {
        if bits >= 128 do return max(u128)
        return (u128(1) << uint(bits)) - 1
    }

    @(private)
    kdl_snap__sign_extend :: proc(x: u128, bits: int) -> i128 {
        if bits >= 128 || bits <= 0 do return i128(x)
        shift := uint(128 - bits)
        return i128(x << shift) >> shift
    }

    @(private)
    kdl_snap__decimal :: proc(neg: bool, mag: u128, allocator: runtime.Allocator) -> string {
        buf: [48]byte
        i := len(buf)
        m := mag
        for {
            i -= 1
            buf[i] = '0' + byte(m % 10)
            m /= 10
            if m == 0 do break
        }
        if neg {
            i -= 1
            buf[i] = '-'
        }
        return strings.clone(string(buf[i:]), allocator)
    }

    @(private)
    kdl_snap__int_value :: proc(x: u128, signed: bool, bits: int, allocator: runtime.Allocator) -> kdl.Value {
        if signed {
            v := kdl_snap__sign_extend(x & kdl_snap__mask(bits), bits)
            if v >= i128(min(i64)) && v <= i128(max(i64)) do return kdl_snap__i64(i64(v))
            if v < 0 do return kdl.Value{ variant = kdl.Number(kdl_snap__decimal(true, ~u128(v) + 1, allocator)) }
            return kdl.Value{ variant = kdl.Number(kdl_snap__decimal(false, u128(v), allocator)) }
        }
        m := x & kdl_snap__mask(bits)
        if m <= u128(max(i64)) do return kdl_snap__i64(i64(m))
        return kdl.Value{ variant = kdl.Number(kdl_snap__decimal(false, m, allocator)) }
    }

    @(private)
    kdl_snap__value_int :: proc(v: kdl.Value) -> (neg: bool, mag: u128, ok: bool) {
        n := v.variant.(kdl.Number) or_return
        switch x in n {
            case i64:
                if x < 0 do return true, ~u128(i128(x)) + 1, true
                return false, u128(x), true
            case string:
                s := x
                if len(s) > 0 && (s[0] == '-' || s[0] == '+') {
                    neg = s[0] == '-'
                    s = s[1:]
                }
                if len(s) == 0 do return
                for i in 0..<len(s) {
                    if (s[i] < '0' || s[i] > '9') && s[i] != '_' do return
                }
                mag, ok = strconv.parse_u128_of_base(s, 10)
                return
            case f64:
        }
        return
    }

    // Two's-complement bits of (neg, mag) if it fits in `bits`.
    @(private)
    kdl_snap__int_fit :: proc(neg: bool, mag: u128, signed: bool, bits: int) -> (x: u128, ok: bool) {
        if signed {
            limit := u128(1) << uint(bits - 1)
            if neg {
                if mag > limit do return
                return ~mag + 1, true
            }
            if mag >= limit do return
            return mag, true
        }
        if neg && mag != 0 do return
        if bits < 128 && mag > kdl_snap__mask(bits) do return
        return mag, true
    }

    @(private)
    kdl_snap__read_float :: proc(ptr: rawptr, size: int, big: bool) -> f64 {
        x := kdl_snap__read_uint(ptr, size, big)
        switch size {
            case 2: return f64(transmute(f16) u16(x))
            case 4: return f64(transmute(f32) u32(x))
            case 8: return transmute(f64) u64(x)
        }
        return 0
    }

    @(private)
    kdl_snap__write_float :: proc(ptr: rawptr, size: int, big: bool, f: f64) {
        x: u128
        switch size {
            case 2: x = u128(transmute(u16) f16(f))
            case 4: x = u128(transmute(u32) f32(f))
            case 8: x = u128(transmute(u64) f)
        }
        kdl_snap__write_uint(ptr, size, big, x)
    }

    // Shortest f32 text when it round-trips exactly, else the f64 formatter.
    @(private)
    kdl_snap__f32_value :: proc(f: f32, allocator: runtime.Allocator) -> kdl.Value {
        if math.is_nan(f) || math.is_inf(f) do return kdl.Value{ variant = kdl.Number(f64(f)) }

        buf: [64]byte
        s := strconv.write_float(buf[:], f64(f), 'g', -1, 32)
        if len(s) > 0 && s[0] == '+' do s = s[1:]

        parsed, ok := strconv.parse_f64(s)
        if !ok || f32(parsed) != f do return kdl.Value{ variant = kdl.Number(f64(f)) }

        if strings.index_any(s, ".eE") < 0 do return kdl.Value{ variant = kdl.Number(strings.concatenate({s, ".0"}, allocator)) }
        return kdl.Value{ variant = kdl.Number(strings.clone(s, allocator)) }
    }

    @(private)
    kdl_snap__value_f64 :: proc(v: kdl.Value) -> (f: f64, ok: bool) {
        n := v.variant.(kdl.Number) or_return
        switch x in n {
            case f64:    return x, true
            case i64:    return f64(x), true
            case string: return strconv.parse_f64(x)
        }
        return
    }

    @(private)
    kdl_snap__enum_name :: proc(e: runtime.Type_Info_Enum, value: i64) -> (string, bool) {
        for ev, i in e.values {
            if i64(ev) == value do return e.names[i], true
        }
        return "", false
    }

    @(private)
    kdl_snap__enum_value :: proc(e: runtime.Type_Info_Enum, name: string) -> (i64, bool) {
        for n, i in e.names {
            if n == name do return i64(e.values[i]), true
        }
        return 0, false
    }

    @(private)
    kdl_snap__hex_value :: proc(ptr: rawptr, size: int, allocator: runtime.Allocator) -> kdl.Value {
        HEX := "0123456789abcdef"
        b := ([^]byte)(ptr)
        out := make([]byte, size * 2, allocator)
        for i in 0..<size {
            out[i * 2] = HEX[b[i] >> 4]
            out[i * 2 + 1] = HEX[b[i] & 0xF]
        }
        return kdl.Value{ type_annotation = "hex", variant = string(out) }
    }

    @(private)
    kdl_snap__hex_digit :: proc(c: byte) -> (byte, bool) {
        switch c {
            case '0'..='9': return c - '0', true
            case 'a'..='f': return c - 'a' + 10, true
            case 'A'..='F': return c - 'A' + 10, true
        }
        return 0, false
    }

    @(private)
    kdl_snap__encode_single :: proc(ti: ^runtime.Type_Info, ptr: rawptr, allocator: runtime.Allocator) -> kdl.Value {
        base := runtime.type_info_base(ti)
        big := kdl_snap__is_big_endian(ti)

        #partial switch v in base.variant {
            case runtime.Type_Info_Integer:
                return kdl_snap__int_value(kdl_snap__read_uint(ptr, base.size, big), v.signed, base.size * 8, allocator)
            case runtime.Type_Info_Float:
                f := kdl_snap__read_float(ptr, base.size, big)
                if base.size == 4 do return kdl_snap__f32_value(f32(f), allocator)
                return kdl.Value{ variant = kdl.Number(f) }
            case runtime.Type_Info_Boolean:
                return kdl_snap__bool(kdl_snap__read_uint(ptr, base.size, big) != 0)
            case runtime.Type_Info_Rune:
                r := rune(kdl_snap__sign_extend(kdl_snap__read_uint(ptr, base.size, big), 32))
                if r >= 0x20 && r != 0x7F && utf8.valid_rune(r) {
                    return kdl_snap__str(utf8.runes_to_string({r}, allocator))
                }
                return kdl_snap__i64(i64(r))
            case runtime.Type_Info_Enum:
                bsize := runtime.type_info_base(v.base).size
                x := kdl_snap__read_uint(ptr, bsize, big)
                value := i64(kdl_snap__sign_extend(x, kdl_snap__is_signed(v.base) ? bsize * 8 : 128))
                if name, ok := kdl_snap__enum_name(v, value); ok do return kdl_snap__str(name)
                return kdl_snap__int_value(x, kdl_snap__is_signed(v.base), bsize * 8, allocator)
        }

        return kdl_snap__hex_value(ptr, base.size, allocator)
    }

    @(private)
    kdl_snap__decode_int :: proc(v: kdl.Value, ptr: rawptr, size: int, signed, big: bool) -> bool {
        neg, mag := kdl_snap__value_int(v) or_return
        x := kdl_snap__int_fit(neg, mag, signed, size * 8) or_return
        kdl_snap__write_uint(ptr, size, big, x)
        return true
    }

    @(private)
    kdl_snap__decode_single :: proc(v: kdl.Value, ti: ^runtime.Type_Info, ptr: rawptr) -> bool {
        base := runtime.type_info_base(ti)
        big := kdl_snap__is_big_endian(ti)

        #partial switch info in base.variant {
            case runtime.Type_Info_Integer:
                return kdl_snap__decode_int(v, ptr, base.size, info.signed, big)
            case runtime.Type_Info_Float:
                f := kdl_snap__value_f64(v) or_return
                kdl_snap__write_float(ptr, base.size, big, f)
                return true
            case runtime.Type_Info_Boolean:
                b := v.variant.(bool) or_return
                kdl_snap__write_uint(ptr, base.size, big, b ? 1 : 0)
                return true
            case runtime.Type_Info_Rune:
                if s, is_str := v.variant.(string); is_str {
                    if utf8.rune_count_in_string(s) != 1 do return false
                    r, _ := utf8.decode_rune_in_string(s)
                    if r == utf8.RUNE_ERROR do return false
                    kdl_snap__write_uint(ptr, base.size, big, u128(u32(r)))
                    return true
                }
                return kdl_snap__decode_int(v, ptr, base.size, true, big)
            case runtime.Type_Info_Enum:
                bsize := runtime.type_info_base(info.base).size
                signed := kdl_snap__is_signed(info.base)
                if s, is_str := v.variant.(string); is_str {
                    value := kdl_snap__enum_value(info, s) or_return
                    kdl_snap__write_uint(ptr, bsize, big, u128(i128(value)))
                    return true
                }
                return kdl_snap__decode_int(v, ptr, bsize, signed, big)
        }

        s := v.variant.(string) or_return
        if len(s) != base.size * 2 do return false
        b := ([^]byte)(ptr)
        for i in 0..<base.size {
            hi := kdl_snap__hex_digit(s[i * 2]) or_return
            lo := kdl_snap__hex_digit(s[i * 2 + 1]) or_return
            b[i] = hi << 4 | lo
        }
        return true
    }

    @(private)
    kdl_snap__array_info :: proc(ti: ^runtime.Type_Info) -> (elem: ^runtime.Type_Info, elem_size: int, count: int) {
        #partial switch v in runtime.type_info_base(ti).variant {
            case runtime.Type_Info_Array:            return v.elem, v.elem_size, v.count
            case runtime.Type_Info_Enumerated_Array: return v.elem, v.elem_size, v.count
        }
        return nil, 0, 0
    }

    @(private)
    kdl_snap__bit_set_member :: proc(bs: runtime.Type_Info_Bit_Set, value: i64, allocator: runtime.Allocator) -> kdl.Value {
        #partial switch e in runtime.type_info_base(bs.elem).variant {
            case runtime.Type_Info_Enum:
                if name, ok := kdl_snap__enum_name(e, value); ok do return kdl_snap__str(name)
            case runtime.Type_Info_Rune:
                r := rune(value)
                if r >= 0x20 && r != 0x7F && utf8.valid_rune(r) do return kdl_snap__str(utf8.runes_to_string({r}, allocator))
        }
        return kdl_snap__i64(value)
    }

    @(private)
    kdl_snap__bit_set_value :: proc(bs: runtime.Type_Info_Bit_Set, v: kdl.Value) -> (value: i64, ok: bool) {
        if s, is_str := v.variant.(string); is_str {
            #partial switch e in runtime.type_info_base(bs.elem).variant {
                case runtime.Type_Info_Enum:
                    return kdl_snap__enum_value(e, s)
                case runtime.Type_Info_Rune:
                    if utf8.rune_count_in_string(s) != 1 do return
                    r, _ := utf8.decode_rune_in_string(s)
                    return i64(r), r != utf8.RUNE_ERROR
            }
            return
        }
        return kdl_snap__value_i64(v)
    }

    // Writes `ti` at `ptr` into the node the emitter is currently on (its name and leading args already out).
    @(private)
    kdl_snap__emit_content :: proc(em: ^kdl.Emitter, ti: ^runtime.Type_Info, ptr: rawptr, allocator: runtime.Allocator) {
        base := runtime.type_info_base(ti)

        switch kdl_snap__kind(ti) {
            case .Single, .Hex:
                kdl.emit_arg(em, kdl_snap__encode_single(ti, ptr, allocator))

            case .Struct:
                s := base.variant.(runtime.Type_Info_Struct)
                has_children := false
                for i in 0..<int(s.field_count) {
                    if s.names[i] == "_" do continue
                    if !kdl_snap__is_single(s.types[i]) {
                        has_children = true
                        continue
                    }
                    fp := rawptr(uintptr(ptr) + s.offsets[i])
                    kdl.emit_property(em, s.names[i], kdl_snap__encode_single(s.types[i], fp, allocator))
                }
                if has_children {
                    kdl.start_emitting_children(em)
                    for i in 0..<int(s.field_count) {
                        if s.names[i] == "_" || kdl_snap__is_single(s.types[i]) do continue
                        kdl.emit_node(em, s.names[i])
                        kdl_snap__emit_content(em, s.types[i], rawptr(uintptr(ptr) + s.offsets[i]), allocator)
                    }
                    kdl.finish_emitting_children(em)
                }

            case .Bit_Field:
                bf := base.variant.(runtime.Type_Info_Bit_Field)
                raw := kdl_snap__read_uint(ptr, base.size, kdl_snap__is_big_endian(bf.backing_type))
                for i in 0..<bf.field_count {
                    if bf.names[i] == "_" do continue
                    ft := bf.types[i]
                    bits := int(bf.bit_sizes[i])
                    x := (raw >> bf.bit_offsets[i]) & kdl_snap__mask(bits)
                    if kdl_snap__is_signed(ft) do x = u128(kdl_snap__sign_extend(x, bits))
                    tmp: [16]byte
                    kdl_snap__write_uint(&tmp, min(ft.size, len(tmp)), kdl_snap__is_big_endian(ft), x)
                    kdl.emit_property(em, bf.names[i], kdl_snap__encode_single(ft, &tmp, allocator))
                }

            case .Array:
                elem, elem_size, count := kdl_snap__array_info(ti)
                if kdl_snap__is_single(elem) {
                    for i in 0..<count {
                        kdl.emit_arg(em, kdl_snap__encode_single(elem, rawptr(uintptr(ptr) + uintptr(i * elem_size)), allocator))
                    }
                } else if count > 0 {
                    kdl.start_emitting_children(em)
                    for i in 0..<count {
                        kdl.emit_node(em, "item")
                        kdl_snap__emit_content(em, elem, rawptr(uintptr(ptr) + uintptr(i * elem_size)), allocator)
                    }
                    kdl.finish_emitting_children(em)
                }

            case .Bit_Set:
                bs := base.variant.(runtime.Type_Info_Bit_Set)
                b := ([^]byte)(ptr)
                for i in 0..<int(bs.upper - bs.lower + 1) {
                    if i / 8 >= base.size do break
                    if b[i / 8] & (1 << uint(i % 8)) == 0 do continue
                    kdl.emit_arg(em, kdl_snap__bit_set_member(bs, bs.lower + i64(i), allocator))
                }
        }
    }

    @(private)
    kdl_snap__struct_field :: proc(s: runtime.Type_Info_Struct, name: string) -> int {
        if name == "_" do return -1
        for i in 0..<int(s.field_count) {
            if s.names[i] == name do return i
        }
        return -1
    }

    // Mirror of kdl_snap__emit_content; `ptr` must be zeroed, so absent fields stay zero.
    @(private)
    kdl_snap__decode_content :: proc(node: ^Kdl_Node, first_arg: int, ti: ^runtime.Type_Info, ptr: rawptr) -> Error {
        base := runtime.type_info_base(ti)
        if first_arg > len(node.args) do return API_Error.Snapshot_Invalid
        args := node.args[first_arg:]

        switch kdl_snap__kind(ti) {
            case .Single, .Hex:
                if len(node.props) > 0 || len(node.children) > 0 || len(args) > 1 do return API_Error.Snapshot_Invalid
                if len(args) == 1 && !kdl_snap__decode_single(args[0], ti, ptr) do return API_Error.Snapshot_Invalid

            case .Struct:
                if len(args) > 0 do return API_Error.Snapshot_Invalid
                s := base.variant.(runtime.Type_Info_Struct)
                for p in node.props {
                    i := kdl_snap__struct_field(s, p.name)
                    if i < 0 || !kdl_snap__is_single(s.types[i]) do return API_Error.Snapshot_Invalid
                    if !kdl_snap__decode_single(p.value, s.types[i], rawptr(uintptr(ptr) + s.offsets[i])) do return API_Error.Snapshot_Invalid
                }
                for c in node.children {
                    i := kdl_snap__struct_field(s, c.name)
                    if i < 0 || kdl_snap__is_single(s.types[i]) do return API_Error.Snapshot_Invalid
                    kdl_snap__decode_content(c, 0, s.types[i], rawptr(uintptr(ptr) + s.offsets[i])) or_return
                }

            case .Bit_Field:
                if len(args) > 0 || len(node.children) > 0 do return API_Error.Snapshot_Invalid
                bf := base.variant.(runtime.Type_Info_Bit_Field)
                big := kdl_snap__is_big_endian(bf.backing_type)
                raw := kdl_snap__read_uint(ptr, base.size, big)
                for p in node.props {
                    i := -1
                    for j in 0..<bf.field_count {
                        if bf.names[j] == p.name && p.name != "_" do i = j
                    }
                    if i < 0 do return API_Error.Snapshot_Invalid

                    ft := bf.types[i]
                    if ft.size > 16 do return API_Error.Snapshot_Invalid
                    tmp: [16]byte
                    if !kdl_snap__decode_single(p.value, ft, &tmp) do return API_Error.Snapshot_Invalid

                    bits := int(bf.bit_sizes[i])
                    x := kdl_snap__read_uint(&tmp, ft.size, kdl_snap__is_big_endian(ft))
                    field := x & kdl_snap__mask(bits)
                    if kdl_snap__is_signed(ft) {
                        if kdl_snap__sign_extend(field, bits) != kdl_snap__sign_extend(x, ft.size * 8) do return API_Error.Snapshot_Invalid
                    } else if field != x {
                        return API_Error.Snapshot_Invalid
                    }

                    off := bf.bit_offsets[i]
                    raw = (raw &~ (kdl_snap__mask(bits) << off)) | (field << off)
                }
                kdl_snap__write_uint(ptr, base.size, big, raw)

            case .Array:
                if len(node.props) > 0 do return API_Error.Snapshot_Invalid
                elem, elem_size, count := kdl_snap__array_info(ti)
                if kdl_snap__is_single(elem) {
                    if len(node.children) > 0 || len(args) > count do return API_Error.Snapshot_Invalid
                    for a, i in args {
                        if !kdl_snap__decode_single(a, elem, rawptr(uintptr(ptr) + uintptr(i * elem_size))) do return API_Error.Snapshot_Invalid
                    }
                } else {
                    if len(args) > 0 || len(node.children) > count do return API_Error.Snapshot_Invalid
                    for c, i in node.children {
                        if c.name != "item" do return API_Error.Snapshot_Invalid
                        kdl_snap__decode_content(c, 0, elem, rawptr(uintptr(ptr) + uintptr(i * elem_size))) or_return
                    }
                }

            case .Bit_Set:
                if len(node.props) > 0 || len(node.children) > 0 do return API_Error.Snapshot_Invalid
                bs := base.variant.(runtime.Type_Info_Bit_Set)
                b := ([^]byte)(ptr)
                for a in args {
                    value, ok := kdl_snap__bit_set_value(bs, a)
                    if !ok || value < bs.lower || value > bs.upper do return API_Error.Snapshot_Invalid
                    i := int(value - bs.lower)
                    if i / 8 >= base.size do return API_Error.Snapshot_Invalid
                    b[i / 8] |= 1 << uint(i % 8)
                }
        }

        return nil
    }

///////////////////////////////////////////////////////////////////////////////
// Save

    @(private)
    kdl_snap__check_pod :: proc(self: ^Database) -> Error {
        for table in self.tables.items {
            if table == nil do continue
            if table.type == .Arch_Table {
                for col in (cast(^Arch_Table) table).columns {
                    if !snapshot__type_is_pod(col.type_info) do return API_Error.Snapshot_Component_Not_POD
                }
            } else {
                ti := shared_table__type_info(table)
                if ti != nil && !snapshot__type_is_pod(ti) do return API_Error.Snapshot_Component_Not_POD
            }
        }
        for pt in self.pair_tables.items {
            if pt == nil || pt.data_type_info.size == 0 do continue
            if !snapshot__type_is_pod(pt.data_type_info) do return API_Error.Snapshot_Component_Not_POD
        }
        return nil
    }

    @(private)
    kdl_snap__read_manifest :: proc(folder: string, allocator: runtime.Allocator) -> (m: Kdl_Manifest, err: Error) {
        nodes := kdl_snap__read_file(folder, KDL_SNAPSHOT_MANIFEST, allocator) or_return
        if len(nodes) == 0 || nodes[0].name != "ode_ecs_snapshot" do return m, API_Error.Snapshot_Invalid

        version, has_version := kdl_snap__prop_i64(nodes[0], "version")
        if !has_version do return m, API_Error.Snapshot_Invalid
        if version != KDL_SNAPSHOT_VERSION do return m, API_Error.Snapshot_Version_Mismatch

        m.files = make([dynamic]string, allocator)
        m.entities_cap = -1
        for node in nodes[1:] {
            switch node.name {
                case "entities_cap":
                    if len(node.args) != 1 do return m, API_Error.Snapshot_Invalid
                    cap, ok := kdl_snap__value_i64(node.args[0])
                    if !ok || cap <= 0 || cap > i64(max(u32)) do return m, API_Error.Snapshot_Invalid
                    m.entities_cap = int(cap)
                case "file":
                    if len(node.args) != 1 do return m, API_Error.Snapshot_Invalid
                    name, ok := kdl_snap__value_str(node.args[0])
                    if !ok || !kdl_snap__is_safe_file_name(name) do return m, API_Error.Snapshot_Invalid
                    for f in m.files {
                        if f == name do return m, API_Error.Snapshot_Invalid
                    }
                    append(&m.files, name)
                case:
                    return m, API_Error.Snapshot_Invalid
            }
        }
        if m.entities_cap < 0 do return m, API_Error.Snapshot_Invalid

        return m, nil
    }

    @(private)
    kdl_snap__table_row :: proc(table: ^Shared_Table, rid: int, size: int) -> (eid: entity_id, ptr: rawptr) {
        #partial switch table.type {
            case .Table:
                raw := cast(^Table_Raw) table
                return raw.rid_to_eid[rid], rawptr(uintptr(raw_data(raw.rows)) + uintptr(rid * size))
            case .Compact_Table, .Flags_Table:
                raw := cast(^Compact_Table_Raw) table
                return raw.rid_to_eid[rid], rawptr(uintptr(raw_data(raw.rows)) + uintptr(rid * size))
            case .Tiny_Table:
                raw := cast(^Tiny_Table_Raw) table
                return raw.rid_to_eid[rid], rawptr(uintptr(&raw.rows[0]) + uintptr(rid * size))
        }
        return {}, nil
    }

    @(private)
    kdl_snap__emit_table :: proc(self: ^Database, em: ^kdl.Emitter, table: ^Shared_Table, arena: ^virtual.Arena) {
        scratch := virtual.arena_allocator(arena)
        n := shared_table__snapshot_len(table)
        ti := shared_table__type_info(table)

        kdl.emit_node(em, "table")
        kdl.emit_property(em, "id", kdl_snap__i64(i64(table.id)))
        kdl.emit_property(em, "type", kdl_snap__str(kdl_snap__table_type_name(table.type)))
        if name := kdl_snap__full_name(ti, scratch); len(name) > 0 {
            kdl.emit_property(em, "component", kdl_snap__str(name))
        }
        kdl.emit_property(em, "cap", kdl_snap__i64(i64(shared_table__cap(table))))

        if table.type == .Arch_Table {
            at := cast(^Arch_Table) table
            for col in at.columns {
                kdl.emit_node(em, "column")
                kdl.emit_arg(em, kdl_snap__str(kdl_snap__full_name(col.type_info, scratch)))
            }
        }

        is_tag := table.type == .Tag_Table
        disabled_bits := is_tag ? self.eid_to_tag_disabled_bits : self.eid_to_disabled_bits

        for rid in 0..<n {
            temp := virtual.arena_temp_begin(arena)
            defer virtual.arena_temp_end(temp)

            eid: entity_id
            ptr: rawptr
            #partial switch table.type {
                case .Tag_Table:
                    eid = (cast(^Tag_Table) table).rows[rid]
                case .Arch_Table:
                    eid = (cast(^Arch_Table) table).rid_to_eid[rid]
                case:
                    eid, ptr = kdl_snap__table_row(table, rid, ti.size)
            }

            disabled := disabled_bits != nil && uni_bits__exists(&disabled_bits[eid.ix], table.id)
            kdl_snap__row_node(em, "row", disabled)
            kdl_snap__emit_eid(em, eid)

            #partial switch table.type {
                case .Tag_Table:
                case .Arch_Table:
                    at := cast(^Arch_Table) table
                    if len(at.columns) > 0 {
                        kdl.start_emitting_children(em)
                        for col in at.columns {
                            short := kdl_snap__short_name(col.type_info)
                            kdl.emit_node(em, len(short) > 0 ? short : "column")
                            kdl_snap__emit_content(em, col.type_info, rawptr(uintptr(raw_data(col.rows)) + uintptr(rid * col.type_info.size)), scratch)
                        }
                        kdl.finish_emitting_children(em)
                    }
                case:
                    kdl_snap__emit_content(em, ti, ptr, scratch)
            }
        }
    }

    @(private)
    kdl_snap__emit_entities :: proc(self: ^Database, em: ^kdl.Emitter) {
        f := &self.overbase.id_factory

        kdl.emit_node(em, "entities")
        kdl.emit_property(em, "cap", kdl_snap__i64(i64(f.cap)))
        kdl.emit_property(em, "created", kdl_snap__i64(i64(f.created_count)))

        for i in 0..<f.cap {
            item := f.items[i]
            free := item.ix == DELETED_INDEX
            if i >= f.created_count && free && item.gen == 0 do continue

            kdl.emit_node(em, "slot")
            kdl.emit_arg(em, kdl_snap__i64(i64(i)))
            kdl.emit_property(em, "gen", kdl_snap__i64(i64(item.gen)))
            if free do kdl.emit_property(em, "free", kdl_snap__bool(true))
        }

        if f.freed_count > 0 {
            kdl.emit_node(em, "freed")
            for i in 0..<f.freed_count do kdl.emit_arg(em, kdl_snap__i64(i64(f.freed[i])))
        }
    }

    @(private)
    kdl_snap__emit_relations :: proc(self: ^Database, em: ^kdl.Emitter) {
        rt := self.relations

        kdl.emit_node(em, "relations")
        kdl.emit_property(em, "cap", kdl_snap__i64(i64(rt.cap)))

        for ix in 0..<len(rt.first_child) {
            c := rt.first_child[ix]
            if is_not_set(c) do continue

            kdl.emit_node(em, "parent")
            kdl_snap__emit_eid(em, rt.parent[c.ix])
            kdl.start_emitting_children(em)
            for !is_not_set(c) {
                kdl.emit_node(em, "child")
                kdl_snap__emit_eid(em, c)
                c = rt.next_sibling[c.ix]
            }
            kdl.finish_emitting_children(em)
        }
    }

    @(private)
    kdl_snap__emit_pairs :: proc(em: ^kdl.Emitter, pt: ^Pair_Table_Base, arena: ^virtual.Arena) {
        scratch := virtual.arena_allocator(arena)
        raw := cast(^Pair_Table_Raw) pt
        elem_size := pt.data_type_info.size

        kdl.emit_node(em, "pair_table")
        kdl.emit_property(em, "id", kdl_snap__i64(i64(pt.id)))
        if name := kdl_snap__full_name(pt.data_type_info, scratch); len(name) > 0 && elem_size > 0 {
            kdl.emit_property(em, "data", kdl_snap__str(name))
        }
        kdl.emit_property(em, "presence", kdl_snap__i64(i64(pt.presence.id)))
        kdl.emit_property(em, "cap", kdl_snap__i64(i64(pt.pairs_cap)))

        // descending: the freelist hands out rows top-down, so a reload lands every pair on its original row
        #reverse for holder, r in pt.row_holder[:pt.pairs_cap] {
            if holder.ix == DELETED_INDEX do continue

            temp := virtual.arena_temp_begin(arena)
            defer virtual.arena_temp_end(temp)

            kdl.emit_node(em, "pair")
            kdl_snap__emit_eid(em, pt.row_holder[r])
            kdl_snap__emit_eid(em, pt.targets[r])
            if elem_size > 0 {
                kdl_snap__emit_content(em, pt.data_type_info, rawptr(uintptr(raw_data(raw.data)) + uintptr(r * elem_size)), scratch)
            }
        }
    }

    @(private)
    kdl_snap__write_text :: proc(folder, name, text: string, allocator: runtime.Allocator) -> Error {
        path := kdl_snap__path(folder, name, allocator) or_return
        if os.write_entire_file(path, text) != nil do return API_Error.File_Error
        return nil
    }

    // Writes the Database as a folder of .kdl files; an existing snapshot there is replaced only when overwrite = true.
    database__save_to_kdl :: proc(self: ^Database, folder: string, overwrite := false, allocator := context.allocator) -> Error {
        if !database__is_valid(self) do return API_Error.Object_Invalid
        database__snapshot_check_not_paused(self, check_holes = true) or_return
        kdl_snap__check_pod(self) or_return

        arena: virtual.Arena
        virtual.arena_init_growing(&arena) or_return
        defer virtual.arena_destroy(&arena)
        scratch := virtual.arena_allocator(&arena)

        files := kdl_snap__plan_files(self, scratch)

        if os.exists(folder) {
            if !os.is_dir(folder) do return API_Error.File_Error
        } else if os.make_directory_all(folder) != nil {
            return API_Error.File_Error
        }

        manifest_path := kdl_snap__path(folder, KDL_SNAPSHOT_MANIFEST, scratch) or_return
        old_files: [dynamic]string
        if os.exists(manifest_path) {
            if !overwrite do return API_Error.Snapshot_Already_Exists
            old := kdl_snap__read_manifest(folder, scratch) or_return
            old_files = old.files
        }

        for f in files {
            if slice.contains(old_files[:], f.name) do continue
            path := kdl_snap__path(folder, f.name, scratch) or_return
            if os.exists(path) do return API_Error.Snapshot_Already_Exists
        }

        if os.exists(manifest_path) {
            for name in old_files {
                path := kdl_snap__path(folder, name, scratch) or_return
                if os.exists(path) && os.remove(path) != nil do return API_Error.File_Error
            }
            if os.remove(manifest_path) != nil do return API_Error.File_Error
        }

        for f in files {
            em: kdl.Emitter
            kdl.init(&em, allocator = allocator) or_return

            switch f.kind {
                case .Entities:
                    kdl_snap__emit_entities(self, &em)
                case .Relations:
                    kdl_snap__emit_relations(self, &em)
                case .Table:
                    kdl_snap__emit_table(self, &em, self.tables.items[f.id], &arena)
                case .Tag:
                    kdl_snap__emit_table(self, &em, cast(^Shared_Table) self.tag_tables.items[f.id], &arena)
                case .Pairs:
                    kdl_snap__emit_pairs(&em, self.pair_tables.items[f.id], &arena)
            }
            kdl.emit_end(&em)

            werr := kdl_snap__write_text(folder, f.name, kdl.get_buffer(&em), scratch)
            kdl.destroy(&em)
            if werr != nil do return werr
        }

        em: kdl.Emitter
        kdl.init(&em, allocator = allocator) or_return
        defer kdl.destroy(&em)

        kdl.emit_node(&em, "ode_ecs_snapshot")
        kdl.emit_property(&em, "version", kdl_snap__i64(KDL_SNAPSHOT_VERSION))
        kdl.emit_node(&em, "entities_cap")
        kdl.emit_arg(&em, kdl_snap__i64(i64(self.overbase.id_factory.cap)))
        for f in files {
            kdl.emit_node(&em, "file")
            kdl.emit_arg(&em, kdl_snap__str(f.name))
        }
        kdl.emit_end(&em)

        return kdl_snap__write_text(folder, KDL_SNAPSHOT_MANIFEST, kdl.get_buffer(&em), scratch)
    }

///////////////////////////////////////////////////////////////////////////////
// Load

    @(private)
    Kdl_Snap_Section :: struct {
        table:   ^Shared_Table,
        is_tag:  bool,
        eids:    [dynamic]entity_id,
        rows:    [dynamic]byte,   // Table/Compact/Tiny/Flags
        columns: [][dynamic]byte, // Arch_Table
    }

    @(private)
    Kdl_Snap_Pairs :: struct {
        pt:      ^Pair_Table_Base,
        holders: [dynamic]entity_id,
        targets: [dynamic]entity_id,
        data:    [dynamic]byte,
    }

    @(private)
    Kdl_Snap_Load :: struct {
        db:        ^Database,
        allocator: runtime.Allocator,
        saved_cap: int,

        disabled_bits:     []Uni_Bits,
        tag_disabled_bits: []Uni_Bits,

        has_entities:  bool,
        created_count: int,
        items:         []entity_id,
        freed:         [dynamic]u32,

        has_relations: bool,
        rel_count:     int,
        parent, first_child, next_sibling, prev_sibling: []entity_id,
        children_count: []i32,

        sections: [dynamic]Kdl_Snap_Section,
        pairs:    [dynamic]Kdl_Snap_Pairs,
    }

    @(private)
    kdl_snap__grow_zeroed :: proc(buf: ^[dynamic]byte, size: int) -> (ptr: rawptr, err: Error) {
        old := len(buf)
        resize(buf, old + size) or_return
        slice.zero(buf[old:])
        return raw_data(buf[old:]), nil
    }

    @(private)
    kdl_snap__load_table :: proc(l: ^Kdl_Snap_Load, nodes: [dynamic]^Kdl_Node) -> Error {
        db := l.db
        header := nodes[0]

        id, has_id := kdl_snap__prop_i64(header, "id")
        type_name, has_type := kdl_snap__prop_str(header, "type")
        if !has_id || !has_type do return API_Error.Snapshot_Invalid
        type, type_ok := kdl_snap__table_type_parse(type_name)
        if !type_ok do return API_Error.Snapshot_Invalid

        s := Kdl_Snap_Section{ is_tag = type == .Tag_Table }
        if s.is_tag {
            if id < 0 || id >= i64(len(db.tag_tables.items)) do return API_Error.Snapshot_Schema_Mismatch
            s.table = cast(^Shared_Table) db.tag_tables.items[id]
        } else {
            if id < 0 || id >= i64(len(db.tables.items)) do return API_Error.Snapshot_Schema_Mismatch
            s.table = db.tables.items[id]
        }
        if s.table == nil || s.table.state != Object_State.Normal || s.table.type != type do return API_Error.Snapshot_Schema_Mismatch

        ti := shared_table__type_info(s.table)
        if !kdl_snap__name_matches(header, "component", ti, l.allocator) do return API_Error.Snapshot_Schema_Mismatch

        s.eids = make([dynamic]entity_id, l.allocator)
        s.rows = make([dynamic]byte, l.allocator)

        at: ^Arch_Table
        if type == .Arch_Table {
            at = cast(^Arch_Table) s.table
            s.columns = make([][dynamic]byte, len(at.columns), l.allocator)
            for &c in s.columns do c = make([dynamic]byte, l.allocator)
        }

        column_ix := 0
        for node in nodes[1:] {
            switch node.name {
                case "column":
                    if at == nil || column_ix >= len(at.columns) || len(node.args) != 1 do return API_Error.Snapshot_Schema_Mismatch
                    name, ok := kdl_snap__value_str(node.args[0])
                    if !ok do return API_Error.Snapshot_Invalid
                    expected := kdl_snap__full_name(at.columns[column_ix].type_info, l.allocator)
                    if len(name) > 0 && len(expected) > 0 && name != expected do return API_Error.Snapshot_Schema_Mismatch
                    column_ix += 1

                case "row":
                    disabled, ann_ok := kdl_snap__is_disabled_row(node)
                    if !ann_ok do return API_Error.Snapshot_Invalid
                    eid, eid_ok := kdl_snap__arg_eid(node, 0)
                    if !eid_ok || eid.ix >= l.saved_cap do return API_Error.Snapshot_Invalid
                    append(&s.eids, eid)

                    if disabled {
                        bits := s.is_tag ? l.tag_disabled_bits : l.disabled_bits
                        uni_bits__add(&bits[eid.ix], s.table.id)
                    }

                    switch {
                        case s.is_tag:
                            if len(node.args) != 2 || len(node.props) > 0 || len(node.children) > 0 do return API_Error.Snapshot_Invalid
                        case at != nil:
                            if len(node.args) != 2 || len(node.props) > 0 do return API_Error.Snapshot_Invalid
                            ptrs := make([]rawptr, len(at.columns), l.allocator)
                            for col, i in at.columns {
                                ptrs[i] = kdl_snap__grow_zeroed(&s.columns[i], col.type_info.size) or_return
                            }
                            for child, k in node.children {
                                if child.type_annotation != nil do return API_Error.Snapshot_Invalid
                                occurrence := 0
                                for prev in node.children[:k] {
                                    if prev.name == child.name do occurrence += 1
                                }
                                col_ix := -1
                                for col, i in at.columns {
                                    short := kdl_snap__short_name(col.type_info)
                                    if (len(short) > 0 ? short : "column") != child.name do continue
                                    if occurrence == 0 {
                                        col_ix = i
                                        break
                                    }
                                    occurrence -= 1
                                }
                                if col_ix < 0 do return API_Error.Snapshot_Invalid
                                kdl_snap__decode_content(child, 0, at.columns[col_ix].type_info, ptrs[col_ix]) or_return
                            }
                        case:
                            ptr := kdl_snap__grow_zeroed(&s.rows, ti.size) or_return
                            kdl_snap__decode_content(node, 2, ti, ptr) or_return
                    }

                case:
                    return API_Error.Snapshot_Invalid
            }
        }
        if at != nil && column_ix != len(at.columns) do return API_Error.Snapshot_Schema_Mismatch

        append(&l.sections, s)
        return nil
    }

    @(private)
    kdl_snap__load_pairs :: proc(l: ^Kdl_Snap_Load, nodes: [dynamic]^Kdl_Node) -> Error {
        db := l.db
        header := nodes[0]

        id, has_id := kdl_snap__prop_i64(header, "id")
        if !has_id do return API_Error.Snapshot_Invalid
        if id < 0 || id >= i64(len(db.pair_tables.items)) do return API_Error.Snapshot_Schema_Mismatch
        pt := db.pair_tables.items[id]
        if pt == nil || pt.state != Object_State.Normal do return API_Error.Snapshot_Schema_Mismatch

        elem_size := pt.data_type_info.size
        if elem_size > 0 && !kdl_snap__name_matches(header, "data", pt.data_type_info, l.allocator) do return API_Error.Snapshot_Schema_Mismatch
        if presence, has := kdl_snap__prop_i64(header, "presence"); has && presence != i64(pt.presence.id) {
            return API_Error.Snapshot_Schema_Mismatch
        }

        p := Kdl_Snap_Pairs{
            pt      = pt,
            holders = make([dynamic]entity_id, l.allocator),
            targets = make([dynamic]entity_id, l.allocator),
            data    = make([dynamic]byte, l.allocator),
        }

        for node in nodes[1:] {
            if node.name != "pair" || node.type_annotation != nil do return API_Error.Snapshot_Invalid
            holder, h_ok := kdl_snap__arg_eid(node, 0)
            target, t_ok := kdl_snap__arg_eid(node, 2)
            if !h_ok || !t_ok do return API_Error.Snapshot_Invalid
            append(&p.holders, holder)
            append(&p.targets, target)

            if elem_size > 0 {
                ptr := kdl_snap__grow_zeroed(&p.data, elem_size) or_return
                kdl_snap__decode_content(node, 4, pt.data_type_info, ptr) or_return
            } else if len(node.args) != 4 || len(node.props) > 0 || len(node.children) > 0 {
                return API_Error.Snapshot_Invalid
            }
        }

        append(&l.pairs, p)
        return nil
    }

    @(private)
    kdl_snap__load_entities :: proc(l: ^Kdl_Snap_Load, nodes: [dynamic]^Kdl_Node) -> Error {
        if l.has_entities do return API_Error.Snapshot_Invalid
        l.has_entities = true
        header := nodes[0]

        if cap, has := kdl_snap__prop_i64(header, "cap"); has && cap != i64(l.saved_cap) do return API_Error.Snapshot_Invalid
        created, has_created := kdl_snap__prop_i64(header, "created")
        if !has_created || created < 0 || created > i64(l.saved_cap) do return API_Error.Snapshot_Invalid
        l.created_count = int(created)

        l.items = make([]entity_id, l.saved_cap, l.allocator)
        for &item, i in l.items {
            item.ix = i < l.created_count ? i : DELETED_INDEX
        }
        l.freed = make([dynamic]u32, l.allocator)

        for node in nodes[1:] {
            switch node.name {
                case "slot":
                    if len(node.args) != 1 || len(node.children) > 0 do return API_Error.Snapshot_Invalid
                    ix, ok := kdl_snap__value_i64(node.args[0])
                    if !ok || ix < 0 || ix >= i64(l.saved_cap) do return API_Error.Snapshot_Invalid

                    gen: i64
                    free := false
                    for p in node.props {
                        switch p.name {
                            case "gen":
                                gen, ok = kdl_snap__value_i64(p.value)
                                if !ok || gen < 0 || gen > i64(max(u32)) do return API_Error.Snapshot_Invalid
                            case "free":
                                free, ok = p.value.variant.(bool)
                                if !ok do return API_Error.Snapshot_Invalid
                            case:
                                return API_Error.Snapshot_Invalid
                        }
                    }
                    if !free && ix >= created do return API_Error.Snapshot_Invalid

                    l.items[ix].ix = free ? DELETED_INDEX : int(ix)
                    l.items[ix].gen = uint(gen)
                case "freed":
                    if len(node.props) > 0 || len(node.children) > 0 do return API_Error.Snapshot_Invalid
                    for a in node.args {
                        ix, ok := kdl_snap__value_i64(a)
                        if !ok || ix < 0 || ix >= i64(l.saved_cap) do return API_Error.Snapshot_Invalid
                        append(&l.freed, u32(ix))
                    }
                case:
                    return API_Error.Snapshot_Invalid
            }
        }

        return nil
    }

    @(private)
    kdl_snap__load_relations :: proc(l: ^Kdl_Snap_Load, nodes: [dynamic]^Kdl_Node) -> Error {
        if l.has_relations do return API_Error.Snapshot_Invalid
        l.has_relations = true

        arrays := [4]^[]entity_id{ &l.parent, &l.first_child, &l.next_sibling, &l.prev_sibling }
        for a in arrays {
            a^ = make([]entity_id, l.saved_cap, l.allocator)
            for &e in a^ do e.ix = DELETED_INDEX
        }
        l.children_count = make([]i32, l.saved_cap, l.allocator)

        for node in nodes[1:] {
            if node.name != "parent" || len(node.args) != 2 || len(node.props) > 0 do return API_Error.Snapshot_Invalid
            p, p_ok := kdl_snap__arg_eid(node, 0)
            if !p_ok || p.ix >= l.saved_cap || !is_not_set(l.first_child[p.ix]) do return API_Error.Snapshot_Invalid

            prev := entity_id{ ix = DELETED_INDEX }
            for child in node.children {
                if child.name != "child" || len(child.args) != 2 || len(child.props) > 0 || len(child.children) > 0 {
                    return API_Error.Snapshot_Invalid
                }
                c, c_ok := kdl_snap__arg_eid(child, 0)
                if !c_ok || c.ix >= l.saved_cap || !is_not_set(l.parent[c.ix]) do return API_Error.Snapshot_Invalid

                l.parent[c.ix] = p
                l.prev_sibling[c.ix] = prev
                if is_not_set(prev) {
                    l.first_child[p.ix] = c
                } else {
                    l.next_sibling[prev.ix] = c
                }
                prev = c
                l.children_count[p.ix] += 1
                l.rel_count += 1
            }
        }

        return nil
    }

    @(private)
    kdl_snap__put :: proc(buf: ^[dynamic]byte, src: rawptr, #any_int size: int) {
        if size <= 0 do return
        append(buf, ..([^]byte)(src)[:size])
    }

    @(private)
    kdl_snap__pad8 :: proc(buf: ^[dynamic]byte) {
        for len(buf) % 8 != 0 do append(buf, 0)
    }

    @(private)
    kdl_snap__put_name :: proc(buf: ^[dynamic]byte, ti: ^runtime.Type_Info, allocator: runtime.Allocator) {
        name := kdl_snap__full_name(ti, allocator)
        kdl_snap__put(buf, raw_data(name), len(name))
        kdl_snap__pad8(buf)
    }

    // Same layout database__serialize writes.
    @(private)
    kdl_snap__build_binary :: proc(l: ^Kdl_Snap_Load) -> (buf: [dynamic]byte, err: Error) {
        db := l.db
        buf = make([dynamic]byte, l.allocator)

        slice.sort_by(l.sections[:], proc(a, b: Kdl_Snap_Section) -> bool {
            if a.is_tag != b.is_tag do return !a.is_tag
            return a.table.id < b.table.id
        })
        slice.sort_by(l.pairs[:], proc(a, b: Kdl_Snap_Pairs) -> bool {
            return a.pt.id < b.pt.id
        })

        flags: u32 = 0
        if l.has_relations do flags |= SNAPSHOT_FLAG__HAS_RELATIONS
        if l.has_entities do flags |= SNAPSHOT_FLAG__HAS_ENTITY_ID_SECTION

        hdr := Snapshot_Header{
            magic         = SNAPSHOT_MAGIC,
            version       = SNAPSHOT_VERSION,
            endian_check  = SNAPSHOT_ENDIAN_CHECK,
            flags         = flags,
            entities_cap  = i64(l.saved_cap),
            created_count = i64(l.created_count),
            freed_count   = i64(len(l.freed)),
            section_count = i64(len(l.sections)),
            pair_table_section_count = i64(len(l.pairs)),
        }
        kdl_snap__put(&buf, &hdr, size_of(hdr))

        if l.has_entities {
            kdl_snap__put(&buf, raw_data(l.items), len(l.items) * size_of(entity_id))
            kdl_snap__put(&buf, raw_data(l.freed), len(l.freed) * size_of(u32))
            kdl_snap__pad8(&buf)
        }

        kdl_snap__put(&buf, raw_data(l.disabled_bits), len(l.disabled_bits) * size_of(Uni_Bits))
        kdl_snap__pad8(&buf)
        kdl_snap__put(&buf, raw_data(l.tag_disabled_bits), len(l.tag_disabled_bits) * size_of(Uni_Bits))
        kdl_snap__pad8(&buf)

        for &s in l.sections {
            n := len(s.eids)
            ti := shared_table__type_info(s.table)
            th := Snap_Table_Header{
                table_id   = i64(s.table.id),
                table_type = i32(s.table.type),
                cap        = i64(shared_table__cap(s.table)),
                len        = i64(n),
            }
            if ti != nil {
                th.comp_size = i64(ti.size)
                th.comp_align = i64(ti.align)
                th.name_len = i64(len(kdl_snap__full_name(ti, l.allocator)))
            }

            #partial switch s.table.type {
                case .Tag_Table:
                    kdl_snap__put(&buf, &th, size_of(th))
                    kdl_snap__put(&buf, raw_data(s.eids), n * size_of(entity_id))
                case .Arch_Table:
                    at := cast(^Arch_Table) s.table
                    th.column_count = i64(len(at.columns))
                    kdl_snap__put(&buf, &th, size_of(th))
                    for col in at.columns {
                        cih := Snap_Arch_Column_Header{
                            comp_size  = i64(col.type_info.size),
                            comp_align = i64(col.type_info.align),
                            name_len   = i64(len(kdl_snap__full_name(col.type_info, l.allocator))),
                        }
                        kdl_snap__put(&buf, &cih, size_of(cih))
                        kdl_snap__put_name(&buf, col.type_info, l.allocator)
                    }
                    kdl_snap__put(&buf, raw_data(s.eids), n * size_of(entity_id))
                    kdl_snap__pad8(&buf)
                    for c in s.columns {
                        kdl_snap__put(&buf, raw_data(c), len(c))
                        kdl_snap__pad8(&buf)
                    }
                case:
                    kdl_snap__put(&buf, &th, size_of(th))
                    kdl_snap__put_name(&buf, ti, l.allocator)
                    kdl_snap__put(&buf, raw_data(s.eids), n * size_of(entity_id))
                    kdl_snap__put(&buf, raw_data(s.rows), len(s.rows))
                    kdl_snap__pad8(&buf)
            }
        }

        if l.has_relations {
            cap := 0
            if db.relations != nil do cap = db.relations.cap
            rh := Snap_Relations_Header{ cap = i64(cap), count = i64(l.rel_count) }
            kdl_snap__put(&buf, &rh, size_of(rh))
            kdl_snap__put(&buf, raw_data(l.parent),         l.saved_cap * size_of(entity_id))
            kdl_snap__put(&buf, raw_data(l.first_child),    l.saved_cap * size_of(entity_id))
            kdl_snap__put(&buf, raw_data(l.next_sibling),   l.saved_cap * size_of(entity_id))
            kdl_snap__put(&buf, raw_data(l.prev_sibling),   l.saved_cap * size_of(entity_id))
            kdl_snap__put(&buf, raw_data(l.children_count), l.saved_cap * size_of(i32))
            kdl_snap__pad8(&buf)
        }

        for &p in l.pairs {
            pth := Snap_Pair_Table_Header{
                pair_table_id     = i64(p.pt.id),
                presence_table_id = i64(p.pt.presence.id),
                data_elem_size    = i64(p.pt.data_type_info.size),
                data_elem_align   = i64(p.pt.data_type_info.align),
                pairs_cap         = i64(p.pt.pairs_cap),
                count             = i64(len(p.holders)),
            }
            kdl_snap__put(&buf, &pth, size_of(pth))
            kdl_snap__put(&buf, raw_data(p.holders), len(p.holders) * size_of(entity_id))
            kdl_snap__put(&buf, raw_data(p.targets), len(p.targets) * size_of(entity_id))
            kdl_snap__pad8(&buf)
            kdl_snap__put(&buf, raw_data(p.data), len(p.data))
            kdl_snap__pad8(&buf)
        }

        return buf, nil
    }

    // Loads a folder written by save_to_kdl; all-or-nothing, same schema rules as deserialize.
    database__load_from_kdl :: proc(self: ^Database, folder: string, allocator := context.allocator) -> Error {
        if !database__is_valid(self) do return API_Error.Object_Invalid

        arena: virtual.Arena
        virtual.arena_init_growing(&arena) or_return
        defer virtual.arena_destroy(&arena)
        scratch := virtual.arena_allocator(&arena)

        manifest := kdl_snap__read_manifest(folder, scratch) or_return
        if manifest.entities_cap > self.overbase.id_factory.cap do return API_Error.Snapshot_Capacity_Too_Small

        l := Kdl_Snap_Load{
            db                = self,
            allocator         = scratch,
            saved_cap         = manifest.entities_cap,
            sections          = make([dynamic]Kdl_Snap_Section, scratch),
            pairs             = make([dynamic]Kdl_Snap_Pairs, scratch),
        }
        l.disabled_bits = make([]Uni_Bits, l.saved_cap, scratch) or_return
        l.tag_disabled_bits = make([]Uni_Bits, l.saved_cap, scratch) or_return

        for name in manifest.files {
            nodes := kdl_snap__read_file(folder, name, scratch) or_return
            if len(nodes) == 0 do return API_Error.Snapshot_Invalid

            switch nodes[0].name {
                case "entities":   kdl_snap__load_entities(&l, nodes) or_return
                case "relations":  kdl_snap__load_relations(&l, nodes) or_return
                case "table":      kdl_snap__load_table(&l, nodes) or_return
                case "pair_table": kdl_snap__load_pairs(&l, nodes) or_return
                case:              return API_Error.Snapshot_Invalid
            }
        }

        buf := kdl_snap__build_binary(&l) or_return
        return database__deserialize(self, buf[:])
    }
