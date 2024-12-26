![alt text](https://github.com/odin-engine/imgs/blob/main/ode_ecs_v1.png?raw=true)
# ODE_ECS (Entity-Component-System)

ODE_ECS is a simple, fast, and type-safe ECS written in Odin.

# Features  

- Simple and type-safe API.  
- Everything is preallocated (no hidden memory reallocations during a game loop).  
- All important operations are **O(1)**, with no hidden linked lists.  
- Supports custom allocators.  
- No additional data is stored with components, ensuring maximum cache efficiency.  
- Iteration over components or views is as fast as possible (no iteration over empty or deleted components; data is 100% dense for optimal caching).  
- Entity IDs are not just indices; they also include a generation number. This ensures that if you save an entity ID and the entity is destroyed, any new entity created with the same index will have a different generation, letting you know it is not the same entity.  
- Supports an unlimited number of component types (default is 128).  
- MIT License.  
- Basic sample is available [here](https://github.com/odin-engine/ode_ecs/blob/main/samples/basic/main.odin).  
- Tests are available [here](https://github.com/odin-engine/ode_ecs/blob/main/tests/ecs_test.odin).  
- An example with 100,000 entities is available [here](https://github.com/odin-engine/ode_ecs/blob/main/samples/sample01/main.odin).  

# How to install

Use `git clone --recursive` to clone this repository into your project, and then `import ecs "ode_ecs"`: 

```  
    git clone --recursive https://github.com/odin-engine/ode_ecs.git
```  

> **NOTE:** The `--recursive` flag is required because this project contains a submodule. If you forgot to use the `--recursive` flag, you can run the following commands in the `ode_ecs` folder to download the submodule:  

```  
    git submodule init  
    git submodule update  
```  

# Basics  

An `Entity` is simply an ID. All data associated with an entity is stored in its components.  

A `Component` represents your data and can be defined using a `struct` or other types in Odin. An entity can have many components.  

An ECS **_Database_** is a database similar to a relational database instance, but for entities and components. Other ECS libraries refer to this concept as _Worlds_ or _Scenes_. However, I believe `Database` is a better term because a single game world can use multiple ECS databases, and a single game scene can also use multiple ECS databases.  

When initializing a `Database`, you can specify the maximum `entities_cap` as well as the allocator:  

```odin
    import ecs "ode_ecs"

    my_ecs: ecs.Database

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

The other two main objects in ODE_ECS are tables and views.  

---

### **Table**  

A component **_Table_** is a dense array of components of the same type. I named it "table" because it is very similar to the concept of a table in relational databases. Each different type of component requires a separate table. For example, you might have a `positions` table for `Position` components and an `ais` table for `AI` components.  

If you have a `Position` component, you can create a table like this:  

```odin
    Position :: struct { x, y: int } // component

    positions : ecs.Table(Position)  // component table

    ecs.table_init(&positions, ecs=&my_ecs, cap=100)
```  

To create an entity, you can do this:  

```odin
    robot, _ = ecs.create_entity(&ecs)
```  

Now you can add a `Position` component to the `robot` entity:  

```odin
    // Assign one component from the table to the entity
    position, _ = ecs.add_component(&positions, robot)

    // Get the existing component from the table for the entity
    position, _ = ecs.get_component(&positions, robot)
```  

To iterate over components in a table, you can do this:  

```odin
    for &pos in positions.records {
        fmt.println(pos)
    }
```  

Or this:  

```odin
    for i := 0; i < ecs.table_len(positions); i += 1 {
        pos = &positions.records[i]
        fmt.println(pos)
    }
```  

>**NOTE:** Iterating over components in a `Table` is as fast as possible because it is just iterating over a slice/array. There are no "empty" or "deleted" components in `positions.records`.  

You can get the `entity_id` by index during iteration over components:  

```odin
    eid: ecs.entity_id
    for &pos, index in positions.records {
        eid = ecs.get_entity(&positions, index)
        fmt.println(eid, pos)
    }
```  

Using an entity, you can access its other components:  

```odin
    eid: ecs.entity_id
    ai: ^AI // AI component
    for &pos, index in positions.records {
        eid = ecs.get_entity(&positions, index)
        ai, _ = ecs.get_component(&ais, eid) // assuming we have variable `ais: Table(AI)`
        fmt.println(eid, pos, ai)
    }
```  

---

### **View**  

A **_View_** is used when you want to iterate over entities that have specific components. To initialize a view for entities with both `Position` and `AI` components, you can do this:  

```odin
    ecs1: ecs.Database

    positions: Table(Position)
    ais: Table(AI)

    view1: ecs.View
    
    // ... skipping initialization of other objects

    ecs.view_init(&view1, &ecs1, {&positions, &ais})
```  

At this point, the view might be empty because it tracks entities as they are created/destroyed or as components are added/removed. If you create the view before creating entities, it will stay up to date. If you initialize your view at a later stage, you can use the `rebuild()` procedure to update it:  

```odin
    ecs.rebuild(&view1)  // This operation might be relatively costly as it iterates over components
```  

To iterate over views, you need to use an `Iterator`:  

```odin
    it: ecs.Iterator

    ecs.iterator_init(&it, &view1)

    for ecs.iterator__next(&it) {
        // ...
    }
```  

To get an entity or its components inside the iterator loop, you can do this:  

```odin
    eid: ecs.entity_id
    pos: ^Position // Position component
    ai: ^AI        // AI component

    for ecs.iterator__next(&it) {
        // To get the entity
        eid = ecs.get_entity(&it)

        // To get the Position component
        pos = ecs.get_component(&positions, &it)

        // To get the AI component
        ai = ecs.get_component(&ais, &it)

        // ...
    }
```
# Advanced

### Public API

List of public procedures (public API) is [here](https://github.com/odin-engine/ode_ecs/blob/main/ecs.odin).

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

### Maximum Number of Component Types  

By default, the maximum number of component types is 128. However, you can have an unlimited number of component types. To increase the maximum number of component types, modify `TABLES_MULT` either in `ecs.odin` or by using the command-line define `ecs_tables_mult`:  

```odin
    TABLES_MULT :: #config(ecs_tables_mult, 1)
```  

A value of `2` will set the maximum number of component types to 256, `3` will increase it to 384, `4` to 512, and so on. However, lower values make ODE_ECS slightly faster and more memory-efficient, so increase it only if necessary.
