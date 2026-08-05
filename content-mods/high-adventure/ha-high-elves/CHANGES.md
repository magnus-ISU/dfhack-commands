# Changes — HA High Elves

## v0.23 addendum -- twinkling is SPECIAL (deployed over 0.23 and bundle v17, version deliberately not bumped)

Shipped by overwriting the deployed 0.23 mod and the `HIGH_ADVENTURE (17)` snapshot in
place, rather than minting a new version. DF keys its per-world snapshot by version, so a
bump would have orphaned the fort that is being played against v17 — and because DF 50
saves carry no `raw/` of their own and read the snapshot directly, overwriting it is also
the only way the token reaches any world at all, new or existing.

- **Both twinkling materials now carry `[SPECIAL]`.** The token stops AI-controlled
  entities making items from a material and stops it travelling in caravans, while
  leaving the player free to use it exactly as normal — so a high-elf fort still catches
  starlight at the Shaping Tree and forges bars at the smelter.
- This matches how the suite already works: `high-adventure/war-gear` hands elves their
  twinkling gear directly, so worldgen's equipment spread has no business minting it, and
  an elf caravan has no business selling divine, fireproof, indestructible cloaks to a
  dwarf fort for a few barrels of ale. Adamantine is protected the same way — `DEEP_SPECIAL`
  implies `SPECIAL`, which is why no AI civ ever trades it. Twinkling is grown rather than
  mined, so it takes the plain token and not the adamantine one.
- Vanilla ships no raw that uses `[SPECIAL]` directly, but DF's own procedural generators
  read the flag: `get_random_inorganic(nil, "IS_METAL", "SPECIAL")` in
  `vanilla_procedural/scripts/generators/creatures/shared_info.lua` passes it as the
  EXCLUDE argument when picking a metal for a generated creature's weapon, so a
  procedurally generated beast can no longer turn up carrying twinkling either.

## v0.23 -- twinkling gear moved to the shared war-gear engine
- The re-gear pass left high-elves.lua for high-adventure/war-gear in the
  HA_adventure_hostility mod, which now does the same job for drow, dark dwarves
  and vanilla dwarves. Behaviour is unchanged except that it upgrades only.
- The shaping tree, its pacing, sky/trunk siting and the catch-starlight thread
  all stay here. fabric_mat() is retained: catch-starlight still mints the
  twinkling thread.

## 0.22 -- twinkling FABRIC for clothes, metal only for armour
The caught strand is now fabric, not metal. A strand woven at a loom becomes
twinkling fabric cloth; a strand smelted WITH SILVER becomes a twinkling metal
bar. Clothes were coming out as "twinkling metal tunic" because there was only
ever one material.
- New material `INORGANIC:HA_TWINKLING_FABRIC`: the same divine strength values
  but soft-only tokens (`ITEMS_SOFT`, no `ITEMS_HARD`/`ITEMS_METAL`/`ITEMS_ARMOR`/
  `ITEMS_WEAPON`), so DF will make thread, cloth and clothing from it and nothing
  else. Armour and weapons still require the metal bar.
- `HA_CATCH_STARLIGHT` now mints the strand as fabric, and
  `HA_FORGE_TWINKLING_BAR` consumes fabric strands plus silver to make the metal.
- The re-gear allowlist is split in two: clothing (tunic, robe, dress, shirt,
  coat, cloak, hood, gloves, mittens, shoes, sandals, socks, trousers, leggings,
  loincloth, braies) is made of fabric; breastplates, mail shirts, helms, caps,
  gauntlets, boots, greaves, shields and weapons stay metal.
- Gloves keep their handedness -- a re-geared elf was ending up with two right
  gloves and a bare left hand.
- **Needs a new world** for the fabric material (raws are baked in at world gen).
  In an existing world the script falls back to the metal for clothing rather
  than leaving those elves in rags.

## 0.21 -- re-gearing finally reaches named elves and ordinary clothes
Two bugs kept most high elves in jute rags (found on the high elven child Imaza
Wabeathe, who was still wearing jute trousers, a ramie tunic, rope reed gloves
and jute socks):
- **Named elves were skipped entirely.** In adventure mode the re-gear test was
  `hist_figure_id < 0`, i.e. non-historical figures only -- but every high elf
  with a name is a historical figure, so all townsfolk, soldiers and children
  were excluded. It now re-gears every high elf except the player.
- **Clothing was not in the allowlist.** Only armour pieces were listed
  (breastplate, mail shirt, gauntlets, boots, greaves...), so tunics, pants,
  gloves, socks, shoes, robes, dresses and hoods were left alone. Twinkling
  metal carries `[ITEMS_SOFT]` -- the adamantine-cloth trick -- so cloth items
  of it are legal, and those subtypes are now included.
- Script-only change: applies on save reload, no new world needed.

## 0.13 -- settle woodland, not everywhere
- **`SETTLEMENT_BIOME:ANY_LAND` was the sprawl.** High elves were the only civ in the world
  with it -- everyone else lists specific biomes or none -- and reached 373 sites and 76,302
  population. Replaced with `ANY_FOREST`, `ANY_SHRUBLAND`, `MOUNTAIN`.
- Dropped the ocean `BIOME_SUPPORT` experiment; it had no measurable effect, which now makes
  sense: territory spreading over water did not matter when they could settle any land it touched.
- `MAX_POP_NUMBER` 120 -> 10000. The old cap was the tightest in the world and they blew
  straight past it, so it was only noise.

## 0.12 -- experiment: ocean-weighted expansion
- `BIOME_SUPPORT:ANY_OCEAN:10` against 1 for everything else, on the theory that territory
  spreading over water they cannot build on wastes their expansion budget. Start biome kept
  first, which is required for any settlement past the first to be founded.
- Result over 250 years: **no visible effect** -- 953 entities and 76,302 population, still the
  third largest civ. This lever did not work; the cause of high elf sprawl is elsewhere.

## 0.11a -- shaping tree art rebuilt on the real 5x6 grid; starlight is chancy and fuel-free
- **"Catch starlight" showed `[Requires fuel]` at the Shaping Tree** even though the
  reaction has no `PRODUCT` and no fuel token of its own. Cause: a *comment* line in
  `reaction_ha_high_elf.txt` began with a bracketed FUEL token (prose describing the
  smelter recipe below it). DF's parser scans every line for an opening bracket --
  comments are not a thing -- so that token was applied to whichever reaction was still
  open, which was `HA_CATCH_STARLIGHT`. A second comment held a bare bracketed PRODUCT
  token that likewise landed on `HA_HE_MAKE_WOODEN_MECHANISMS`.
- Rewrote both comments with no brackets at all, and added a warning at the top of the
  file. Verified by re-simulating the parse: `FUEL` now belongs only to
  `HA_FORGE_TWINKLING_BAR`, and every other token lands on its intended reaction.
- Patched into `installed_mods/HA_high_elves (11)` in place so the existing fort picks it
  up on its next load (no version bump, so no stale mod folder to clean up).
- **The art now uses the grid DF actually gives a 5x5 workshop: 5 x (DIM_Y+1) = 5x6.**
  Row 0 is the single free row ABOVE the footprint and rows 1..5 are the footprint --
  which is why the old `wy` 0..4 tokens sat one row too high, and why the `wy - 2`
  attempt in 0.10 was silently cropped (DF drops rows above row 0 without an errorlog
  entry). Verified against vanilla, where every building obeys it: 1x1 screw press
  1x2, 3x3 workshops 3x4, trade depot/kennel/siege 5x6.
- **New sprite**, composed from the Gentle Forest tiles: a ring of 11 ferns with 7 more
  clustered around the trunk, 40% of them green/lime, small flowers tight around the
  tree and through the ring, and 5 boulders ringing the outside. Row 0 is left fully
  transparent so the living tree DF draws there is never covered.
- **The four variants are DF's construction stages, so they are now a growth sequence**
  rather than four unrelated crowns: every rock is present from stage 0, ferns and
  flowers start at 20% and fill in, ferns appearing trunk-outward so the ring closes
  last. `graphics/images/shaping_tree.png` is a 160x768 page (four 160x192 stages) and
  the token count is 120 (4 variants x 5 columns x 6 rows).
- Generator lives in `content-mods/art/shaping-tree/5x6/build_5x6.py` (seed 31).
- **Catch starlight is a gamble**: 5% success per point of the worker's strand
  extractor rating, rolled in the companion script. A failure still spends both
  threads. Its `SKILL` also changed from `CLOTHESMAKING` to `EXTRACT_STRAND` so the
  job trains the skill that gates it -- otherwise a fresh fort could never improve it.
- **Catching starlight now rests the tree, but only when it works.** A caught strand
  puts the tree on the same one-month cooldown that growing wood uses (one cooldown per
  tree, shared between both jobs); a failed catch spends the threads but leaves the tree
  unspent, so it can be tried again immediately.

## 0.11 -- undyed clothing renders for every profession
- **Fishermen (and rangers/children) rendered fully naked on the world sprite.** In the
  moon-elf clothing layers, the color is chosen by profession -- but the `FISHERY_WORKER`
  layer *also* required `CONDITION_DYE:MIDNIGHT_BLUE`, `RANGER` required `EMERALD`, and
  `CHILD` required `RED`. High elves wear **undyed** rope reed, so a unit of one of those
  professions matched no clothing layer at all -> naked (this was Nethithalave, a Fisherman).
  Removed those three dye requirements (66 lines across all body regions) so the profession's
  layer renders regardless of dye. Kept `DYE:BLACK` (it disambiguates the multiple `NONE`
  layers) and `CONDITION_NOT_DYED` (farmer, which already matched undyed).
- Note: a Stonecrafter (e.g. Limi) maps to the no-dye `CRAFTSMAN`/`STONEWORKER` category, so
  her clothes already have matching layers; if she still shows bare legs it is because she
  wears a *skirt* (a hip drape) rather than pants, not a raw mismatch.


## 0.10 -- shaping tree crown moved onto the trunk
- **SUPERSEDED by 0.11a.** This tried to lift the crown with `wy - 2` and to vary the art
  per workshop using the four variants. Neither works: negative `wy` rows are silently
  dropped (the art lost its top two rows), and the variants are construction stages, not
  random picks, so the four crowns animated as the workshop was built.
- **A shaping tree now needs a living tree**: the companion script cancels, while still under
  construction, any tree without a tree tile on the spot the crown wraps -- build the workshop
  hugging a standing trunk. (A trunk pillar is tiletype material `TREE` but shape `WALL`, not
  `TRUNK_BRANCH`.)
- **Crash fix in the companion script**: `custom_type` only exists on workshops/furnaces, so
  the shaping-tree scans now test `building_workshopst` first -- reading it off a farm plot
  aborted the whole tick (sky-access and regrow-cooldown included).
- Graphics + script change -- applies on save reload, no new world needed.

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
