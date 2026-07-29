# Changes — HA High Elves

## 0.9 -- plain skirt renders without a dress
- **A plain skirt worn without a dress showed bare legs on the world sprite.** The moon-elf
  waist-hang layers are AND-conditioned: `CLOTHING_WAIST_SKIRT` (the sprite that drapes a
  medium skirt over the legs) required `ITEM_ARMOR_DRESS` **and** `ITEM_PANTS_SKIRT`, so a
  skirt worn with anything other than a dress (e.g. a tunic) never drew its lower half.
  Removed the spurious `ITEM_ARMOR_DRESS` requirement from all 18 `CLOTHING_WAIST_SKIRT`
  layers, so a plain skirt now renders on its own (dress+skirt still works unchanged).
- Graphics change; applies to a fresh world / on graphics reload.

## 0.8 -- the missing noble roster
The civ had only six positions (Lady of Light, warden, protector, blade singer, diplomat,
emissary) and no site-level administration at all: no fort leader, no work orders, no
stock counts, no trading, no health screen, no justice. Added, all `[SITE]`:
- **Seneschal** (EXPEDITION_LEADER) and **Voice of the Enclave** (MAYOR, elected at pop 50)
  -- `MEET_WORKERS`/`RECEIVE_DIPLOMATS`/`MILITARY_GOALS`, the fort's head noble.
- **Master of works** (MANAGER) -- `MANAGE_PRODUCTION`, work orders.
- **Keeper of tallies** (BOOKKEEPER) -- `ACCOUNTING`, accurate stock counts.
- **Silver-tongue** (BROKER) -- `TRADE`, depot negotiation and appraisal.
- **High healer** (CHIEF_MEDICAL_DWARF) -- `HEALTH_MANAGEMENT`, the health screen.
- **Watcher** (SHERIFF) and **captain of the watch** (CAPTAIN_OF_THE_GUARD) --
  `LAW_ENFORCEMENT`; the captain carries a 10-elf watch squad and replaces the watcher.
- **Beast-friend** (DUNGEON_MASTER) -- `ESPIONAGE` + `MANAGE_ANIMALS`.

No executioner: high elves deliberately have no hammerer or `EXECUTIONS` holder, so
sentences fall through to jail time rather than a beating. Needs a fresh world.

## 0.7 -- world-sprite fixes + fuel-free strands
- **Body invisible on some elves (world sprite)**: the world-sprite body layers only cover
  skin colours `CERULEAN/MIDNIGHT_BLUE`, `WHITE`, `PALE_BLUE/…`, `PALE_PINK/PINK`, but 0.5's
  portrait fix set skin to `PALE_PINK/TAUPE_PALE` -- `TAUPE_PALE` matched no world-sprite
  layer, so those elves rendered no body. Skin is now `PALE_PINK:2:PINK:1`, the intersection
  of portrait- and world-sprite-supported colours (both render everywhere).
- **Same trap in hair**: world-sprite hair has no `GOLDEN_YELLOW` layer, so 0.6's
  `SILVER/WHITE/GOLDEN_YELLOW` would render golden-haired elves bald on the map. Hair is now
  `SILVER:2:WHITE:1` (the portrait ∩ world-sprite intersection).
- **Tunics didn't render on the world sprite**: the upper-body clothing layer groups listed
  `COAT:SHIRT:TOGA:DRESS:ROBE` without `ITEM_ARMOR_TUNIC` (only the waist-hang layers had it),
  so a tunic's torso/sleeves never drew. Added `ITEM_ARMOR_TUNIC` to all 36 upper-body
  clothing conditions.
- **Twinkling strands no longer require fuel**: DF hardcodes a fuel requirement onto any
  reaction that outputs a *metal* item, even at a fuel-less custom workshop. `HA_CATCH_STARLIGHT`
  no longer lists the twinkling THREAD as a native `[PRODUCT]`; the script now hooks the reaction
  and mints the dimension-15000 strand itself after the reagents are consumed.
- **Shaping tree art**: rescaled so the full crown (including its bottom fringe) fits the lower
  four tile-rows -- fixes the cropped bottom row from 0.6 while keeping the low seating.
- Raw changes (skin/hair/reaction/graphics) need a fresh world; script + art apply on reload.

## 0.6 -- shaping tree: yield, pacing, art
- **Skill now grows more wood**: previously a legendary strand extractor merely halved
  the regrow cooldown. Now the grow-wood/feather reaction yields **one native log plus
  one bonus log per EXTRACT_STRAND level**, capped at 21 total (legendary+5 == rating 20).
  Bonus logs are minted by the script at the worker's feet; the reaction PRODUCT dropped
  from 4 to 1 so unskilled growers get a single log.
- **Fresh trees start on cooldown**: a newly built shaping tree is immediately placed on a
  full one-month cooldown, so it can't be harvested the instant construction finishes.
- **Reworded the too-soon message** to: "The shaping tree is not yet ready to grow into new
  forms; it only yields new logs once a moon."
- **Art seated lower**: `shaping_tree.png` shifted down one 32px tile so the crown sits
  flush with a wall below and no longer clips into the tile above.
- Twinkling-strand ("catch starlight") already requires no fuel (custom-workshop reaction
  with no `[FUEL]` token) -- confirmed, no change needed.
- Reaction/PRODUCT change needs a fresh world; script + graphics changes apply on reload.

## 0.5 -- portrait colours render + no bald elves
- **Portraits were blank** for most generated elves: the creature's hair/skin
  `TL_COLOR_MODIFIER` colours had no matching layer in the shipped (vanilla-elf) portrait art.
  - Hair was `AQUA/BLACK/MIDNIGHT_BLUE/PALE_BLUE/SILVER/WHITE`, but the art only has layers for
    `SILVER, WHITE, MOSS_GREEN, GOLDEN_YELLOW/GOLDENROD/SAFFRON, ORANGE/PUMPKIN, RED/SCARLET`
    — 4 of 6 (incl. pale blue) rendered blank. Now `SILVER:2:WHITE:1:GOLDEN_YELLOW:1`.
  - Skin was `PALE_PINK/PALE_BLUE/WHITE`, but the art only has a light-body layer for
    `PALE_PINK/PINK/TAUPE_PALE` — pale-blue and white rendered blank. Now `PALE_PINK:2:TAUPE_PALE:1`.
- **No more bald elves**: head-hair length distribution was `0:0:0:0:0:0:0` (grew from bald with
  age), so young/generated elves showed no hair. Added an overriding head-hair length of
  `300:400:500:600:700:800:900` (facial hair unchanged) — all high elves now have long hair.
- Needs a fresh world (raw changes).

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
