# 📏 Lines of Code (as of July 21, 2026)

A snapshot of the project's size, measured with `wc -l` over all `.odin` files (excluding gitignored `out/` build folders).

| Area | Lines |
|---|---:|
| Root `ode_ecs` core (`.odin` files at repo root) | 7,510 |
| `ode_core` (generic data structures) | 1,104 |
| `ode_core/maps` (`Rh_Map`, `Tt_Map`, `Key_Map`) | 2,224 |
| `tests/` (public + private test suites) | 10,137 |
| `samples/` | 4,023 |
| **Total** | **26,036** |

The library surface itself — core + `ode_core` + `ode_core/maps` — is about **10,838 lines**. Tests are roughly the same size as the library, and samples add another ~4k lines on top.

#### Please consider starring ⭐ this project on [Github](https://github.com/odin-engine/ode_ecs). 

