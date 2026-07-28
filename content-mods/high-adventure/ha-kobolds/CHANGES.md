# ha-kobolds — build notes

## v0.1 — fork scaffold
- Self-contained fork of **Cute Kobold Caverns** (workshop 3477662286): every CKC-defined id
  prefixed `HA_` (creature `HA_KOBOLD` <- CUTEKOBOLD; entity `HA_KOBOLD_CAVES` <- KOBOLD_CAVES;
  ~222 items/reactions/translation + 26 graphics tile pages) so the fork collides with neither
  vanilla nor the original CKC.
- **Dropped all five CKC files that modify vanilla** (suite rule: never modify vanilla): the two
  creature patches (renamed vanilla KOBOLD; tweaked vanilla snakes/spiders/pets), the entity patch
  (altered the dwarf MOUNTAIN entity), the inorganic stone patch, and the item patch (SELECT_ITEM on
  vanilla armor/weapons). Consequence: the CKC pet-venom-milking / enhanced-pet tweaks are gone
  (acceptable degraded outcome); kobold gear and crafting are otherwise intact.
- **Skulking Filth baked in**: `[ITEM_THIEF]` added to `HA_KOBOLD_CAVES` (without `SKULKING`, so war
  and diplomacy still work) -- the Skulking Filth addon (workshop 2925069486).

## v0.2 — Ancient Dragon caste + Dread Wyrm king
- Added the **Ancient Dragon** caste to HA_KOBOLD: ~0.2% POP_RATIO (kobold castes set to 500 each),
  asexual, four-legged/two-winged iron-scaled dragon body with a tail-slam attack, dragonfire
  (MATERIAL_EMISSION/DRAGONFIRE), FLIER + BUILDINGDESTROYER:2, FIREIMMUNE_SUPER, legendary
  (NATURAL_SKILL:15) in every combat skill, physical attributes 2000-3000, effectively immortal
  (MAXAGE override so it reaches age 1000+), size = full dragon (~5M) at 100 / giant elephant (~10M)
  at 1000. CREATURE_CLASS HA_DRAGON_RULER gates the throne.
- Added the **Dread Wyrm** position (ALLOWED_CLASS:HA_DRAGON_RULER, precedence 1, rules from location):
  the ancient-dragon king; vacant when the civ has no living dragon.

## v0.3 — Ancient Dragon megabeast
- Added **HA_ANCIENT_DRAGON**: a solitary `[MEGABEAST][DIFFICULTY:18]` (NOT `[POWER]`), based on the
  vanilla dragon with the same custom design as the caste -- asexual (no castes, no egg-laying),
  4 legs + 2 wings + tail (tail-slam), iron scales, dragonfire, FLIER + BUILDINGDESTROYER:2,
  legendary combat, phys 2000-3000, size dragon@100 / giant-elephant@1000, MAXAGE 1000-1500,
  LAIR:SIMPLE_BURROW + HABIT:COLLECT_WEALTH (it hoards). Lairs the world alongside vanilla beasts.
- Dragon lifespan changed from effectively-immortal to **MAXAGE:1000:1500** (long but mortal, per
  request) for both the caste and the megabeast.

## v0.4 -- dragon graphics (layered, procedural colour, flash-free)
- Adapted **Naut's Procedural Dragons** sprite sheet + body palette (copied HA-namespaced). The
  ancient dragon renders as a LAYERED composite -- body + tail + both wings + head -- each part a
  LAYER_GROUP whose colour variants are chosen by the scale-tissue colour and recoloured by a
  body-palette row (Naut's palette-remap system). 15 classic dragon colours aligned between the
  raws TL_COLOR_MODIFIER and the graphics, so EVERY rollable colour has a matching layer and no
  state ever falls back to grayscale (this is the grayscale-flash fix the elder brain/drider had).
- Fixed 4-leg body only (no wyvern/two-legged/multi-head forms) per request; procedural colour only.
- Done for BOTH: the wild **HA_ANCIENT_DRAGON** megabeast (own CREATURE_GRAPHICS) and the
  **ANCIENT_DRAGON caste** in HA_KOBOLD (composite injected into all three layer sets, every layer
  CONDITION_CASTE:ANCIENT_DRAGON so it never renders on kobolds; the kobold body layers were already
  FEMALE/MALE-conditioned so they never render on the dragon -- no leak either way).

## v0.5 -- dragonscale skin, dragon values, shadow fix
- **Dragonscale skin** replaces the literal-iron override: the scale material now has structural
  strength a touch above iron (impact/compressive yield 600k vs iron 542k, edge 11000 vs 10000) but
  is EXTREMELY light (SOLID_DENSITY 200 vs iron 7850) and valuable (MATERIAL_VALUE 30), flagged
  ITEMS_ARMOR/SCALED/SOFT -- butchered dragonscale is prized for light armour and dragonscale cloaks.
  It stays an organic (butcherable) tissue, so no inorganic-tissue finalization risk.
- **Draconic personality.** Cultural VALUEs are entity-only in DF and the kobold civ keeps its own
  culture (lawless, cunning, communal, playful thieves -- unchanged from CKC/Skulking Filth). The
  dragon's distinctiveness is its PERSONALITY facets instead (on both the caste and the megabeast):
  extreme GREED, high PRIDE and CRUELTY, low ALTRUISM, wrathful (ANGER/VENGEFUL), fearless, aloof --
  a D&D chromatic temperament. A dragon ruler thus has a draconic character but shares its kobolds'
  cultural values (it rules among them).
- **Shadow flash fix**: the kobold SHADOW layer was ungated, so it drew on the dragon caste; it is now
  CONDITION_CASTE:FEMALE/MALE like the body layers, so it no longer renders on dragons.

## v0.7 -- dragon power tags
- Added Tier-1 resilience to both the caste and megabeast: NOFEAR, NOPAIN, NOEXERT, NONAUSEA,
  NO_DIZZINESS, NO_FEVERS, NO_PHYS_ATT_RUST, TRANCES (martial fury), EXTRAVISION, and TRAPAVOID
  (a dragon isn't caught by a cage/weapon trap; the caste already inherited it from the kobold).
  Confirmed BUILDINGDESTROYER:2 (full siege-breaker) on both.
- Deliberately NOT applied: NOSTUN (stays stunnable -- the intended counterplay), NO_SLEEP (they
  sleep), NOEMOTION (they keep their greedy/proud temperament), and no Tier-2 immunities
  (webs / paralysis / drowning remain viable ways to bring a dragon down).

## v0.8 -- dragonscale is heat-inert
- Dragonscale material is now fully heat-inert (SPEC_HEAT:NONE plus MELTING/BOILING/IGNITE/HEATDAM/
  COLDDAM points all NONE): dragonscale armour is immune to dragonfire and magma and has no specific
  heat. Removed the megabeast's blanket SPEC_HEAT:30000 (from the vanilla-dragon fireproof block) so
  it can't override the scale's heat-inertness.

## TODO (next)
- (DONE) Ancient Dragon caste in HA_KOBOLD (~0.2% POP_RATIO, asexual, dragon body/fire/flight/iron-skin,
  tail attack, dragon-size@100 / giant-elephant@1000, legendary combat, phys 2000-3000) + the
  Dread Wyrm king position (ALLOWED_CLASS-gated to the dragon caste).
- (DONE) HA_ANCIENT_DRAGON [MEGABEAST][DIFFICULTY:18] (same dragon design; not POWER).
- (DONE) Dragon graphics -- see v0.4.
