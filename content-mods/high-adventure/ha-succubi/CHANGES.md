# ha-succubi — fork changelog

## v0.8
- Worldgen survival package for the new insular mountain forts: all castes gain
  **Legendary Discipline** (never rout - fitting for demons) and **NOPAIN**
  (never give in to pain). Routing is the main way worldgen battles are lost;
  a shieldwall of unflinching demons should hold the single fortress.

## v0.7
- **Dwarven-fortress homes**: `DEFAULT_SITE_TYPE`/`LIKES_SITE` moved from
  DARK_FORTRESS to **CAVE_DETAILED** (the original author had a disabled
  CAVE_DETAILED line - they'd considered it). Mountain start
  (`EXCLUSIVE_START_BIOME:MOUNTAIN`) with `SETTLEMENT_BIOME:MOUNTAIN` only -
  the drow-proven configuration in which the dwarf site family founds nothing.
  This closes the sprawl hole: snatching still swells the population, but
  dark-pit-style founding no longer exists for them.

## v0.6
- Script renamed to **high-adventure/succubi** (`enable high-adventure/succubi`).

Standalone fork of **Succubus Dungeon** v20.1 (Steam 2950544248, Boltie). All raw IDs
renamed `SUCCUBUS*` → `HA_SUCCUBUS*`; scripts renamed (`enable ha-succubi`). Coexists
with the original.

## v0.2
- **Clothing restored** (design reversal): bustier, corset, short pants, stockings,
  bodysuit are back, with all their sprite layers.

## Removed
- Weapons: blade-whip, pitchfork → vanilla **pikes, halberds, scourges** added (whip
  already permitted).
- Writing tools: tablet, slip → vanilla **quires and scrolls**; the four slip-making
  reactions and their permits removed.
- Doll toy (knuckle bones and spinning tops remain).
- Graphics for removed items excised block-aware.

## Kept
- All clothing (v0.2), barbed wire trap component, knuckle bones, spinning tops,
  corruption/summoning/powers/magma wells/language/buildings/plants, Summer caravans
  (matches the original's effective behavior; the disabled season lines were cleaned).

## v0.3
- Removed the unused knuckle bone and spinning top toys (nothing referenced them).
- Prefixed the last four unprefixed inorganics (`SMOKE_SLEEP`, `SMOKE_PURPLE`,
  `FIRE_LIQUID`, `FIRE_GAS` → `HA_SUCCUBUS_*`) across raws, graphics, and scripts —
  zero unprefixed object IDs remain.

## v0.4 — upstream Steam bug reports fixed
- **Errorlog spam / "error initializing entity"** (Nahui Ollin): the entity permitted
  **117 reactions and 2 buildings that don't exist** (rock furniture set, cremation
  system, `ADAMANTINE_STRANDS`, `CREMATORIUM`, `MAGMA_DREDGER` — remnants of an older
  mod version). All phantom permits removed; permits now validate clean against
  vanilla + mod definitions.
- **Bolt throwers but no bolts** (Duel): the entity had `SIEGEAMMO` but no siege
  jobs — added `PERMITTED_JOB:SIEGE_ENGINEER` and `SIEGE_OPERATOR`.
- **Cauchemars starving in scorched pastures** (Duel): removed `STANDARD_GRAZER` —
  demonic steeds no longer need grass they themselves burn.
- **Courtesan powers hitting friendlies** (Dr. Force A Failure): the draining kiss is
  DEFEND-hinted with nearest-touchable targeting, and pheromones are an undirected
  vapor — allies got caught. Added a `HA_SUCCUBUS_ALLY` creature class to every mod
  creature and the succubi's pet edits, with `SYN_IMMUNE_CLASS` shields on the
  draining-kiss debuff, entice, crazed song, and the pheromone debuff (the succubus
  self-buff side is untouched).
- **Friendly to the HFS?** (Logograms): answered, not fixable — underworld demons are
  procedurally generated uniques with no raw-level diplomacy; succubi can *summon*
  demon allies via their circle, but breaching the underworld is hostile like for
  everyone. Documented as intended.

## v0.5 — insular succubi
- Live-world measurement: 3 succubus civs held **85 sites** with 300+ living members
  each — dark-fortress founding is population-pressure driven (`SETTLEMENT_BIOME` is
  irrelevant to it; vanilla goblins have none either), plus conquest occupation.
- Levers applied: `MAX_POP_NUMBER` 10000 → **600**, `MAX_SITE_POP_NUMBER` 250 → **500**
  (one packed spire instead of an empire), and removed `LIKES_SITE:CAVE_DETAILED` +
  `TOLERATES_SITE:CITY` so conquered foreign sites are not occupied. Survival outlook
  is good — the measured civs were *winning* their wars (occupied elf retreats), and
  demon combat strength is individual, not site-count-based. Verify next worldgen.
