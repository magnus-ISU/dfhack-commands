# ha-dark-dwarves — fork changelog

Standalone fork of the **vanilla dwarf raws** (creature_standard DWARF block + entity_default
MOUNTAIN block, DF v53 vanilla data). New IDs `HA_DARK_DWARF` / `HA_DARK_DWARF_CIV`; vanilla
is untouched and both civs coexist.

## Creature (`creature_ha_dark_dwarf.txt`)
- Renamed; new name/description ("dark dwarf").
- Added creature-level: `[EVIL]`, `[OUTSIDER_CONTROLLABLE]`.
- Added to all castes: `[CARNIVORE]` (meat-only cannibals eat sapients via entity ethics),
  and zeroed `ANGER_PROPENSITY`, `STRESS_VULNERABILITY`, `DEPRESSION_PROPENSITY`,
  `ANXIETY_PROPENSITY` — never tantrums, never bad thoughts.
- Everything else identical to vanilla dwarves (sizes, castes, skills, alcohol dependence,
  strange moods).

## Entity (`entity_ha_dark_dwarf.txt`)
- Renamed; uses `CREATURE:HA_DARK_DWARF`; keeps `TRANSLATION:DWARF`, all vanilla dwarven
  positions, jobs, full metallurgy (steel + adamantine), `SIEGE_SKILLED_MINERS`.
- **No hillocks**: removed surface `SETTLEMENT_BIOME` entries (forest/grassland/savanna/
  shrubland) and their `BIOME_SUPPORT`; kept `SETTLEMENT_BIOME:MOUNTAIN`; swapped river
  support for subterranean chasm/water/lava support. Sites: fortresses + mountain halls.
- **Evil bloc**: added `[BABYSNATCHER]`, `[ABUSE_BODIES]`; caravan season changed
  AUTUMN → **WINTER**; progress triggers set to 2/2/2 with sieges at 3.
- Added `[ALL_MAIN_POPS_CONTROLLABLE]` (fort + adventure civ-member play).
- **Sappers**: added `DIGGER:ITEM_WEAPON_PICK_GREAT` alongside the pick.
- Ethics: killing/torture/slavery/trophies/cannibalism ACCEPTABLE; in-group protections
  kept (KILL_ENTITY_MEMBER etc. unchanged from vanilla = punished).
- Values: loyalty/law/tradition/craftsmanship high, nature/harmony/peace negative.
- Religion: added DEATH, DARKNESS, WAR, BLIGHT spheres (death gods → necromancy-prone).

## v0.2
- **Graphics**: full vanilla dwarf art (layered sprites + portraits) copied and re-keyed to
  `CREATURE_GRAPHICS:HA_DARK_DWARF`, with the five palette PNGs shipped at matching
  relative paths (tile pages are global identifiers, so only palettes needed copying).
  Fixes the blue-gorlak fallback sprite and missing portraits. A "dark" palette recolor is
  possible later by editing the palette PNGs.
- **Worldgen population fix**: v0.1 removed the surface `BIOME_SUPPORT` entries along with
  the surface `SETTLEMENT_BIOME`s, which starved worldgen population capacity (3 survivors).
  Surface `BIOME_SUPPORT` restored at vanilla weights (forest/grassland/savanna/shrubland/
  river:1) alongside mountain+subterranean; `SETTLEMENT_BIOME` remains MOUNTAIN-only, so
  still no hillocks.

## v0.3
- **Expansion diagnosis** (live-world data): with `SETTLEMENT_BIOME:MOUNTAIN` only, dark
  dwarf civs founded ZERO new sites all history while vanilla dwarves in the same world
  grew to 53 — surface settlement biomes are what drive dwarven-family worldgen expansion.
  One dark dwarf civ was also ground from 72 histfigs to 2 by wars (single-site snatcher
  civ = extermination target).
- **Experimental fix**: added `SETTLEMENT_BIOME:SUBTERRANEAN_CHASM/WATER/LAVA` (cavern
  expansion — thematic if worldgen honors it; verify via site enumeration after regen)
  and raised `MAX_SITE_POP_NUMBER` 120 → 250 so their few sites concentrate strength.
- Fallback decision if subterranean founding doesn't work: either accept insular
  single-mighty-fortress civs, or restore surface settlement (= hillocks return).

## v0.4
- Subterranean `SETTLEMENT_BIOME`s confirmed inert (parse silently, no founding) —
  removed. **Surface settlement restored** (forest/grassland/savanna/shrubland): dark
  dwarves expand like vanilla dwarves again, hillocks included — accepted trade-off, since
  worldgen welds dwarven-family expansion to surface settlements. `MAX_SITE_POP_NUMBER`
  stays 250 (helps snatcher civs survive their many wars).

## Known gaps
- "Allies only with drow and goblins, rarely" is emergent from the shared snatcher bloc +
  ethics proximity — verify in worldgen legends.

## v0.5
- Banditry 20 -> 40 (LOCAL already present).
