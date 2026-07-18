# 📄 Docs

* [README.md](/README.md)
* [Database](database.md)
* [Tables](tables.md)
* [View](view.md)
* [Group](group.md)
* [Relations](relations.md)
* [Command Buffer](command_buffer.md)
* ❓[Frequently Asked Questions (F.A.Q)](faq.md)

# 🍕 Samples

I highly recommend going through the [samples](../samples) to learn about ODE_ECS functionality. I tried to demonstrate all the main features in the samples.

* [Basics](/samples/basics/main.odin) – A minimal starting point: init a database, tables and a view, create entities, iterate.
* [Sample01](/samples/sample01/main.odin) – A basic sample with 100,000 entities that demonstrates how to use tables and views.
* [Sample02](/samples/sample02/main.odin) – Demonstrates how to optimize your ECS (Approach 1 vs. Approach 2).
* [Sample03](/samples/sample03/main.odin) – Demonstrates the benefits of the View approach versus the Archetype approach in ECS.
* [Sample04](/samples/sample04/main.odin) – Demonstrates:

    * How to use `Tiny_Table`
    * How to use a View on top of different table types (`Tiny_Table`, `Table`, and `Compact_Table`)
    * An example of a tags table
    * An example of a bool table

* [Sample05](/samples/sample05/main.odin) – Compares `Table` vs. `Compact_Table`, and `Tiny_Table` vs. `Compact_Table` vs. `Table`.
* [Sample06](/samples/sample06/main.odin) – Demonstrates how to use `Tag_Table` and View filtering.
* [Sample07](/samples/sample07/main.odin) – Demonstrates `Group`: exclusive table ownership and iterating the aligned dense prefix.
* [Sample08](/samples/sample08/main.odin) – Demonstrates entity relations (`relations_init`, `set_parent`, `children_of`).
* [Sample09](/samples/sample09/main.odin) – Demonstrates `Command_Buffer`: deferring structural changes while iterating, then `replay`.
* [Sample10](/samples/sample10/main.odin) – Demonstrates serialization: snapshot a database, save/load it from a file.
* [Sample11](/samples/sample11/main.odin) – Demonstrates multithreading: parallel batched View iteration + a single-threaded sync point (see [F.A.Q. #1](faq.md)).


# 📖 How to read the source code

To check the main **ODE\_ECS** procedures, you can go to [ecs.odin](/ecs.odin) and scroll down to the **aliases** section. Those are the main or most commonly used procedures, though not all of them.

If you want to find all procedures related to a specific object—for example, **Table** (or [View](/view.odin), [Iterator](/iterator.odin), [Tiny\_Table](/tiny_table.odin), [Compact\_Table](/compact_table.odin), etc.)—you can go to its respective file. For **Table**, that would be [table.odin](/table.odin).

Scroll down to the **Table** section (ignore the **Table\_Base** and **Table\_Raw** objects/sections), and there you’ll find all of the public **Table** procedures along with their implementations.

# 🕑 Performance tuning

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

# 💪 Benchmarks (ODE_ECS vs other ECSes)

- ODE_ECS vs moecs vs odecs benchmark is [here](https://github.com/zm69/ecs_bench).

# ‼️ When to open an issue ticket
If you have any questions about ODE_ECS or encounter any issues, please open an issue ticket, and I’ll try to answer, fix, or add new functionality.
