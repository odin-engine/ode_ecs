# Fat Struct Is Just a Fat Component

Fat Struct vs. ECS discussion is hot but I think that Fat Struct is just a fat component. You control granularity of your components. No one is telling you that you must extract position data into one component and velocity data into another component. You can unite them and other data into a fat component and still use ODE_ECS for its other benefits without any disadvantages.

For example, you have this hybrid Fat Struct:

```Odin
    // Primary Monolithic Struct (Fits within 64-byte cache line)
    // A 64-byte cache line is the fundamental, non-divisible unit of data transfer between main
    // memory (RAM) and a CPU’s internal cache hierarchy (L1, L2, L3) on virtually all
    // modern x86, x64, and ARM processors.
    Entity :: struct #align(16) {
        id:               u32,
        flags:            Entity_Flags,

        // Handles pointing into dedicated secondary pools
        inventory_handle: u16,
        ai_handle:        u16,

        // Hot-path data used in main update loops
        position:         [3]f32,
        velocity:         [3]f32,
        health:           f32,
        padding:          [2]f32, // Padding to maintain alignment
    }
```

It's called hybrid Fat Struct, not just Fat Struct, because Inventory and AI_State are moved outside the struct to keep Entity within a 64-byte cache line for faster processing.

Inventory and AI_State can be defined something like this:

```Odin
    // Secondary Data Structures (Stored off-struct in dedicated pools)
    Inventory :: struct {
        owner_id: u32,
        gold:     u32,
        items:    [16]u16,
    }

    AI_State :: struct {
        owner_id: u32,
        target_id: u32,
        aggro_range: f32,
    }
```

Check out a working example of a pure hybrid Fat Struct without ECS here: [/samples/fat_struct/fat/main.odin](/samples/fat_struct/fat/main.odin).

Now you have to build your own code to support this approach. You need code to support entity id(s); note that they are without a generation number. You need code to support inventory_handle and ai_handle, and appropriate pools. Now, what would you do if you want to iterate over separate types of entities — say, only active entities, only NPCs, or only players? All of this is easily solved by ODE_ECS, and in an optimal way. You can just treat the fat struct as a fat component and get all the benefits of ODE_ECS:

```Odin

    // One Table holding fat components.
    entities: ecs.Table(Entity)
```

And you can easily iterate your Fat Structs like this:

```Odin
    for &e in ecs.slice(&entities) {
        if .Active not_in e.flags || .Has_Physics not_in e.flags {
            continue
        }

        e.position += e.velocity * dt
    }
```

Using Fat Struct + ODE_ECS, you can get benefits like:

- automatic tracking of [entity IDs and generations](/README.md#entity).
- easily attaching `Inventory` and `AI_State` to an entity without worrying about handles, pools, or cleanup.
- deleting entities is automatically handled via tail-swap, so you never end up with holes in your entities array (i.e., you never iterate over holes). This can be disabled with [pause_packing](/README.md#mutating-tables-while-iterating-pause_packing--resume_packing--pack) if you wish.
- easily creating pre-calculated queries ([Views](/README.md#-view)) over entities (or entities + `Inventory` + `AI_State`, or other combinations) to make your code faster.
- if you decide to, easily adding more components to entities — for example, `Equipped_Gear` or `Abilities` — dynamically, with O(1) speed in ODE_ECS and minimal code.
- creating parent-child relationships between your entities.
- taking binary snapshots of your entities + components and writing them to a buffer or file.
- multithreading support.
- and more.

And all of this will probably work faster than your custom code.

A working example of Fat Struct as a fat component + ODE_ECS is in [/samples/fat_struct/fat_component/main.odin](/samples/fat_struct/fat_component/main.odin).

I created more samples while exploring this topic:

- The same example in a high-granularity ECS architecture: [/samples/fat_struct/ecs/main.odin](/samples/fat_struct/ecs/main.odin)
- The same example in a mix of Fat Struct (not a component) and ECS architecture: [/samples/fat_struct/mix/main.odin](/samples/fat_struct/mix/main.odin)

## Exploring how to implement inventory a bit more

Should inventory items be their own separate entities in ECS with their own `entity_id`? Depends.

I would probably create separate ODE_ECS databases for separate entity types. For example, players and NPCs share many components, so I would put them in one database.
Item templates and ability templates would go in their own separate databases.

One way to do it is like this:

```Odin
actors: ecs.Database // actors: players, NPCs and their components
item_templates: ecs.Database // sword, potion, chest piece, everything that can be put in inventory and their components
ability_templates: ecs.Database // super kick, shield bash, basic heal (you can attach them to different actors!) and their components
// etc.
```
 Then, for example, the `actors` database would use an `Inventory` component for players and maybe NPCs:

 ```Odin
    Item_Instance :: struct {
        template_id: ecs.entity_id, // item entity_id from the `item_templates` database
        count: int
    }

    Inventory :: struct {
        items: [INVENTORY_CAP]Item_Instance
    }
 ```

 Or players or NPCs from the `actors` database could have an `Abilities` component:

 ```Odin
    Ability_Instance :: struct {
        template_id: ecs.entity_id, // ability entity_id from the `ability_templates` database
        min_damage: f64,            // pre-calculated ability min damage for entity
        max_damage: f64,            // pre-calculated ability max damage for entity
    }

    Abilities :: struct {
        list: [ABILITIES_CAP]Ability_Instance // could be some map: ability template entity_id -> Ability_Instance for faster search
    }
 ```

 Now you can combine actors with different abilities and items.
 Some component types can be shared between databases, for example the `Description` component type:

 ```Odin
    // Story behind entity/item/ability
    Description :: struct {
        text: string
    }
 ```

It's not that complicated when using ODE_ECS, and it's easily scalable.
A working example of this idea is in [/samples/fat_struct/rpg/main.odin](/samples/fat_struct/rpg/main.odin).

Do we need a separate database for Item_Instances or ecs.Table, for example? It depends on your game. Maybe, if you really want to track the same item between inventories and places in the world.

Bottom line for me is: don't be shy to use multiple ODE_ECS databases to modularize entities.

More on Fat Struct vs. ECS in games: [in_games.md](in_games.md)
