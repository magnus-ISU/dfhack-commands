# Changes — HA High Elves

## 0.4 -- nobles: Lady of Light, Diplomat, Protector
- Renamed the high queen to **Lady of Light** (Ladies of Light).
- Added **Diplomat** (position id MESSENGER): SITE, NUMBER:AS_NEEDED, DELIVER_MESSAGES, rootless
  (no APPOINTED_BY) so a player fort can assign it directly.
- Added **Protector** (SITE, NUMBER:1, squad, COMMANDER of blade singers, rootless): the fort-level
  militia commander the civ was missing; blade singers now also APPOINTED_BY:PROTECTOR, fixing the
  broken fort squad chain (previously gated on the civ-level warden only). Needs a fresh world.

## 0.3 -- embark food & drink
- High-elf civs generated with EMPTY food/drink resource lists (verified live in region2:
  plants=0 seeds=0 booze=0 meat=0), so embark offered no provisions at all. The entity had no
  farming tokens: worldgen only fills crop/seed/booze lists from *_FARMING/*_GARDENS tokens.
- Added `[OUTDOOR_FARMING]` `[OUTDOOR_GARDENS]` `[OUTDOOR_ORCHARDS]` `[USE_ANIMAL_PRODUCTS]`
  `[RIVER_PRODUCTS]`; jobs PLANTER/BREWER/COOK/THRESHER/MILLER/CHEESE_MAKER/MILKER; reactions
  BREW_DRINK_FROM_PLANT(_GROWTH), MAKE_MEAD, PROCESS_PLANT_TO_BAG, MILL_SEEDS_NUTS_TO_PASTE,
  PRESS_OIL_FRUIT.
- De-bracketed comment tokens (`[ACTIVE_SEASON]` in the entity, divine-metal token names in
  inorganic_ha_twinkling.txt) -- the raw parser reads bracketed tokens even in comment prose.
- Needs a fresh world.

## 0.2 — fort-mode playable
- Added `[SITE_CONTROLLABLE]` to HA_HIGH_ELF so high-elf civs appear in the
  fort-mode embark civilization picker. (Worldgen itself was never broken —
  region2 has 7 living high-elf town civs; they were just unpickable.)
  Needs a fresh world, like all raw changes.

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
