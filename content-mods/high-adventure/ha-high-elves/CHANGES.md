# Changes — HA High Elves

## 0.1 (initial)
- New civ: **high elves** — elf-stock with dwarven metal artifice, no fey moods.
- **Twinkling metal** (`HA_TWINKLING_METAL`): fixed divine metal. Properties from
  vanilla's generated divine metal (`[MELTING_POINT:NONE]` → truly dragonfire-safe,
  unlike adamantine) + adamantine's thread-metal flags so it is also weavable
  (metal-tier, fireproof fabric) and forgeable into bars/wafers. Grown, not mined.
- Reactions: **catch starlight** (Shaping Tree: plant + silk thread → twinkling
  strand) and **forge twinkling bar** (strand + silver bar + fuel → bar).
- Entity: elf base + mining/smithing jobs + metal reactions; `DEFAULT_SITE_TYPE:CITY`;
  low `MAX_POP_NUMBER` + high `MAX_SITE_POP_NUMBER` (few big castles); **no
  `ACTIVE_SEASON`** (no trade); not cannibal (`EAT_SAPIENT_*:UNTHINKABLE`);
  `CRAFTSMANSHIP`/`SKILL`/`PEACE` values raised.
- DFHack `high-elves.lua` (first pass): re-gears high-elf invaders/visitors/
  adventurer to twinkling metal (worldgen can't equip divine metal).
- Self-contained: own Shaping Tree building, grown-wood plant, and reactions (no HA_playable_civs dependency).

### Known TODO (see README)
- Verify the loom weaves a custom thread-metal in-game (fallback reaction ready).
- Graphics: reuse elf sprites / fetch workshop art off-blue.
- Drow steel gear + ~½ siege cull script; Shaping-tree sky-access enforcement.
