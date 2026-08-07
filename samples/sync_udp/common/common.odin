/*
    2026 (c) Oleh, https://github.com/zm69

    Schema shared by the sync_udp server and client samples (see sync.odin
    for the underlying delta-sync feature this demonstrates).
*/
package sync_udp_common

// ODE_ECS
    import ecs "../../../"

///////////////////////////////////////////////////////////////////////////////

    SERVER_PORT  :: 9877
    CLIENT_PORT  :: 9878
    ENTITY_COUNT :: 50
    TICK_COUNT   :: 40

///////////////////////////////////////////////////////////////////////////////
// Components

    Position :: struct { x, y: f32 }
    Health   :: struct { hp, max_hp: int }
    // Stunned has no data — it is a Tag_Table membership, structural-only.

    World :: struct {
        db:        ecs.Database,
        positions: ecs.Table(Position),
        healths:   ecs.Compact_Table(Health),
        stunned:   ecs.Tag_Table,
    }

    // Server and client both call this, in this exact order, at startup —
    // that keeps their table ids in lockstep, which sync's wire format relies
    // on (a table_id on the wire only means anything if both sides registered
    // their tables in the same order).
    world_init :: proc(w: ^World, allocator := context.allocator) -> ecs.Error {
        ecs.init(&w.db, entities_cap = ENTITY_COUNT, allocator = allocator) or_return
        ecs.table_init(&w.positions, &w.db, ENTITY_COUNT) or_return
        ecs.compact_table__init(&w.healths, &w.db, ENTITY_COUNT) or_return
        ecs.tag_table__init(&w.stunned, &w.db, ENTITY_COUNT) or_return
        return nil
    }

    world_terminate :: proc(w: ^World) {
        ecs.terminate(&w.db)
    }

    // Pre-allocates a fixed pool of ENTITY_COUNT entities. Server and client
    // both call this identically at startup — entity_id's underlying id
    // allocator is a deterministic index counter (see ode_core/ix_gen.odin),
    // so as long as neither side destroys or creates entities independently
    // afterwards, entity N means the exact same entity_id (index + generation)
    // on both sides, with no join handshake required.
    //
    // This is a deliberate simplification for the sample: sync.odin's
    // apply_delta tolerantly SKIPS any structural/value record naming an
    // entity_id the receiving Database doesn't already recognize (see its own
    // doc comment) — it never creates entities on the receiver's behalf. A
    // real deployment would instead bootstrap a newly-joining client with a
    // full serialization.odin snapshot (database__serialize/deserialize),
    // which establishes the id space and initial state in one shot, then
    // switch to delta_sync from there (see sync_channel__resync's doc comment
    // for why the two compose correctly). Sidestepped here so the sample can
    // focus on the delta-sync wire path itself.
    world_spawn_pool :: proc(w: ^World) -> (eids: [ENTITY_COUNT]ecs.entity_id, err: ecs.Error) {
        for i in 0..<ENTITY_COUNT {
            eids[i] = ecs.create_entity(&w.db) or_return
        }
        return
    }
