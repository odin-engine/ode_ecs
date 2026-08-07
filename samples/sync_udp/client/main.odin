/*
    2026 (c) Oleh, https://github.com/zm69

    UDP delta-sync sample — client side. Mirrors the server's schema and
    entity pool, then receives and applies delta packets via ecs.apply_delta.
    Its printed final state should match the server's printed final state
    (modulo the last couple of in-flight ticks) even though only changed
    field bytes ever crossed the wire.

    The sync feature is off by default (see ecs.SYNC_ENABLED's doc comment) —
    build/run this with -define:ECS_SYNC_ENABLED=true, e.g.
    odin run . -define:ECS_SYNC_ENABLED=true

    Run this first — it binds and blocks in recv_udp — then run the server.
*/
package ode_ecs_sync_udp_client

// Core
    import "core:fmt"
    import "core:net"

// ODE_ECS
    import ecs "../../../"
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

    dec: ecs.Sync_Decoder
    defer ecs.sync_decoder_terminate(&dec)
    if err := ecs.sync_decoder_init(&dec, &w.db, 4); err != nil {
        fmt.eprintln("sync_decoder_init failed:", err)
        return
    }
    if err := ecs.sync_register(&dec, &w.positions); err != nil {
        fmt.eprintln("sync_register(positions) failed:", err)
        return
    }
    if err := ecs.sync_register(&dec, &w.healths); err != nil {
        fmt.eprintln("sync_register(healths) failed:", err)
        return
    }
    if err := ecs.sync_register(&dec, &w.stunned); err != nil {
        fmt.eprintln("sync_register(stunned) failed:", err)
        return
    }

    socket, sock_err := net.make_bound_udp_socket(net.IP4_Loopback, common.CLIENT_PORT)
    if sock_err != nil {
        fmt.eprintln("make_bound_udp_socket failed:", sock_err)
        return
    }
    defer net.close(socket)

    buf := make([]byte, 65536)
    defer delete(buf)

    total_bytes := 0

    fmt.println("Client: waiting for", common.TICK_COUNT, "delta packets on port", common.CLIENT_PORT, "...")

    for tick in 0..<common.TICK_COUNT {
        n, _, recv_err := net.recv_udp(socket, buf)
        if recv_err != .None {
            fmt.eprintln("recv_udp failed:", recv_err)
            return
        }
        total_bytes += n

        if err := ecs.apply_delta(&dec, buf[:n]); err != nil {
            fmt.eprintln("apply_delta failed on tick", tick, ":", err)
            return
        }
    }

    fmt.println("Client: done.", common.TICK_COUNT, "packets received,", total_bytes, "bytes total")

    fmt.println("Client final state (first 5 entities) -- compare against the server's printout:")
    for i in 0..<5 {
        pos := ecs.get_component(&w.positions, eids[i])
        hp := ecs.get_component(&w.healths, eids[i])
        fmt.println("  entity", i, "pos:", pos^, "hp:", hp^, "stunned:", ecs.has_tag(&w.stunned, eids[i]))
    }
}
