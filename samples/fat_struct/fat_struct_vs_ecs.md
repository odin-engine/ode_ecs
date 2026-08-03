### Fat Structs vs. ECS vs. Hybrid architectures

I think it's important not to overengineer your game. Hybrid fat structs should satisfy most small games. Or you can use a "Fat Structs + ECS" hybrid.

Building a good ECS library is not that simple and is a rabbit hole by itself. My advice: build your game, not an ECS, unless you want to explore ideas and learn, like I did. Or build your game and use an ECS library.

By overengineering, I mean things like:

Should inventory items be their own separate entities in ECS? Depends.

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
A working example of this idea is [here](rpg/main.odin).

Do we need a separate database for Item_Instances or ecs.Table, for example? It depends on your game. Maybe, if you really want to track the same item between inventories and places in the world.

Bottom line for me is:
- don't be shy to mix architectures, using the best tool for the task
- don't be shy to use multiple ODE_ECS databases to modularize entities

Other examples:

- An example of hybrid Fat Structs architecture: [here](fat/main.odin)
- The same example in full ECS architecture: [here](ecs/main.odin)
- The same example in a mix of Fat Structs and ECS architecture: [here](mix/main.odin)

More on Fat Structs vs. ECS in games: [here](in_games.md)