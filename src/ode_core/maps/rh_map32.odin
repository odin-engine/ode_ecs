/*
    2026 (c) Oleh, https://github.com/zm69
*/
package maps

// Core
    import "core:log"
    import "core:mem"
    import "core:math"

// ODE_CORE
    import oc ".."

///////////////////////////////////////////////////////////////////////////////
// Rh_Map32 - Robin Hood map with 8-byte items (u32 key -> u32 value).
//
// Made for eid.ix -> row-id indexes (Compact_Table); RH_MAP32_DELETED (max(u32)) doubles as the empty-slot marker and "not found".

    RH_MAP32_DELETED :: max(u32)

    Rh_Map32_Item :: struct {
        key: u32,
        value: u32,
    }

    Rh_Map32 :: struct {
        items: []Rh_Map32_Item,
        capacity: int,
        count: int,

        max_count: int,
        mask: int,
    }

    rh_map32__is_valid ::  #force_inline proc "contextless"(self: ^Rh_Map32) -> bool {
        if self == nil do return false
        if self.items == nil do return false
        if self.capacity <= 0 do return false
        if self.max_count <= 0 do return false
        if self.mask == 0 do return false

        return true
    }

    // Smallest power-of-2 capacity holding count items under RH_MAP32_LOAD_PCT.
    rh_map32__capacity_for :: proc(#any_int count: int) -> int {
        return math.next_power_of_two((count * 100 + RH_MAP32_LOAD_PCT - 1) / RH_MAP32_LOAD_PCT)
    }

    rh_map32__init :: proc(self: ^Rh_Map32, #any_int capacity: int, allocator := context.allocator, loc := #caller_location) -> (err: oc.Error) {
        assert(self != nil, loc = loc)
        assert(capacity > 1, loc = loc)
        assert(u64(capacity) < u64(max(u32)), loc = loc) // must fit in u32

        if !math.is_power_of_two(capacity) do return oc.Core_Error.Capacity_Is_Not_Power_Of_2
        self.capacity = capacity

        when !MAPS_TESTING {
            if self.capacity < 8 do self.capacity = 8
        }

        self.items = make([]Rh_Map32_Item, self.capacity, allocator) or_return

        rh_map32__clear(self)  // requires self.capacity to be set

        // derive from self.capacity (may have been bumped to the 8 minimum above)
        when MAPS_TESTING {
            self.max_count = self.capacity
        } else {
            self.max_count = self.capacity * RH_MAP32_LOAD_PCT / 100
        }

        self.mask = self.capacity - 1

        return nil
    }

    // Rehashes into capacity (a power of 2) when that is larger.
    rh_map32__grow :: proc(self: ^Rh_Map32, #any_int capacity: int, allocator := context.allocator) -> (err: oc.Error) {
        assert(rh_map32__is_valid(self))
        if capacity <= self.capacity do return nil

        old := self^
        if ierr := rh_map32__init(self, capacity, allocator); ierr != nil {
            self^ = old
            return ierr
        }

        for item in old.items {
            if item.key == RH_MAP32_DELETED do continue
            if aerr := rh_map32__add(self, item.key, item.value); aerr != .None do return aerr
        }
        delete(old.items, allocator)
        return nil
    }

    rh_map32__terminate :: proc(self: ^Rh_Map32, allocator := context.allocator, loc := #caller_location) -> (err: oc.Error) {
        assert(self != nil, loc = loc)

        delete(self.items, allocator) or_return
        self.items = nil

        self.capacity = 0
        self.count = 0

        self.max_count = 0
        self.mask = 0

        return nil
    }

    // Low-bits Fibonacci hash for power-of-2 capacity: (k * odd_constant) mod 2^n
    // is a bijection on dense consecutive keys, so zero collisions for entity indexes.
    @(private)
    rh_map32__hash :: #force_inline proc "contextless" (self: ^Rh_Map32, key: u32) -> int {
        when MAPS_TESTING {
            return int(key) & self.mask // predictable hash for tests
        } else {
            return cast(int)((u64(key) * 11400714819323198485) & u64(self.mask))
        }
    }

    // Insert; key must be < RH_MAP32_DELETED (#no_bounds_check: idx is always masked with capacity - 1).
    rh_map32__add :: proc(self: ^Rh_Map32, key: u32, value: u32) -> (err: oc.Core_Error) #no_bounds_check {

        if self.count >= self.max_count {
            return oc.Core_Error.Container_Is_Full
        }

        item := Rh_Map32_Item{ key = key, value = value }

        idx := rh_map32__hash(self, item.key)
        probe_distance := 0

        for {
            if self.items[idx].key == RH_MAP32_DELETED {
                self.items[idx] = item
                self.count += 1
                return oc.Core_Error.None
            }

            if self.items[idx].key == key { // update existing key
                self.items[idx].value = item.value
                return oc.Core_Error.None
            }

            existing_key := self.items[idx].key
            existing_distance := (idx - rh_map32__hash(self, existing_key)) & self.mask

            if existing_distance < probe_distance { // Robin Hood swap
                temp_item := self.items[idx]
                self.items[idx] = item
                item = temp_item
                probe_distance = existing_distance
            }

            idx = (idx + 1) & self.mask
            probe_distance += 1

            // No mid-probe bail-out: count < max_count guarantees an empty
            // slot exists, and bailing after a swap would drop the displaced item.
        }
    }

    // Single-probe get-or-insert: one walk either finds an existing key (found=true) or, if can_insert, inserts at the walk's natural point (found=false).
    rh_map32__get_or_insert :: #force_inline proc(self: ^Rh_Map32, key: u32, insert_value: u32, can_insert: bool) -> (value: u32, found: bool, err: oc.Core_Error) #no_bounds_check {
        insertable := can_insert && self.count < self.max_count

        idx := rh_map32__hash(self, key)
        probe_distance := 0

        if !insertable {
            for probe_distance < self.max_count {
                k := self.items[idx].key
                if k == key do return self.items[idx].value, true, oc.Core_Error.None
                if k == RH_MAP32_DELETED do break
                if ((idx - rh_map32__hash(self, k)) & self.mask) < probe_distance do break
                idx = (idx + 1) & self.mask
                probe_distance += 1
            }
            if can_insert do err = oc.Core_Error.Container_Is_Full
            return 0, false, err
        }

        item := Rh_Map32_Item{ key = key, value = insert_value }

        for {
            if self.items[idx].key == RH_MAP32_DELETED {
                self.items[idx] = item
                self.count += 1
                return insert_value, false, oc.Core_Error.None
            }

            if self.items[idx].key == key {
                return self.items[idx].value, true, oc.Core_Error.None
            }

            existing_key := self.items[idx].key
            existing_distance := (idx - rh_map32__hash(self, existing_key)) & self.mask

            if existing_distance < probe_distance {
                temp_item := self.items[idx]
                self.items[idx] = item
                item = temp_item
                probe_distance = existing_distance
            }

            idx = (idx + 1) & self.mask
            probe_distance += 1
        }
    }

    @(private)
    // #no_bounds_check: idx is always masked with capacity - 1, capacity == len(items)
    rh_map32__get_from_hash :: #force_inline proc "contextless" (self: ^Rh_Map32, key: u32, ix: int) -> (u32, int) #no_bounds_check {
        probe_distance := 0
        idx := ix

        for probe_distance < self.max_count {
            k := self.items[idx].key
            if k == key do return self.items[idx].value, idx
            if k == RH_MAP32_DELETED do break
            if ((idx - rh_map32__hash(self, k)) & self.mask) < probe_distance do break // Robin Hood: key would sit before a closer-to-home item

            idx = (idx + 1) & self.mask
            probe_distance += 1
        }

        return RH_MAP32_DELETED, oc.DELETED_INDEX
    }

    // Returns (value, slot index); index is oc.DELETED_INDEX when absent.
    rh_map32__get_with_index :: #force_inline proc "contextless" (self: ^Rh_Map32, key: u32) -> (u32, int) {
        ix := rh_map32__hash(self, key)

        return rh_map32__get_from_hash(self, key, ix)
    }

    // Lookup; returns RH_MAP32_DELETED when key is absent
    rh_map32__get :: #force_inline proc "contextless" (self: ^Rh_Map32, key: u32) -> u32 {
        idx := rh_map32__hash(self, key)

        val, _ := rh_map32__get_from_hash(self, key, idx)

        return val
    }

    // Core_Error, not oc.Error — never allocates.
    rh_map32__update :: proc(self: ^Rh_Map32, key: u32, new_value: u32) -> (err: oc.Core_Error) {
        _, ix := rh_map32__get_with_index(self, key)

        if ix == oc.DELETED_INDEX {
            return oc.Core_Error.Not_Found
        }

        self.items[ix].value = new_value

        return oc.Core_Error.None
    }

    // Removes the item at a slot index from rh_map32__get_with_index via backward shift, without re-hashing (#no_bounds_check: indexes are always masked with capacity - 1).
    rh_map32__remove_at :: proc(self: ^Rh_Map32, #any_int idx: int) #no_bounds_check {
        idx := idx

        next_idx := (idx + 1) & self.mask // backward shift
        for self.items[next_idx].key != RH_MAP32_DELETED {
            home := rh_map32__hash(self, self.items[next_idx].key)
            if ((next_idx - home) & self.mask) == 0 {
                break
            }
            self.items[idx] = self.items[next_idx]
            idx = next_idx
            next_idx = (next_idx + 1) & self.mask
        }

        self.items[idx].key = RH_MAP32_DELETED
        self.items[idx].value = RH_MAP32_DELETED
        self.count -= 1
    }

    // Core_Error, not oc.Error — never allocates.
    rh_map32__remove :: proc(self: ^Rh_Map32, key: u32) -> oc.Core_Error {
        _, idx := rh_map32__get_with_index(self, key)
        if idx == oc.DELETED_INDEX do return oc.Core_Error.Not_Found

        rh_map32__remove_at(self, idx)
        return oc.Core_Error.None
    }

    rh_map32__clear ::  #force_inline proc "contextless" (self: ^Rh_Map32) {
        for i:=0; i<self.capacity; i+=1 {
            self.items[i].key = RH_MAP32_DELETED
        }
        self.count = 0
    }

    rh_map32__len ::  #force_inline proc "contextless" (self: ^Rh_Map32) -> int {
        return self.count
    }

    rh_map32__memory_usage :: proc(self: ^Rh_Map32) -> int {
        return size_of(Rh_Map32) + size_of(Rh_Map32_Item) * self.capacity
    }

///////////////////////////////////////////////////////////////////////////////
// Tests
//


    // Asserts observable behavior only (never slot placement), so it runs in
    // both modes; without -define:maps_testing=true it exercises the
    // production Fibonacci hash, the default load factor, and the min-capacity-8 bump.


