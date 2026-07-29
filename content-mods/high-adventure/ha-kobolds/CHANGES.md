# ha-kobolds — build notes

## v0.18 -- horn alignment, tail tips, coloured extra heads
- **The default dragon head wore the wrong horns.** Naut's horn sprites on atlas row
  14 are anchored to the DRAKE head (they carry drake's `HEAD.HEIGHT 110-500` +
  `BODY_UPPER.HEIGHT 90-500` conditions); the set with no shape condition at all --
  the one drawn for the plain dragon head -- lives on row 16. The fallback head was
  using row 14, so those dragons wore horns a couple of pixels up and to the right
  while wyvern, wyrm and drake heads looked correct. Now uses row 16 (`18:16`, `21:16`,
  `24:16`).
- **Spiked and clubbed tails now draw their tips.** The body parts existed but nothing
  referenced them, so every tail rendered plain. Added `DRAGON_TAILCLUB1` (`0:28`) and
  the matching spike (`6:28`), gated on `TAIL_CLUBBED`/`TAIL_SPIKED`; both verified to
  align with the tail sprite at `6:0`.
- **Second and third heads were red on every dragon.** Those layers had no
  `CONDITION_TISSUE_LAYER`/`TISSUE_MAY_HAVE_COLOR`, and that condition is what tints a
  layer to the creature's scale colour -- not `USE_PALETTE`, which the kobold head
  layers do not even carry. Expanded both into the full 15 colour variants.
- Caste `POP_RATIO`s divided through by their GCD of 15: kobolds are now 4990/4990 with
  the six draconic castes at 8/8/1/1/1/1, summing to a round 10000 and still exactly
  0.2%. The megabeast's are 8/8/1/1/1/1.
- **Needs a new world.**

## v0.17 -- six ancient dragon castes, procedural head shapes
- **The single ancient dragon becomes multiple castes**, applied identically to the standalone
  `HA_ANCIENT_DRAGON` megabeast and to the draconic caste-set inside `HA_KOBOLD`:
  head count 1/2/3 at 80/10/10 and spiked vs clubbed tail 50/50 (the horn axis was
  dropped -- see below). Multi-headed frames carry a fixed four horns
  per head, which is how upstream bundles them.
- `POP_RATIO` sums to 300. The two kobold castes were rescaled from 500 to **74850** each
  so the draconic share stays exactly **0.2%**. Worldgen megabeast counts are per creature,
  not per caste, so this adds no extra megabeasts.
- **New `objects/body_ha_dragon.txt`**, ported from Naut's `body_new.txt`. Plan names carry
  an `HA_` prefix so they cannot collide with the upstream mod; the body part TOKENS are
  deliberately unchanged (`HD`, `NK`, `TRHORN`, ...) because the graphics layers match on
  tokens. Includes the `HA_DRAGON` frame -- a real `CATEGORY:NECK` neck and `CATEGORY:HEAD`
  head, replacing vanilla `QUADRUPED_NECK` whose neck was `CATEGORY:SPINE`.
- `HA_2HEAD_HORN` has no upstream equivalent (Naut ships only 4- and 6-horn sets) and is
  written here as the top pair alone. The 6-horn set was re-tokened so its top pair keeps
  the `TRHORN`/`TLHORN` names the sprites gate on.
- **Dragonfire now needs the organ**: every caste gets `HA_FIRE_SACK` and the breath moved
  from `BP_REQUIRED:BY_CATEGORY:MOUTH` to `FIRE_ORGAN`, so destroying the sack ends the
  fire without killing the dragon. Not copied from upstream, whose own gating asks for
  `BY_TOKEN:BIG_FIRE_SACK` -- that is the plan name, not the part token, so it can never
  match. Vapor/ice/venom sacks were skipped: upstream defines them but attaches them to no
  caste and references them in no interaction.
- **Graphics**: all 594 dragon layers were re-gated from the deleted `ANCIENT_DRAGON` caste
  onto the ten new ones. Horns are now gated on the real body parts (`TRHORN`/`TLHORN`,
  with `TRHORN1`/`TLHORN1` as an alternate layer for the multi-headed frames), so a severed
  horn disappears. Second and third heads draw from `HD2`/`HD3` presence with their own horn
  pairs.
- Version bumped to 17 rather than patched into 16 in place: the `ANCIENT_DRAGON` caste no
  longer exists, so an existing save holding dragons of that caste must keep loading 16.
- **Revised down to 6 castes and procedural head shapes.** The horn axis was dropped: the
  atlas carries exactly three horn positions per head shape (a top pair plus one lower
  left horn) and no 4- or 6-horn art at all, so 2/4/6-horn castes would have looked
  identical. Every dragon now gets the same three-horn set (`HA_HEAD_HORNS`) and the
  castes reduce to head count x tail = **6**: `POP_RATIO` 120 per single-headed caste and
  15 per multi-headed one, still summing to 300 and still exactly 0.2% of kobolds.
- **Head shape is now procedural, not caste-bound.** The head sprite is chosen from the
  head's own `BP_APPEARANCE_MODIFIER` rolls, upstream's own mechanism: narrow and short
  reads as a **wyvern** head, broad as a **wyrm**, tall (with a tall upper body) as a
  **drake**, and anything else falls back to the default **dragon** head. Added
  `BROADNESS`/`HEIGHT` rolls on the head and `HEIGHT` on the upper body to drive it.
- These four sprites carry the face themselves, so the separate eye layer was dropped --
  it existed only because the old head sprite was a featureless silhouette.
- **Horns are shape-matched**: wyvern heads get Naut's WYVHORN set, wyrm heads the
  WYRMHORN set, drake and dragon heads the plain long and medium sets, each gated on the
  real `TRHORN`/`TLHORN`/`LHORN` body parts.

- **Multi-headed dragons were one head (and one horn pair) short.** The head and horn
  layers were gated on `BY_TOKEN:HD` / `TRHORN`, but the 2- and 3-head frames name their
  parts `HD1`/`HD2`/`HD3` and `TRHORN1`... -- there is no plain `HD` on them, so the primary
  head simply never drew. Caught by spawning 100 of each caste and counting heads on screen.
  Head presence is now `BY_CATEGORY:HEAD`, which matches every frame, and each first-head
  horn layer gained a numbered alternate so the group resolves either spelling.

- **Needs a new world.**

## v0.16b -- the ancient dragon gets its face back
- **The head rendered as a featureless blob.** The base head sprite (Naut's `HEAD1`,
  page region 12:10:14:11) is only a snout-and-jaw silhouette -- it carries no face at
  all. Upstream stacks the eye and the two crown horns on top of it as separate layer
  groups; our port took the base and nothing else, on both the kobold ANCIENT_DRAGON
  caste and the standalone HA_ANCIENT_DRAGON megabeast.
- Added the eye plus both horns after the head group in all four composites (the caste's
  BABY/CHILD/DEFAULT layer sets and the megabeast's DEFAULT).
- The upstream conditions could not be copied verbatim: Naut gates these on its own body
  part tokens (`LEYE5`, `TRHORN5`, `TLHORN5`) and colours the iris from an `IRIS_EYE_*`
  tissue palette. Our dragons have `LEYE`/`REYE` but **no horn body parts at all**, and
  no `IRIS_EYE` colours are declared anywhere in the mod -- which is why the layers were
  dropped in the first place. So the eye is gated on `CONDITION_BP:BY_TOKEN:LEYE`
  (it correctly vanishes if the eye is destroyed) and renders in its baked colour, while
  the horns draw unconditionally, the same convention the legs port used.
- Smoke and the animated-neck layers were left out: they need a `FIRE_ORGAN` body part
  and a zombie syndrome class respectively.
- Graphics change: applies on save reload / new world.

## v0.16a -- the ancient dragon caste grows its legs back
- **Kobold ancient dragons rendered as a legless winged serpent.** The dragon composite
  in `graphics_creatures_cutekobold_layered.txt` had only five of the thirteen layer
  groups the sprite needs: body, head, tail and the two wings. All four legs and all
  four feet (front/back x left/right) were simply absent, even though the comment above
  it claimed a "full 4-leg dragon composite" -- the art on the HA_ANCIENT_DRAGONS page
  was always there, nothing pointed at it.
- Copied the eight missing leg/foot layer groups over from the standalone
  `HA_ANCIENT_DRAGON` megabeast graphics, into all three of the caste's layer sets
  (BABY, CHILD, DEFAULT), keeping Naut's draw order: right-side legs and feet UNDER the
  body, left-side legs and feet OVER it. Every added layer is `CONDITION_CASTE:
  ANCIENT_DRAGON` gated, so none of it can render on a plain kobold -- 585 dragon layers
  now, all caste-gated, 15 colour variants per region so no state falls back to grayscale.
- Graphics change: applies on save reload, no new world needed.

## v0.16 -- the Dread Wyrm executes
- Added `[RESPONSIBILITY:EXECUTIONS]` to the **Dread Wyrm**. The civ had no executioner of
  any kind; an ancient dragon overlord answers to nobody and kills whoever it likes.
- Note: the Dread Wyrm is a civ-level position (no `[SITE]`), so it only carries out
  sentences at the site it actually rules from. Needs a fresh world.

## v0.15 -- Speaker messengers
- Added **Speaker** (position id SPEAKER): SITE, NUMBER:AS_NEEDED, DELIVER_MESSAGES, appointed by
  the unique Head Speaker chain -- so the Head Speaker must exist before speakers are assignable,
  and the civ finally has unlimited messengers. Needs a fresh world.

## v0.14 -- dragon legs + new description
- The layered Ancient Dragon sprite was missing all four legs: the HA adaptation of Naut's sheet
  carried body/tail/wings/head layer groups but dropped Naut's leg+foot groups entirely. Added all
  8 groups (front/back x left/right leg + foot, adult regions from Naut's atlas) x 15 colours,
  sandwiched in Naut's draw order (right-side under the body, left-side over it). No CONDITION_BP:
  the legs ALWAYS render regardless of body-part state.
- New description for both the megabeast and the civ caste: "A huge winged creature full of dread
  majesty, it soars the skies with iron-hard scales immune to any fire."
- Graphics reach the active save via the installed_mods snapshot (restart DF); the description is
  baked raws -- new worlds only (live-patched in the running session via DFHack).

## v0.13 -- THE sterile-civ fix: bracketed tokens in comments
- Root cause of "0 kobold civs" across v0.10-v0.12 site-type experiments was NOT the site type:
  a design comment above the Ancient Dragon caste contained literal `[MALE]/[FEMALE]` -- DF's raw
  parser reads tokens anywhere, and coming right after `[SELECT_CASTE:ALL]` it stamped MALE then
  FEMALE onto every caste. Last token wins, so the MALE caste parsed as female (verified live:
  HA_KOBOLD castes FEMALE=0/MALE=0 vs vanilla KOBOLD MALE=1). A civ with no males is sterile, and
  sterile civs die out/never place in worldgen. De-bracketed the comment.
- Same bug class in creature_ancient_dragon.txt: header `[MEGABEAST]`/`[POWER]` (orphan tokens) and
  a mid-creature `[MALE]/[FEMALE]` comment that made the "asexual" megabeast female. De-bracketed.
- The v0.12 DARK_FORTRESS default site is kept -- it parsed and loaded correctly all along.
- Needs a fresh world.

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

## v0.9 -- item cleanup (vanilla-first)
- **Removed the 6 CKC custom toys** (doll, ball, hoop, wagon, toy knife, toy bow) -- their item defs,
  graphics, tile-page entry, image, and entity permits. Kobolds keep the vanilla toys and now also
  make **miniature hammers** ([TOY:ITEM_TOY_HAMMER]) alongside puzzleboxes and boats.
- **Removed the 3 oversized weapons** (war pick, saber, longstaff): they needed a size-20k-60k wielder
  (an adult kobold is ~20k) and the entity never granted them -- dead CKC leftovers. Deleted defs +
  graphics. The 9 remaining weapons are all kobold-sized (small axe/pick/hammer/mace/sword/knife,
  dagger, staff, sling).
- **Kobolds no longer manufacture full shields, only bucklers.** Dropped the forge shield token
  ([SHIELD:ITEM_SHIELD_SHIELD], kept [SHIELD:ITEM_SHIELD_BUCKLER]) AND un-permitted the two bone/shell
  full-shield crafting reactions (HA_MAKE_BONE_SHIELD, HA_MAKE_SHELL_SHIELD), keeping the buckler
  reactions. They can still use a full shield if they loot one -- these tokens only control what the
  civ knows how to make/issue.
- Kept per request: the 5 new pets (wooly spider, cave rat + giant cave rat, tame helmet snake + tame
  monitor lizard), the small kobold weapons, and all crafting/cleaning reactions.

## v0.10 -- fix civ worldgen placement
- **HA_KOBOLD_CAVES now reliably generates civilizations.** CKC's inherited
  START_BIOME was restricted to tropical/temperate wetlands + tropical rivers, so
  in worlds short on those biomes the kobold civ founded ZERO sites (a test world
  generated 0 HA kobold civs while vanilla broad-placement kobolds made 19).
  Added [START_BIOME:MOUNTAIN] + [START_BIOME:NOT_FREEZING] to match vanilla kobold
  breadth; the tropical/wetland START_BIOMEs and BIOME_SUPPORT weights are kept so
  they still lean toward swampy caves. (Pairs with ha-playable-civs no longer making
  vanilla SKULKING kobolds playable -- HA_KOBOLD_CAVES is the intended kobold civ.)

## v0.11 -- THE actual worldgen fix: kobolds found caves, not mountain halls
- v0.10's biome broadening was a red herring. Inspecting a freshly-genned world
  live (DFHack) proved HA_KOBOLD_CAVES *does* load and now has 28 start biomes
  (broader than vanilla kobolds' 25) yet still generated ZERO civs, while vanilla
  SKULKING kobolds made 9. The only remaining difference: `DEFAULT_SITE_TYPE`.
- **Root cause:** CKC's inherited `[DEFAULT_SITE_TYPE:CAVE_DETAILED]` resolves to
  world site type **MountainHalls** (the dwarf fortress type, enum 3) -- so kobolds
  tried to found mountain halls, which need mountain biomes and lose that niche to
  actual dwarves (who themselves only placed 4 civs). Result: no kobold civs.
- **Fix:** `[DEFAULT_SITE_TYPE:CAVE]` (enum 2, "Cave") -- the canonical kobold site
  type that vanilla SKULKING uses and that generates reliably across biomes. Pop cap
  is unchanged (MAX_SITE_POP_NUMBER:120). Kept the broadened START_BIOMEs from v0.10.

## v0.12 -- worldgen fix, round three: kobolds found pits (DARK_FORTRESS)
- v0.11's `[DEFAULT_SITE_TYPE:CAVE]` ALSO generated zero civs (verified live in
  region2, genned with v11: HA_KOBOLD_CAVES 0 civs / 0 entity populations while
  vanilla SKULKING kobolds placed 3 civs with near-identical baked start biomes
  and the same baked default_site_type enum). **Root cause:** Cave sites are
  pregenerated terrain features that only `SKULKING` civs move into; a
  non-SKULKING civ must *found* its default site at worldgen, and Cave is not
  foundable. Every foundable-site civ in the same world placed fine (CITY: orcs 7,
  high elves 7; DARK_FORTRESS: illithids 3, goblins 3; CAVE_DETAILED+mountain:
  drow/dark dwarves/succubi 1 each).
- **Fix:** `[DEFAULT_SITE_TYPE:DARK_FORTRESS]` + `[LIKES_SITE:DARK_FORTRESS]` --
  kobold *pits* (the PIT_BOSS flavor writes itself), foundable in any biome and
  empirically reliable for a custom non-goblin civ (HA_ILLITHID_CIV precedent).
  CAVE / CAVE_DETAILED stay liked/tolerated so kobolds still migrate into caves
  after worldgen. Mountain-halls and skulking-cave routes are documented as dead
  ends in the entity file.
- Needs a fresh world to test, like all raw changes. Verify with:
  `dfhack-run lua` counting Civilization entities whose `entity_raw.code ==
  "HA_KOBOLD_CAVES"` (expect >0, sites of type DarkFortress).

## TODO (next)
- (DONE) Ancient Dragon caste in HA_KOBOLD (~0.2% POP_RATIO, asexual, dragon body/fire/flight/iron-skin,
  tail attack, dragon-size@100 / giant-elephant@1000, legendary combat, phys 2000-3000) + the
  Dread Wyrm king position (ALLOWED_CLASS-gated to the dragon caste).
- (DONE) HA_ANCIENT_DRAGON [MEGABEAST][DIFFICULTY:18] (same dragon design; not POWER).
- (DONE) Dragon graphics -- see v0.4.
