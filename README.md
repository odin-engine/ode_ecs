![alt text](https://github.com/odin-engine/imgs/blob/main/ode_ecs_v1.png?raw=true)
# ODE_ECS (Entity-Component-System)

ODE_ECS is a simple, fast and type-safe ECS written in Odin.

# Features  

- Simple and type-safe API.  
- Fast — if you find a faster ECS written in Odin, please open an issue and let me know.
- Everything is preallocated (no hidden memory reallocations during a game loop).  
- All important operations are **O(1)**, with no hidden linked lists.  
- Supports custom allocators.  
- No additional data is stored with components, ensuring maximum cache efficiency.  
- Iteration over components or views is as fast as possible (no iteration over empty or deleted components; data is 100% dense for optimal caching).  
- Entity IDs are not just indices; they also include a generation number. This ensures that if you save an entity ID and the entity is destroyed, any new entity created with the same index will have a different generation, letting you know it is not the same entity.  
- Supports an unlimited number of component types (default is 128).  
- Optional parent/child entity relations (`Relations_Table`): O(1) re-parenting, cycle protection, automatic cleanup on destroy, and cascading `destroy_entity(&db, eid, destroy_children=true)`.  
- zlib License (even more permissive than both the MIT License and the BSD 3-Clause License). 
- Basic sample is available [here](https://github.com/odin-engine/ode_ecs/blob/main/samples/basics/main.odin).  
- Tests are [here](https://github.com/odin-engine/ode_ecs/blob/main/tests/ecs_test.odin).  
- An example with 100,000 entities is available [here](https://github.com/odin-engine/ode_ecs/blob/main/samples/sample01/main.odin).  
- An example demonstrating how to optimize your ECS can be found [here](https://github.com/odin-engine/ode_ecs/blob/main/samples/sample02/main.odin). 

# How to install

Use `git clone` to clone this repository into your project folder, and then `import ecs "ode_ecs"`: 

```  
    git clone https://github.com/odin-engine/ode_ecs.git
```  

# Basics  

An **_Entity_** is simply an ID. All data associated with an entity is stored in its components.  

A **_Component_** represents your data and can be defined using a `struct` or other types in Odin. An entity can have many components.  

An ECS **_Database_** is a database similar to a relational database instance, but for entities and components. Other ECS libraries refer to this concept as _Worlds_ or _Scenes_. However, I believe `Database` is a better term because a single game world can use multiple ECS databases, and a single game scene can also use multiple ECS databases.  

When initializing a `Database`, you can specify the maximum `entities_cap` as well as the allocator:  

```odin
    import ecs "ode_ecs"

    my_ecs: ecs.Database

    // in some procedure:
    ecs.init(&my_ecs, entities_cap=100, allocator=my_allocator)
```  

Every other object (tables, views) linked to `my_ecs` will now use `my_allocator` to allocate memory.  

>**NOTE:** ODE_ECS never reallocates memory automatically. The reason for this is the same as avoiding garbage collectors — to prevent unexpected performance drops caused by unexpected memory allocations, deallocations, or memory copying. Usually, you know the maximum number of entities you want in your game, so you can preallocate that amount ahead of time.  

You can have as many ECS databases in your game as you want:  

```odin
    ecs1: ecs.Database
    ecs2: ecs.Database

    ecs.init(&ecs1, entities_cap=100)
    ecs.init(&ecs2, entities_cap=200)
```  

The other two main types of objects in ODE_ECS are tables and views.  

---

### **Table**  

A component **_Table_** is a dense array of components of the same type. I named it "table" because it is very similar to the concept of a table in relational databases. Each different type of component requires a separate table. For example, you might have a `positions` table for `Position` components and an `ais` table for `AI` components.  

If you have a `Position` component, you can create a table like this:  

```odin
    Position :: struct { x, y: int } // component

    positions : ecs.Table(Position)  // component table

    ecs.table_init(&positions, db=&my_ecs, cap=100)
```  

To create an entity, you can do this:  

```odin
    robot, _ = ecs.create_entity(&my_ecs)
```  

Now you can add a `Position` component to the `robot` entity:  

```odin
    // Assign one component from the table to the entity
    position, _ = ecs.add_component(&positions, robot)

    // Get the existing component from the table for the entity
    position = ecs.get_component(&positions, robot)
```  

To iterate over components in a table, you can do this:  

```odin
    for &pos in positions.rows {
        fmt.println(pos)
    }
```  

Or this:  

```odin
    for i := 0; i < ecs.table_len(positions); i += 1 {
        pos := &positions.rows[i]
        fmt.println(pos^)
    }
```  

>**NOTE:** Iterating over components in a `Table` is as fast as possible because it is just iterating over a slice/array. There are no "empty" or "deleted" components in `positions.rows`.  

You can get the `entity_id` by index during iteration over components:  

```odin
    eid: ecs.entity_id
    for &pos, index in positions.rows {
        eid = ecs.get_entity(&positions, index)
        fmt.println(eid, pos)
    }
```  

Using an entity, you can access its other components:  

```odin
    eid: ecs.entity_id
    ai: ^AI // AI component
    for &pos, index in positions.rows {
        eid = ecs.get_entity(&positions, index)
        ai = ecs.get_component(&ais, eid) // assuming we have variable `ais: Table(AI)`
        fmt.println(eid, pos, ai)
    }
```  

---

### **View**  

A **_View_** is used when you want to iterate over entities that have specific components. A View does not store component data or copies of it. Instead, it holds pointers to component data stored in tables for fast access.
To initialize a view for entities with both `Position` and `AI` components, you can do this:  

```odin
    ecs1: ecs.Database

    positions: Table(Position)
    ais: Table(AI)

    view1: ecs.View
    
    // ... skipping initialization of other objects

    // This view will reference all entities that have Position and AI components
    ecs.view_init(&view1, &ecs1, {&positions, &ais})
```  

At this point, the view might be empty because it tracks entities as they are created/destroyed or as components are added/removed. If you create the view before creating entities or adding/removing components, it will stay up to date. If you initialize your view at a later stage, you can use the `rebuild()` procedure to update it:  

```odin
    ecs.rebuild(&view1)  // This operation might be relatively costly as it iterates over components
```  

To iterate over views, you need to use an `Iterator`:  

```odin
    it: ecs.Iterator

    ecs.iterator_init(&it, &view1)

    for ecs.iterator_next(&it) {
        // ...
    }
```  

To get an entity or its components inside the iterator loop, you can do this:  

```odin
    eid: ecs.entity_id
    pos: ^Position // Position component
    ai: ^AI        // AI component

    for ecs.iterator_next(&it) {
        // To get the entity
        eid = ecs.get_entity(&it)

        // To get the Position component
        pos = ecs.get_component(&positions, &it)

        // To get the AI component
        ai = ecs.get_component(&ais, &it)

        // ...
    }
```

The `Iterator` automatically uses a *dense fast path* when the view is "aligned" — when view row `i` corresponds to row `i` in every `Table` of the view (which is the common case: it holds whenever components are added to tables in the same order per entity, and it survives entity despawn/respawn churn). In that case components are read directly from the tables' dense arrays, which is roughly 2x faster than going through the view's pointer records. This is fully automatic and falls back transparently when the view is not aligned.

For the absolute fastest iteration, `view_dense_slice` returns the raw component slices in view-row order when the view is aligned (and `nil` otherwise). A plain loop over these slices compiles to a raw SoA sweep (~2x faster still than the iterator):

```odin
    pos_slice := ecs.view_dense_slice(&view1, &positions)
    ai_slice  := ecs.view_dense_slice(&view1, &ais)

    if pos_slice != nil && ai_slice != nil {
        for i in 0..<len(pos_slice) {
            // pos_slice[i] and ai_slice[i] belong to the same entity (view row i)
        }
    } else {
        // View is not dense-aligned: iterate with Iterator as usual
    }
```

The slices are invalidated by any structural change (adding/removing components, creating/destroying entities) — use them immediately, do not store them.

---

### Tag_Table

`Tag_Table` is a variation of `Table`, but it doesn’t contain any components. A `Tag_Table` only “tags” entities. You can create a `Tag_Table` like this:

```odin
    is_alive : ecs.Tag_Table
    ecs.tag_table__init(&is_alive, &db, 10)
```

Then you can tag or untag entities like this:

```odin
    human, _ = ecs.create_entity(&db)
    
    ecs.tag(&is_alive, human)       // add tag
    ecs.untag(&is_alive, human)    // remove tag
```

`Tag_Table` is especially useful with `View`:

```odin
    view : ecs.View

    // create a view for all entities that have AI, Position components, and the alive tag
    ecs.view_init(&view, &db, {&ais, &positions, &is_alive_table})
```

You can iterate over tagged entities like this:

```odin
    // iterate over entities tagged in is_alive_table
    fmt.println("Tagged entities:")
    for eid in is_alive_table.rows {
        fmt.println("Entity tagged in `is_alive_table`:", eid)
    }
```

[Sample06](https://github.com/odin-engine/ode_ecs/blob/main/samples/sample06/main.odin) demonstrates how to use `Tag_Table`.

---

### Relations_Table (parent/child entity relations)

`Relations_Table` is an optional table that adds parent/child relations between entities: every entity can have at most one parent and any number of children. Like everything else in ODE_ECS, all of its memory is preallocated at init and every operation is a direct array access (adding, removing and re-parenting are all **O(1)**). Only one `Relations_Table` can be created per `Database`:

```odin
    rt : ecs.Relations_Table

    // cap limits the number of concurrent parent links (relations)
    ecs.relations_table__init(&rt, &db, cap=100)
```

Once created, relations are managed through database-level procedures (they return `Relations_Table_Not_Created` if you call them before creating the table):

```odin
    parent, _ := ecs.create_entity(&db)
    child, _  := ecs.create_entity(&db)

    ecs.set_parent(&db, child, parent)      // make `parent` the parent of `child`
    ecs.remove_parent(&db, child)           // remove the link (alias: ecs.unparent)

    p, _        := ecs.parent_of(&db, child)      // parent id, or .ix == ecs.DELETED_INDEX if none
    children, _ := ecs.children_of(&db, parent)   // []entity_id — use immediately, see note below
    n, _        := ecs.children_count(&db, parent)

    yes, _ = ecs.is_child_of(&db, child, parent)    // is `child` a child of `parent`?
    yes, _ = ecs.is_parent_of(&db, parent, child)   // is `parent` the parent of `child`?
    yes, _ = ecs.has_relations(&db, child)          // does entity have a parent or children?
    yes, _ = ecs.is_relation_of(&db, parent, child) // direct link in either direction
```

`set_parent` re-parents in place (replacing the previous parent) and always guards against cycles: making an entity a descendant of itself returns `Relation_Cycle` and changes nothing. The check walks the new parent's ancestor chain, so it costs O(tree depth).

**Cleanup is automatic.** Destroying an entity unlinks it from its parent and *orphans* its children (their parent link is cleared). To destroy a whole subtree instead, use the new optional flag on `destroy_entity`:

```odin
    ecs.destroy_entity(&db, boss, destroy_children=true) // destroys boss and all descendants
```

The cascade is iterative (no recursion) and destroys the deepest entities first; each destroyed entity is removed from all its component tables as usual.

>**NOTE:** The slice returned by `children_of` points into an internal preallocated buffer. It is valid only until the next `children_of` call or any structural change (set_parent / remove_parent / destroy_entity / clear) — use it immediately, do not store it.

>**NOTE:** Relations are not components: they do not affect `View`s. If you need to iterate "all entities that have a parent", pair the feature with a `Tag_Table`.

---

# Tips

### TIP: Avoid mutating tables while iterating over them 

For example, avoid doing this:

```Odin
for d in my_tags_table.rows {
    ecs.destroy_entity(&my_db, d)  // Mutates my_tags_table during iteration!
}
```
Correct pattern: Drain the table by repeatedly taking row `0` until it is empty:
```Odin
for ecs.table_len(&my_tags_table) > 0 {
    d := my_tags_table.rows[0]
    ecs.destroy_entity(&my_db, d)   
}
```
Or pause tail swapping for the duration of the iteration — see the next section.

### Mutating tables while iterating: pause_tail_swap / resume_tail_swap / pack

`ecs.pause_tail_swap(&db)` switches all component tables (`Table`, `Compact_Table`, `Tiny_Table`) into deferred-tail-swap mode: removing a component (or destroying an entity) clears the component **in place** instead of tail-swapping, so no other component moves — rows and component pointers stay stable while you iterate. The vacated row becomes a *hole*: `get_entity` for it returns an id with `ix == ecs.DELETED_INDEX`, and `table_len` keeps reporting the full row span (holes included). Views are still notified as usual.

```Odin
ecs.pause_tail_swap(&db)

for i in 0..<ecs.table_len(&monsters) {
    eid := ecs.get_entity(&monsters, i)
    if eid.ix == ecs.DELETED_INDEX do continue // hole (already removed this frame)

    monster := ecs.get_component(&monsters, eid)
    if monster.hp <= 0 do ecs.destroy_entity(&db, eid) // safe: nothing moves
}

ecs.resume_tail_swap(&db) // packs all tables with holes and re-enables tail swap
```

`ecs.resume_tail_swap(&db)` restores normal tail swapping and *packs* every table that accumulated holes. `ecs.pack(&table)` is also available directly — for example mid-pause, when a table with many holes reports full (new components are always appended at the tail, so holes don't free capacity until packed).

### TIP: Be aware that component locations might shift within tables.

ODE_ECS performs tail swaps when you remove components from a table (mutating a table) to optimize iteration speeds and avoid empty slots. This means you should avoid re-using pointers to components after a table has been mutated (e.g., by removing the component or its owning entity). Instead, save and use entity IDs to retrieve the updated component pointer after each table mutation. (Exception: while tail swapping is paused, pointers stay stable until the table is packed.)

---

# How to Run Samples and Tests  

To run samples, navigate to the appropriate folder (`samples/basic` or `samples/sample01`) and execute:  

```  
    odin run . -o:speed
```  

To run tests, go to the `tests` folder and execute:  

```  
    odin test .  
```  

# Advanced

### Entity  

In ODE_ECS, an entity is simply an ID. In the `ecs.odin` file, an entity is defined as follows:  

```odin
    entity_id ::        oc.ix_gen
```  

The `ix_gen` is defined like this:  

```odin
    ix_gen :: bit_field i64 {
        ix: int | 56,       // index
        gen: uint | 8,      // generation
    }
```  

This approach is very useful because it ensures that if you save an entity ID somewhere and the entity is destroyed, any new entity created with the same index will have a different generation, letting you know it is not the same entity.  

If an entity has been destroyed via `ecs.destroy_entity()`, use `is_entity_expired` to check its status:

```odin
    ecs.is_entity_expired(&db, my_entity_id) // returns true if the entity was destroyed
```

This procedure compares the entity's generation (`gen`) against the database records. 

### View Filter

A view filter is a `proc` that you can pass to `ecs.view_init` to filter view data. It allows you to create views based on any custom logic.

```odin
    view: ecs.View

    My_User_Data :: struct {
        human_eid: ecs.entity_id,
        chair_eid: ecs.entity_id,
    }

    // if this proc returns true, the entity (and its components) will be added to the view
    my_filter :: proc(row: ^ecs.View_Row, user_data: rawptr = nil) -> bool {
        if user_data == nil do return false

        eid := ecs.get_entity(row)
        data := (^My_User_Data)(user_data)

        // using entities saved in user_data
        if eid == data.human_eid || eid == data.chair_eid do return true 

        return false
    }

    my_user_data := My_User_Data{
        human_eid = human,
        chair_eid = chair,
    }

    view.user_data = &my_user_data  // set user_data!

    err = ecs.view_init(&view, &db, {&is_alive_table}, my_filter)
```

The `my_filter` proc determines whether an entity (and its components) will be added to the view.

Check [Sample06](https://github.com/odin-engine/ode_ecs/blob/main/samples/sample06/main.odin) for an example of how to use a View filter.

---
### Maximum Number of Component Types  

By default, the maximum number of component types is 128. However, you can have an unlimited number of component types. To increase the maximum number of component types, modify `TABLES_MULT` either in `ecs.odin` or by using the command-line define `ECS_TABLES_MULT`:  

```odin
    TABLES_MULT :: #config(ECS_TABLES_MULT, 1)
```  

A value of `2` will set the maximum number of component types to 256, `3` will increase it to 384, `4` to 512, and so on. However, lower values make ODE_ECS slightly faster and more memory-efficient, so increase it only if necessary.

# F.A.Q

### 1. Thread safety?

This is a data-oriented library with a "no hidden costs / preallocate everything" philosophy. Baking locks into every call is exactly the kind of hidden cost it avoids. The idiomatic answer is to not make the core thread-safe, and instead parallelize at a higher level where synchronization amortizes to zero:

- Phase separation: run read/compute systems in parallel, then apply all structural changes (create/destroy/add/remove) in a single-threaded sync point. The parallel phase touches no shared mutable bookkeeping.

- Data-parallel iteration is already a designed-in feature. iterator__init(self, view, start_row, end_row) exists precisely for this — its comment says "Use start_row and end_row if you want to process View in batches."

- One Database per thread/region for fully independent workloads — the API explicitly supports many databases, and they share nothing.

So the honest summary: making the core internally thread-safe would meaningfully hurt — per-element locking is a 2–10× hit on the headline iteration path and per-mutation locking serializes the very thing you parallelized for. But thread-safe usage via batched parallel iteration over immutable component data plus a single-threaded structural-mutation phase costs essentially nothing.

### 2. How to iterate over all entities?

Iterating over all entities is ECS anti-pattern. You have should have systems (basically procs) that iterate over components related to those systems. Like network system should iterate over network copmonenents to process them. Physics system should iterate over physics components to process them etc.


# Documentation
- [Updates Timeline](https://github.com/odin-engine/ode_ecs/wiki/Updates-Timeline)    
- [Documentation](https://github.com/odin-engine/ode_ecs/wiki/Documentation)

## If you have any questions about ODE_ECS or encounter any issues, please open an issue ticket, and I’ll try to answer, fix, or add new functionality.
