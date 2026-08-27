/*
    2026 (c) Oleh, https://github.com/zm69

    UDP delta-sync sample — server side. Spawns a fixed entity pool, mutates a
    few entities' Position/Health every tick and toggles a Stunned tag, then
    sends only what changed via ecs.collect_delta over a UDP socket.

    The sync feature is off by default (see ecs.SYNC_ENABLED's doc comment) —
    build/run this with -define:ECS_SYNC_ENABLED=true, e.g.
    odin run . -define:ECS_SYNC_ENABLED=true

    Run the client first (it binds and blocks on recv), then run this.
*/
package ode_ecs_sync_udp_server

// Core
    import "core:fmt"
    import "core:net"
    import "core:time"

// ODE_ECS
    import ecs "../../../src"
    import common "../common"

main :: proc() {
    w: common.World
    defer common.world_terminate(&w)
    if err := common.world_init(&w); err != nil {
        fmt.eprintln("world_init failed:", err)
        return
    }

    eids, spawn_err := common.world_spawn_pool(&w)
    if spawn_err != nil {
        fmt.eprintln("world_spawn_pool failed:", spawn_err)
        return
    }

    ch: ecs.Sync_Channel
    defer ecs.sync_channel_terminate(&ch)
    if err := ecs.sync_channel_init(&ch, &w.db, 4); err != nil {
        fmt.eprintln("sync_channel_init failed:", err)
        return
    }
    if err := ecs.sync_register(&ch, &w.positions); err != nil {
        fmt.eprintln("sync_register(positions) failed:", err)
        return
    }
    if err := ecs.sync_register(&ch, &w.healths); err != nil {
        fmt.eprintln("sync_register(healths) failed:", err)
        return
    }
    if err := ecs.sync_register(&ch, &w.stunned); err != nil {
        fmt.eprintln("sync_register(stunned) failed:", err)
        return
    }

    for i in 0..<common.ENTITY_COUNT {
        pos, perr := ecs.add_component(&w.positions, eids[i])
        if perr != nil {
            fmt.eprintln("add_component(positions) failed:", perr)
            return
        }
        pos.x = f32(i)
        pos.y = 0

        hp, hperr := ecs.add_component(&w.healths, eids[i])
        if hperr != nil {
            fmt.eprintln("add_component(healths) failed:", hperr)
            return
        }
        hp.hp = 100
        hp.max_hp = 100
    }

    socket, sock_err := net.make_bound_udp_socket(net.IP4_Loopback, common.SERVER_PORT)
    if sock_err != nil {
        fmt.eprintln("make_bound_udp_socket failed:", sock_err)
        return
    }
    defer net.close(socket)

    client_ep := net.Endpoint{ address = net.IP4_Loopback, port = common.CLIENT_PORT }

    buf := make([]byte, ecs.delta_max_size(&ch))
    defer delete(buf)

    total_bytes := 0

    fmt.println("Server: sending", common.TICK_COUNT, "ticks of delta updates to", client_ep, "...")

    for tick in 0..<common.TICK_COUNT {
        for k in 0..<5 {
            i := (tick * 5 + k) % common.ENTITY_COUNT

            pos := ecs.get_component_mut(&w.positions, eids[i])
            pos.x += 1
            pos.y = f32(tick)

            hp := ecs.get_component_mut(&w.healths, eids[i])
            hp.hp -= 1
            if hp.hp < 0 do hp.hp = 100
        }

        stun_target := eids[tick % common.ENTITY_COUNT]
        if ecs.has_tag(&w.stunned, stun_target) {
            _ = ecs.remove_tag(&w.stunned, stun_target)
        } else {
            _ = ecs.add_tag(&w.stunned, stun_target)
        }

        written, werr := ecs.collect_delta(&ch, buf)
        if werr != nil {
            fmt.eprintln("collect_delta failed:", werr)
            return
        }

        _, send_err := net.send_udp(socket, buf[:written], client_ep)
        if send_err != .None {
            fmt.eprintln("send_udp failed:", send_err)
            return
        }
        total_bytes += written

        time.sleep(20 * time.Millisecond)
    }

    full_size, size_err := ecs.serialized_size(&w.db)
    if size_err != nil {
        fmt.eprintln("serialized_size failed:", size_err)
        return
    }
    fmt.println("Server: done.", common.TICK_COUNT, "ticks,", total_bytes, "bytes sent via delta sync")
    fmt.println("Comparison: one full snapshot (ecs.serialized_size) is", full_size, "bytes -- a naive full resend every tick would cost", full_size * common.TICK_COUNT, "bytes over the same run")

    fmt.println("Server final state (first 5 entities):")
    for i in 0..<5 {
        pos := ecs.get_component(&w.positions, eids[i])
        hp := ecs.get_component(&w.healths, eids[i])
        fmt.println("  entity", i, "pos:", pos^, "hp:", hp^, "stunned:", ecs.has_tag(&w.stunned, eids[i]))
    }
}
