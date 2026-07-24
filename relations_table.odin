/*
    2026 (c) Oleh, https://github.com/zm69

    Optional parent/child entity relations. One Relations_Table per Database.
    Every entity has at most one parent and any number of children.

    Storage is intrusive linked-tree arrays indexed by eid.ix — every operation
    is a direct array access, no hashing. All memory is preallocated at init:
    entities_cap * 36 bytes + cap * 8 bytes.

    `cap` limits the number of concurrent parent links (relations). It also
    sizes the internal scratch buffer used by relations_table__children_of and
    the destroy_children cascade (sufficient: a parent has at most `cap`
    children and a subtree has at most `cap` descendants).

    Relations are not components: they do not affect Views. If you need to
    iterate "all entities with a parent", pair this with a Tag_Table.

    Cleanup is automatic: database__destroy_entity unlinks the destroyed entity
    from its parent and orphans (or, with destroy_children=true, destroys) its
    children, so every entity_id stored here is always alive.
*/
package ode_ecs

// ODE
    import oc "ode_core"

///////////////////////////////////////////////////////////////////////////////
// Relations_Table
//

    Relations_Table :: struct {
        state: Object_State,
        db: ^Database,

        cap: int,       // max number of concurrent parent links (relations)
        count: int,     // current number of parent links

        // Sized to db.overbase.id_factory.cap, indexed by eid.ix.
        // entity_id with ix == DELETED_INDEX means "none".
        parent:         []entity_id,
        first_child:    []entity_id,
        next_sibling:   []entity_id,    // doubly-linked sibling list => O(1) unlink
        prev_sibling:   []entity_id,
        children_count: []i32,

        // Sized to cap: children_of() results and destroy-cascade queue.
        // The slice returned by children_of is valid only until the next
        // children_of call or any structural change.
        scratch: []entity_id,
    }

    // Is table valid and ready to use (initialized and everything is ok)
    relations_table__is_valid :: proc(self: ^Relations_Table) -> bool {
        if self == nil do return false
        if self.state != Object_State.Normal do return false
        if !database__is_valid(self.db) do return false
        if self.parent == nil do return false
        if self.first_child == nil do return false
        if self.next_sibling == nil do return false
        if self.prev_sibling == nil do return false
        if self.children_count == nil do return false
        if self.scratch == nil do return false
        if self.cap <= 0 do return false

        return true
    }

    relations_table__init :: proc(self: ^Relations_Table, db: ^Database, cap: int, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(database__is_valid(db), loc = loc)
            assert(self.state == Object_State.Not_Initialized, loc = loc) // should be NOT_INITIALIZED
            assert(cap > 0, loc = loc)
            assert(cap <= db.overbase.id_factory.cap, loc = loc) // cannot be larger than entities_cap
        }

        if db.relations != nil do return API_Error.Relations_Table_Already_Exists

        self.db = db
        self.cap = cap

        entities_cap := db.overbase.id_factory.cap

        self.parent         = make([]entity_id, entities_cap, db.allocator) or_return
        self.first_child    = make([]entity_id, entities_cap, db.allocator) or_return
        self.next_sibling   = make([]entity_id, entities_cap, db.allocator) or_return
        self.prev_sibling   = make([]entity_id, entities_cap, db.allocator) or_return
        self.children_count = make([]i32,       entities_cap, db.allocator) or_return
        self.scratch        = make([]entity_id, cap,          db.allocator) or_return

        db.relations = self
        self.state = Object_State.Normal

        relations_table__clear(self) or_return

        return nil
    }

    relations_table__terminate :: proc(self: ^Relations_Table) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        delete(self.parent, self.db.allocator) or_return
        delete(self.first_child, self.db.allocator) or_return
        delete(self.next_sibling, self.db.allocator) or_return
        delete(self.prev_sibling, self.db.allocator) or_return
        delete(self.children_count, self.db.allocator) or_return
        delete(self.scratch, self.db.allocator) or_return

        self.parent = nil
        self.first_child = nil
        self.next_sibling = nil
        self.prev_sibling = nil
        self.children_count = nil
        self.scratch = nil
        self.count = 0
        self.cap = 0

        self.db.relations = nil
        self.db = nil

        // Leave the table in Not_Initialized state (not Terminated) so the same
        // struct can be re-init'd without zeroing it first. See issue #8.
        self.state = Object_State.Not_Initialized

        return nil
    }

    relations_table__clear :: proc(self: ^Relations_Table) -> Error {
        if !relations_table__is_valid(self) do return API_Error.Object_Invalid

        for i := 0; i < len(self.parent); i += 1 {
            self.parent[i].ix = DELETED_INDEX
            self.first_child[i].ix = DELETED_INDEX
            self.next_sibling[i].ix = DELETED_INDEX
            self.prev_sibling[i].ix = DELETED_INDEX
            self.children_count[i] = 0
        }

        self.count = 0

        return nil
    }

    // Memory usage in bytes
    relations_table__memory_usage :: proc(self: ^Relations_Table) -> int {
        total := size_of(self^)

        if self.parent != nil         do total += size_of(self.parent[0]) * len(self.parent)
        if self.first_child != nil    do total += size_of(self.first_child[0]) * len(self.first_child)
        if self.next_sibling != nil   do total += size_of(self.next_sibling[0]) * len(self.next_sibling)
        if self.prev_sibling != nil   do total += size_of(self.prev_sibling[0]) * len(self.prev_sibling)
        if self.children_count != nil do total += size_of(self.children_count[0]) * len(self.children_count)
        if self.scratch != nil        do total += size_of(self.scratch[0]) * len(self.scratch)

        return total
    }

    // Number of parent links (relations)
    relations_table__len :: #force_inline proc "contextless" (self: ^Relations_Table) -> int {
        return self.count
    }

    relations_table__cap :: #force_inline proc "contextless" (self: ^Relations_Table) -> int {
        return self.cap
    }

    // Makes `parent` the parent of `child`, replacing child's previous parent (if any).
    // Returns Relation_Cycle if child == parent or child is an ancestor of parent.
    // Returns Container_Is_Full when creating a NEW link would exceed cap
    // (re-parenting an already-linked child always succeeds).
    relations_table__set_parent :: proc(self: ^Relations_Table, child: entity_id, parent: entity_id, loc := #caller_location) -> Error #no_bounds_check {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(self.state == Object_State.Normal, loc = loc)
        }

        database__is_entity_correct(self.db, child) or_return
        database__is_entity_correct(self.db, parent) or_return

        if child == parent do return API_Error.Relation_Cycle

        old_parent := self.parent[child.ix]
        if old_parent == parent do return nil // no-op, already the parent

        // Cycle check: walk up parent's ancestor chain; if we reach child,
        // parenting would close a cycle. O(depth), before any mutation.
        p := self.parent[parent.ix]
        for !is_not_set(p) {
            if p == child do return API_Error.Relation_Cycle
            p = self.parent[p.ix]
        }

        if !is_not_set(old_parent) {
            relations_table__unlink_child(self, old_parent, child)
        } else if self.count >= self.cap {
            return oc.Core_Error.Container_Is_Full
        }

        relations_table__link_child(self, parent, child)

        return nil
    }

    // Removes child's parent link. Returns Not_Found if child has no parent.
    relations_table__remove_parent :: proc(self: ^Relations_Table, child: entity_id, loc := #caller_location) -> Error #no_bounds_check {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(self.state == Object_State.Normal, loc = loc)
        }

        database__is_entity_correct(self.db, child) or_return

        old_parent := self.parent[child.ix]
        if is_not_set(old_parent) do return oc.Core_Error.Not_Found

        relations_table__unlink_child(self, old_parent, child)

        return nil
    }

    // Returns eid's parent, or entity_id{ix = DELETED_INDEX} if it has none.
    relations_table__parent_of :: proc(self: ^Relations_Table, eid: entity_id) -> (res: entity_id, err: Error) #no_bounds_check {
        res.ix = DELETED_INDEX
        database__is_entity_correct(self.db, eid) or_return

        return self.parent[eid.ix], nil
    }

    // Returns parent's children as a slice of the internal scratch buffer.
    // The slice is valid only until the next children_of call or any
    // structural change (set_parent/remove_parent/destroy_entity/clear) —
    // use it immediately, do not store it.
    relations_table__children_of :: proc(self: ^Relations_Table, parent: entity_id) -> (res: []entity_id, err: Error) #no_bounds_check {
        database__is_entity_correct(self.db, parent) or_return

        n := 0
        c := self.first_child[parent.ix]
        for !is_not_set(c) {
            // scratch holds at most cap children; exceeding it means the
            // sibling links are corrupted (e.g. a cycle) — fail loudly instead
            // of writing out of bounds
            when VALIDATIONS do assert(n < len(self.scratch), "relations links corrupted — sibling list exceeds cap")
            self.scratch[n] = c
            n += 1
            c = self.next_sibling[c.ix]
        }

        return self.scratch[:n], nil
    }

    relations_table__children_count :: proc(self: ^Relations_Table, eid: entity_id) -> (res: int, err: Error) #no_bounds_check {
        database__is_entity_correct(self.db, eid) or_return

        return int(self.children_count[eid.ix]), nil
    }

    // Is `a` a child of `b`?
    relations_table__is_child_of :: proc(self: ^Relations_Table, a: entity_id, b: entity_id) -> (res: bool, err: Error) #no_bounds_check {
        database__is_entity_correct(self.db, a) or_return
        database__is_entity_correct(self.db, b) or_return

        return self.parent[a.ix] == b, nil
    }

    // Is `a` the parent of `b`?
    relations_table__is_parent_of :: proc(self: ^Relations_Table, a: entity_id, b: entity_id) -> (res: bool, err: Error) #no_bounds_check {
        database__is_entity_correct(self.db, a) or_return
        database__is_entity_correct(self.db, b) or_return

        return self.parent[b.ix] == a, nil
    }

    // True if eid has a parent or at least one child.
    relations_table__has_relations :: proc(self: ^Relations_Table, eid: entity_id) -> (res: bool, err: Error) #no_bounds_check {
        database__is_entity_correct(self.db, eid) or_return

        return !is_not_set(self.parent[eid.ix]) || !is_not_set(self.first_child[eid.ix]), nil
    }

    // Does `eid` relate to `target` directly — as its child or its parent?
    relations_table__is_relation_of :: proc(self: ^Relations_Table, target: entity_id, eid: entity_id) -> (res: bool, err: Error) #no_bounds_check {
        database__is_entity_correct(self.db, target) or_return
        database__is_entity_correct(self.db, eid) or_return

        return self.parent[eid.ix] == target || self.parent[target.ix] == eid, nil
    }

///////////////////////////////////////////////////////////////////////////////
// Relations_Table private

    // Pushes child at the head of parent's child list. O(1).
    @(private)
    relations_table__link_child :: #force_inline proc "contextless" (self: ^Relations_Table, parent: entity_id, child: entity_id) #no_bounds_check {
        head := self.first_child[parent.ix]

        self.next_sibling[child.ix] = head
        self.prev_sibling[child.ix].ix = DELETED_INDEX
        if !is_not_set(head) do self.prev_sibling[head.ix] = child

        self.first_child[parent.ix] = child
        self.parent[child.ix] = parent

        self.children_count[parent.ix] += 1
        self.count += 1
    }

    // Unlinks child from parent's child list. O(1) via the doubly-linked siblings.
    @(private)
    relations_table__unlink_child :: #force_inline proc "contextless" (self: ^Relations_Table, parent: entity_id, child: entity_id) #no_bounds_check {
        prev := self.prev_sibling[child.ix]
        next := self.next_sibling[child.ix]

        if !is_not_set(prev) do self.next_sibling[prev.ix] = next
        else do self.first_child[parent.ix] = next

        if !is_not_set(next) do self.prev_sibling[next.ix] = prev

        self.parent[child.ix].ix = DELETED_INDEX
        self.next_sibling[child.ix].ix = DELETED_INDEX
        self.prev_sibling[child.ix].ix = DELETED_INDEX

        self.children_count[parent.ix] -= 1
        self.count -= 1
    }

    // Removes all of eid's relations: unlinks it from its parent and orphans
    // its children (their parent link is cleared). Called by
    // database__destroy_entity; eid is already validated by the caller.
    @(private)
    relations_table__unlink_entity :: proc "contextless" (self: ^Relations_Table, eid: entity_id) #no_bounds_check {
        p := self.parent[eid.ix]
        if !is_not_set(p) do relations_table__unlink_child(self, p, eid)

        c := self.first_child[eid.ix]
        for !is_not_set(c) {
            next := self.next_sibling[c.ix]

            self.parent[c.ix].ix = DELETED_INDEX
            self.next_sibling[c.ix].ix = DELETED_INDEX
            self.prev_sibling[c.ix].ix = DELETED_INDEX
            self.count -= 1

            c = next
        }

        self.first_child[eid.ix].ix = DELETED_INDEX
        self.children_count[eid.ix] = 0
    }
