# Docs

* [Database](database.md)
* [Tables](tables.md)
* [View](view.md)
* [Relations](relations.md)
* [Frequently Asked Questions (F.A.Q)](faq.md)

# Samples

I highly recommend going through the [samples](../samples) to learn about ODE_ECS functionality. I tried to demonstrate all the main features in the samples.

* [Sample01](../samples/sample01/main.odin) – A basic sample with 100,000 entities that demonstrates how to use tables and views.
* [Sample02](../samples/sample02/main.odin) – Demonstrates how to optimize your ECS (Approach 1 vs. Approach 2).
* [Sample03](../samples/sample03/main.odin) – Demonstrates the benefits of the View approach versus the Archetype approach in ECS.
* [Sample04](../samples/sample04/main.odin) – Demonstrates:

    * How to use `Tiny_Table`
    * How to use a View on top of different table types (`Tiny_Table`, `Table`, and `Compact_Table`)
    * An example of a tags table
    * An example of a bool table

* [Sample05](../samples/sample05/main.odin) – Compares `Table` vs. `Compact_Table`, and `Tiny_Table` vs. `Compact_Table` vs. `Table`.
* [Sample06](../samples/sample06/main.odin) – Demonstrates how to use `Tag_Table` and View filtering.


# How to read source code

To check the main **ODE\_ECS** procedures, you can go to [ecs.odin](../ecs.odin) and scroll down to the **aliases** section. Those are the main or most commonly used procedures, though not all of them.

If you want to find all procedures related to a specific object—for example, **Table** (or [View](../view.odin), [Iterator](../iterator.odin), [Tiny\_Table](../tiny_table.odin), [Compact\_Table](../compact_table.odin), etc.)—you can go to its respective file. For **Table**, that would be [table.odin](../table.odin).

Scroll down to the **Table** section (ignore the **Table\_Base** and **Table\_Raw** objects/sections), and there you’ll find all of the public **Table** procedures along with their implementations.

See [this sample](../samples/sample04/main.odin) for more usage examples.

> **NOTE:** Use `Tiny_Table` when you need a table with a component capacity of eight or fewer (you can change the limit via `TINY_TABLE__ROW_CAP`).

**Compact\_Table** is designed to optimize memory usage at the cost of speed. You can use it exactly as you would use a `Table`.

```odin
inventory_table : ecs.Compact_Table(Inventory) // Compact_Table !!!
err = ecs.compact_table__init(&inventory_table, &db, 5)
```

Views can be created on top of a mix of `Table`s, `Tag_Table`s, `Compact_Table`s, and `Tiny_Table`s. See the example [here](../samples/sample04/main.odin).

[Sample05](../samples/sample05/main.odin) shows memory usage and speed comparisons between `Table`, `Compact_Table`, and `Tiny_Table`.

> **NOTE:** Use Compact_Table to save memory when its capacity is much lower than the database entity capacity. Iteration speed is about the same as Table, but per-entity lookups and add/remove are slower (hash map vs. direct array). If the capacity is close to the entity capacity, Table is faster on lookups and uses less memory.

# Performance tuning

ODE_ECS ships with a micro-benchmark suite in `benchmarks/` — the referee for any performance work on the library. Run it before and after a change and compare ns/op:

```
    cd benchmarks
    odin run . -o:speed -out:out/bench.exe
```

Compiler flags that matter for release builds of your game:

- `-o:speed` — enables optimizations; the single biggest factor.
- `-define:ECS_VALIDATIONS=false` — strips the library's parameter/state asserts.
- `-disable-assert` — strips all remaining asserts globally.
- `-no-bounds-check` — disables bounds checking globally. The library already annotates its provably-safe hot paths with `#no_bounds_check`, so this mostly affects your own code.
- `-microarch:native` — allows the compiler to use your CPU's full instruction set.

# Benchmarks (ODE_ECS vs other ECSs)

- ODE_ECS vs moecs vs odecs benchmark is [here](https://github.com/zm69/ecs_bench).

# When to open an issue ticket
If you have any questions about ODE_ECS or encounter any issues, please open an issue ticket, and I’ll try to answer, fix, or add new functionality.