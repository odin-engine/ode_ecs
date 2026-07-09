# F.A.Q

### 0. Why did you build it?

I built it for my own MMORPG project. It is minimal, low-level, well-tested, and fast—exactly what I want an ECS to be. I wanted to avoid overengineered libraries that unpredictably tank frame-to-frame stability. At the same time, I didn't want a full-blown in-memory relational database; there is simply no need for that level of complexity. An ECS is essentially a stripped-down, high-performance, in-memory relational database (RDB). That's it. It isn't a new concept at all, and it maps beautifully to standard RDB principles. In my view, if a game's data structure is complex enough to benefit from a relational database, it's complex enough to warrant an ECS.

### 1. Thread safety?

This is a data-oriented library with a "no hidden costs / preallocate everything" philosophy. Baking locks into every call is exactly the kind of hidden cost it avoids. The idiomatic answer is to not make the core thread-safe, and instead parallelize at a higher level where synchronization amortizes to zero:

- Phase separation: run read/compute systems in parallel, then apply all structural changes (create/destroy/add/remove) in a single-threaded sync point. The parallel phase touches no shared mutable bookkeeping.

- Data-parallel iteration is already a designed-in feature. iterator__init(self, view, start_row, end_row) exists precisely for this — its comment says "Use start_row and end_row if you want to process View in batches."

- One Database per thread/region for fully independent workloads — the API explicitly supports many databases, and they share nothing.

So the honest summary: making the core internally thread-safe would meaningfully hurt — per-element locking is a 2–10× hit on the headline iteration path and per-mutation locking serializes the very thing you parallelized for. But thread-safe usage via batched parallel iteration over immutable component data plus a single-threaded structural-mutation phase costs essentially nothing.

### 2. How to iterate over all entities?

Iterating over all entities unconditionally is a major anti-pattern in ECS.

In fact, avoiding this exact practice is one of the primary reasons the ECS architecture was invented in the first place.

Why It's an Anti-Pattern
ECS is designed heavily around data-oriented design and cache locality. Iterating over every single entity defeats these benefits for three major reasons:

- CPU Cache Misses: In a good ECS, components are stored in contiguous memory arrays (often grouped by archetype). If a system loops through every entity, it will constantly jump around in memory to look up components, causing CPU cache misses and destroying performance.

- The "Empty Entity" Waste: Many entities in your game might just be static environment pieces, UI elements, or particle effects. If your MovementSystem has to look at a UI button entity just to check if it has a Velocity component, you are wasting massive amounts of CPU cycles.

- O(N) Complexity Scaling: As your world grows from 1,000 entities to 100,000 entities, your frame rate will plummet because every system is checking every entity, even if only 5 of them are relevant.

In ECS you should have systems (basically procs) that iterate over components/Views related to those systems. Like network system should iterate over network copmonents to process them. Physics system should iterate over physics components to process them etc.