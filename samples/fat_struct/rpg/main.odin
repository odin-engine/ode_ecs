/*
    2026 (c) Oleh, https://github.com/zm69

    RPG inventory example using ODE_ECS 

    Read more: ../../../docs/fat_struct_vs_ecs.md

    - Three independent ecs.Databases - actors (NPCs, players), item_templates, ability_templates.
    - Description reused as-is across all three databases, each with its own Table(Description) - create_template is one helper shared by both item_templates and ability_templates.
    - Item_Instance/Ability_Instance in the Player's Inventory/Abilities hold a template_id plus per-owner data (count, min_damage/max_damage); print_inventory/print_abilities resolve those ids against the correct database's Description table explicitly - the code makes visible that a template_id only means something in the database it came from.
    - Goblin NPC has Description + Abilities but no Inventory, confirmed via has_component printing false.
*/

package ode_ecs_fat_struct_rpg

// Core
    import "core:fmt"

// ODE_ECS
    import ecs "../../../src"

//
// Shared component
    Description :: struct {
        text: string,
    }

//
// actors-side components: template reference + per-owner instance data
    Item_Instance :: struct {
        template_id: ecs.entity_id, // key into item_templates
        count:       int,
    }

    Inventory :: struct {
        items: [INVENTORY_CAP]Item_Instance,
        count: int, // slots in use
    }

    Ability_Instance :: struct {
        template_id: ecs.entity_id, // key into ability_templates
        min_damage:  f64,
        max_damage:  f64,
    }

    Abilities :: struct {
        list:  [ABILITIES_CAP]Ability_Instance, // could be map instead, but this is a simple example
        count: int,
    }

//
// Config
//

    INVENTORY_CAP  :: 8
    ABILITIES_CAP  :: 4

//
// Helpers
//

    // Shared by both item_templates and ability_templates - same Description
    // type, different database.
    create_template :: proc(db: ^ecs.Database, descriptions: ^ecs.Table(Description), text: string) -> ecs.entity_id {
        eid, _ := ecs.create_entity(db)
        desc, _ := ecs.add_component(descriptions, eid)
        desc.text = text
        return eid
    }

    add_item :: proc(inv: ^Inventory, template_id: ecs.entity_id, count: int) {
        inv.items[inv.count] = Item_Instance{ template_id = template_id, count = count }
        inv.count += 1
    }

    add_ability :: proc(abilities: ^Abilities, template_id: ecs.entity_id, min_damage, max_damage: f64) {
        abilities.list[abilities.count] = Ability_Instance{ template_id = template_id, min_damage = min_damage, max_damage = max_damage }
        abilities.count += 1
    }

    // Resolves each Item_Instance's template_id against item_templates's own
    // Description Table - the same template_id would be meaningless looked
    // up in any other database.
    print_inventory :: proc(inv: ^Inventory, item_descriptions: ^ecs.Table(Description)) {
        for i in 0..<inv.count {
            item := inv.items[i]
            desc := ecs.get_component(item_descriptions, item.template_id)
            fmt.printfln("  x%d %s", item.count, desc.text)
        }
    }

    print_abilities :: proc(abilities: ^Abilities, ability_descriptions: ^ecs.Table(Description)) {
        for i in 0..<abilities.count {
            ab := abilities.list[i]
            desc := ecs.get_component(ability_descriptions, ab.template_id)
            fmt.printfln("  %s (%.1f-%.1f dmg)", desc.text, ab.min_damage, ab.max_damage)
        }
    }

//
// Main
//

    main :: proc() {
        //
        // item_templates database
        //

        item_templates: ecs.Database
        defer ecs.terminate(&item_templates)
        ecs.init(&item_templates, 10)

        item_descriptions: ecs.Table(Description)
        ecs.table_init(&item_descriptions, &item_templates, 10)

        sword         := create_template(&item_templates, &item_descriptions, "Sword - a finely balanced blade.")
        health_potion := create_template(&item_templates, &item_descriptions, "Health Potion - restores a modest amount of health.")

        //
        // ability_templates database
        //

        ability_templates: ecs.Database
        defer ecs.terminate(&ability_templates)
        ecs.init(&ability_templates, 10)

        ability_descriptions: ecs.Table(Description)
        ecs.table_init(&ability_descriptions, &ability_templates, 10)

        fireball   := create_template(&ability_templates, &ability_descriptions, "Fireball - hurls a bolt of fire at a single target.")
        frost_bolt := create_template(&ability_templates, &ability_descriptions, "Frost Bolt - chills and slows a single target.")
        bite       := create_template(&ability_templates, &ability_descriptions, "Bite - a vicious goblin bite.")

        //
        // actors database - players/NPCs
        //

        actors: ecs.Database
        defer ecs.terminate(&actors)
        ecs.init(&actors, 20)

        descriptions: ecs.Table(Description)
        inventories:  ecs.Table(Inventory)
        abilities_table: ecs.Table(Abilities)
        ecs.table_init(&descriptions, &actors, 20)
        ecs.table_init(&inventories, &actors, 20)
        ecs.table_init(&abilities_table, &actors, 20)

        // Player: Description + Inventory + Abilities
        player, _ := ecs.create_entity(&actors)

        player_desc, _ := ecs.add_component(&descriptions, player)
        player_desc.text = "A lone adventurer."

        player_inv, _ := ecs.add_component(&inventories, player)
        add_item(player_inv, sword, 1)
        add_item(player_inv, health_potion, 3)

        player_abilities, _ := ecs.add_component(&abilities_table, player)
        add_ability(player_abilities, fireball, 12.0, 18.0)
        add_ability(player_abilities, frost_bolt, 8.0, 14.0)

        // Goblin NPC: Description + Abilities only - no Inventory
        goblin, _ := ecs.create_entity(&actors)

        goblin_desc, _ := ecs.add_component(&descriptions, goblin)
        goblin_desc.text = "A snarling forest goblin."

        goblin_abilities, _ := ecs.add_component(&abilities_table, goblin)
        add_ability(goblin_abilities, bite, 2.0, 5.0)

        //
        // Print
        //

        fmt.println(player_desc.text)
        fmt.println("Inventory:")
        print_inventory(player_inv, &item_descriptions)
        fmt.println("Abilities:")
        print_abilities(player_abilities, &ability_descriptions)

        fmt.println()
        fmt.println(goblin_desc.text)
        fmt.println("Has inventory?", ecs.has_component(&inventories, goblin))
        fmt.println("Abilities:")
        print_abilities(goblin_abilities, &ability_descriptions)
    }
