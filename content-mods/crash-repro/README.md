# crash-repro — minimal reproduction of the DF 53.15 out-of-bounds sprite bug

**This mod crashes Dwarf Fortress on purpose. Do not play with it installed.**

It exists to demonstrate, in as few moving parts as possible, the memory-safety
bug that caused a run of heap-corruption crashes in this repo's High Adventure
suite on 2026-07-31 (see `../../../crash-investigation/`, outside the repo, for
the full diagnosis, valgrind output and crash logs).

## The bug in four lines

`graphics/graphics_crash_repro.txt`:

```
[TILE_PAGE:CRASH_REPRO_PAGE]
    [FILE:crash_repro/body.png]        <- the PNG is 64x32: TWO 32px tiles
    [TILE_DIM:32:32]
    [PAGE_DIM_PIXELS:32:32]            <- but the page declares ONE

[CREATURE_GRAPHICS:CRASH_REPRO]
    [LAYER_SET:DEFAULT]
    [LAYER_GROUP]
    [LAYER:BODY_OUT_OF_BOUNDS:CRASH_REPRO_PAGE:1:0]   <- asks for the second tile
    [END_LAYER_GROUP]
```

Tile `1:0` is inside the image file and outside the declared grid. DF does not
reject the reference when the graphics load, and does not clamp it when
drawing: the layered-sprite compositor indexes past the end of the surface it
sized from `PAGE_DIM_PIXELS` and writes out of bounds. That corrupts the glibc
heap, and the process aborts or segfaults some seconds or minutes later at
whatever allocation happens to come next — so the crash backtrace is almost
never near the actual fault.

Correcting `PAGE_DIM_PIXELS` to `64:32` removes the fault entirely. That is
exactly the one-token fix that ended the crash burst in `ha-succubi 0.22`,
where six layered clothing layers referenced column 1 of a page declared one
column wide.

## What each file is for

| File | Role |
|---|---|
| `graphics/graphics_crash_repro.txt` | **the bug** — malformed tile page + the layer that reads past it |
| `graphics/crash_repro/body.png` | 64x32: magenta tile 0 (declared), cyan tile 1 (hidden, requested) |
| `objects/creature_crash_repro.txt` | `[COPY_TAGS_FROM:DWARF]` plus a name — just something to draw |
| `objects/entity_crash_repro.txt` | *generated*: vanilla `MOUNTAIN` verbatim, renamed, pointed at the creature, so the civ is embark-able without inventing a civilization |
| `generate.py` | rebuilds the entity copy and the PNG |

The scaffolding is deliberately unoriginal: a proven-good vanilla entity and a
copied creature keep the reproduction from failing for reasons unrelated to the
bug.

## Reproducing

1. Copy this folder into `<DF>/mods/crash_repro` and restart DF (mods are
   scanned once, at startup).
2. Generate a world with the mod enabled — worldgen itself is unaffected.
3. Embark as the "crash test subjects" civilization. The creature is drawn as
   soon as the embark screen shows your seven units, and again constantly in
   the fort.
4. The game dies within seconds to minutes. `<DF>/crashlog/` gets a stack
   trace; stderr shows a glibc diagnostic such as `double free or corruption
   (!prev)`, `malloc(): largebin double linked list corrupted (bk)` or
   `corrupted size vs. prev_size`.

Under valgrind the fault is caught at composite time, before any crash, and
points straight at the writer:

```
valgrind --error-limit=no --num-callers=24 --undef-value-errors=no ./dwarfort
```

Expect `Invalid write of size 1 ... N bytes after a block of size 296 alloc'd`
with `textures::create_texture` → `SDL_CreateRGBSurface` in the allocation
stack. Valgrind itself eventually aborts with a heap-metadata assertion, which
is its own way of saying the overrun runs well past the allocation.

Verified on Dwarf Fortress 53.15, Steam native Linux build, with and without
DFHack loaded.
