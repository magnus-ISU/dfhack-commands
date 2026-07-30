# ha-drow — fork changelog

## v0.48 -- drop the dead HA_DROW_BODY_SPECIAL tile page
- The page declared `[FILE:images/dark_elf_body_special.png]`, which has never
  existed in this mod or in upstream Dark Elves Redux, and which no creature
  graphic references. Removed rather than left pointing at nothing.
- Upstream has the identical dead declaration; this is a fix, not a divergence in
  behaviour -- nothing rendered from it either way.

## v0.45 -- expansion limited to mountains and forests
- Dropped `SETTLEMENT_BIOME` grassland/savanna/shrubland and their `BIOME_SUPPORT`
  entries; drow now only settle (and expand to) mountains and forests. River and
  subterranean support weights kept.

## v0.38 -- drop the ocean experiment
- Removed the 10:1 ocean `BIOME_SUPPORT` and restored MOUNTAIN 3 / subterranean 3-2. MOUNTAIN
  stays the first entry because it is the `EXCLUSIVE_START_BIOME`.
- `MAX_SITE_POP_NUMBER` 1000 -> 120, matching vanilla.

## v0.37 -- experiment: ocean-weighted expansion
- Same 10:1 ocean pull as the high elves, and MOUNTAIN moved to the first `BIOME_SUPPORT`
  entry because it is the `EXCLUSIVE_START_BIOME` -- the first entry should be the start biome
  or nothing past the first settlement is founded. Subterranean weights flattened to 1.
- Result over 250 years: 129 entities, 3,006 population -- a small civ, and drow historical
  figures peak at 282 and settle near 206. Suggestive but not proven; between-world variance
  is large enough that this needs several seeds.

## v0.35
- **Fixed driders flashing grayscale.** The drider has its own dedicated
  `CREATURE_CASTE_GRAPHICS:HA_DROW:DRIDER` (a LARGE_IMAGE sprite), but the parent
  `CREATURE_GRAPHICS:HA_DROW` in graphics_ha_drow.txt was *also* conditioning all
  370 of its body layers on `[CONDITION_CASTE:DRIDER]`, so driders were drawn by
  both at once and flickered between the layered drow body and the large image.
  Removed every `[CONDITION_CASTE:DRIDER]` from the parent layered graphics (the
  layers now cover FEMALE/MALE only), so driders render solely from their own
  large image. Same class of bug as the illithid Elder Brain grayscale flash.
  (The corpse, statue, and portrait files had no conflict -- the portrait file
  keeps its DRIDER conditions, an intentional fall-through.) Graphics change ->
  reload graphics / new world to see it.

## v0.34
- **Driders never sleep** (NO_SLEEP added beside NOSTUN - ends the drowse loop).
- **Boots and pants impossible, stance unbreakable**: no external part carries
  STANCE or LOWERBODY anymore. Instead the abdomen contains internal parts -
  two chitin-sheathed "leg-roots" (STANCE) and "vitals" (LOWERBODY). Internal
  parts cannot be equipped over and cannot be struck except through the armored
  abdomen, so: zero boots, zero greaves/pants, and no toppling from foot wounds.
- Armor-wearing parts audit: upper body/head/arms/hands are ordinary drow flesh
  (standard skin-fat-muscle); chitin covers exactly the spider parts - abdomen,
  all eight legs and feet, and now the internal roots.

## v0.33
- **Weapons**: added halberds and pikes (ordered), plus crossbows+bolts and large
  daggers (the hand-crossbow-and-poisoned-knife kit any drow expects).
- **Drider armor fixed** (body surgery): cephalothorax renamed **upper body** and
  given the lower-body flag; abdomen no longer a pants slot; only the front pair
  of feet bear STANCE. Result: 1 helm, breastplate + mail shirt on the upper body,
  gauntlets on hands, exactly one pair of boots (front legs), no greaves-on-abdomen.
  Trade-off: front-foot injuries topple her like a biped, and pants-class items
  technically fit the upper body (avoid in uniforms).

## v0.21 — drider art: root cause was upstream
- Diagnostics isolated the failure: LARGE_IMAGE never renders inside
  CREATURE_CASTE_GRAPHICS (single tiles do), and creature-level appends never
  parsed because **Dark Elves Redux ships a stray lone `]` mid-file** (line
  ~5254), desyncing the raw parser for everything after it - the source of every
  "Unrecognized Graphics Token" cascade and several silently-broken DER armor
  layers. Stray bracket removed; single-pass rebuild: set-end caste conditions
  (adult sets FEMALE/MALE; baby/child also DRIDER so drider young wear drow child
  art), plus a creature-level caste-scoped LARGE_IMAGE set for the drider sprite
  (the Naut-proven container). Caste-graphics file removed.

## v0.18 — drider art: clean-room architecture
- Errorlog revealed the true blocker: "Unrecognized Graphics Token" cascades in the
  layered drow file - my five generations of surgical edits had desynced the parser,
  which then swallowed the appended drider sets (even the Naut-verbatim one). Also
  restored surface settlement (v0.17 entry) after a deploy hiccup.
- New architecture, all proven parts: the DER layered file is **regenerated pristine**
  (rename-only, zero edits); the drider caste is renamed **DRIDER** (no FEMALE
  substring); its art lives in its own file as `CREATURE_CASTE_GRAPHICS:HA_DROW:DRIDER`
  (the Topples-orc container, proven in-suite) holding one `LARGE_IMAGE` layer set
  (the Naut-dragon layer form, proven upstream). Vanilla merpersons prove caste- and
  creature-graphics coexist with caste taking precedence - which should also end the
  hair leak without touching the DER file at all.
- Naut diagnostic assets removed. Note: drider children currently have no dedicated
  child set; revisit after adult sprite is confirmed.

## v0.16
- **Chosen of Lolth**: the mayor's office renamed (female-only).
- **Landed titles de-dwarfed**: baron → **matron**, count → **high matron**,
  duke → **grand matron** (all female-only). (First attempt stripped their
  NAME_MALE/NAME_FEMALE-only names without substituting - repaired.)

## v0.15
- **"Champion" noble fixed**: the old champion merge left a second
  `[NAME:champion:champions]` inside the priestess block, which overrode the
  display name. Removed; the office is the **high priestess** (champion morale
  duties + health management, female).
- **Drider chitin vs blunt force**: impact yield/fracture raised to
  600k/1200k - abdomen no longer fractures from embark wildlife; iron and steel
  edges still cut (shear unchanged).
- **Drider art diagnostic, Naut-exact**: set-level caste conditions moved to the
  END of each layer set (Naut's actual placement - mine were at the front);
  drider set now uses Naut's own dragon sheet, page id, palette file, and a
  known-good LARGE_IMAGE region verbatim. If a drider now renders as a dragon
  wing, the structure works and we swap the sprite back in; if not, it's
  engine-level and we go single-tile.

## v0.14
- **Noble court reworked**: **priestess** (champion duties + health management, female),
  **mistress of pain** (captain of the guard + dungeon master + executions by whip,
  female), **mouth of the queen** (manager + broker, male), **lady of whispers**
  (record keeper, female). Chief Medical Dwarf, Hammerer, Dungeon Master, and Broker
  positions absorbed/removed - no drow position bears a dwarven title. (Sweep
  confirmed no other suite civ uses "chief medical dwarf"; dark dwarves keep theirs.)
- **Drider art, Naut's-canonical form**: whole LAYER_SETs are now caste-scoped
  (set-level CONDITION_CASTE, the pattern Naut's dragons prove) - drow sets scoped
  FEMALE/MALE (+DRIDER_FEMALE on baby/child so drider young use drow child art),
  plus a drider-only DEFAULT set holding the 3x3 LARGE_IMAGE layer with its own
  palette block.

## v0.13
- Script renamed to **high-adventure/drow** (auto-enables next reload).

## v0.11
- **Forest retreats are never occupied**: TREE_CITY tolerance removed — a site a civ
  does not tolerate is razed on conquest, so drow victories over elves leave burned
  groves, not drow colonies. (Cities, dark fortresses, caves, and fortress-kind
  sites are still occupied.)

## v0.10
- **Expansion by the sword only**: drow now tolerate every conquerable site family
  (city, dark fortress, tree city, cave, plus their own fortress kind) so victories
  become occupied sites — while `SETTLEMENT_BIOME:MOUNTAIN` keeps peaceful founding
  inert (measured: zero sites founded all history). Their empire can only grow the
  drow way.

## v0.8 — drider art, the real fix
- Root cause found: `graphics_ha_drider.txt` was silently lost in the v0.2 art
  rebuild (that script crashed on an image copy before writing it) — driders have
  had NO sprite definition since; v0.4 only fixed the hair leak.
- Rebuilt using the form Naut's Procedural Dragons proves works in current DF:
  `LARGE_IMAGE` inside a layered `LAYER` entry, caste-conditioned
  (`[LAYER:DRIDER_BODY:HA_DRIDER:LARGE_IMAGE:0:0:2:2]` +
  `[CONDITION_CASTE:DRIDER_FEMALE]`), added to all three layer sets (baby/child/
  adult). The `CREATURE_CASTE_GRAPHICS`+LARGE_IMAGE combo (no vanilla precedent)
  is abandoned; the tile page remains.
- Hot-deployed to the live world snapshot — **restart DF** to load textures.

## v0.7
- **Goblin slaves no longer count as population**: `CAN_LEARN` made the engine
  classify tame slaves as fort *members* rather than animals (verified live:
  citizen count included them). `CAN_LEARN` and `SLOW_LEARNER` removed - they
  are now true livestock. Applied to the source, the live world snapshot, and
  hot-patched onto the running fort's units (citizens 9 -> 7 on the spot).
- Trade-off: no skill learning - war slaves still train, pull wagons, smash walls
  in sieges, and wear their sword/shield/armor kit, but fight at natural skill.

## v0.6
- **War-slave equip fixed and expanded**: the script used a DFHack enum that no
  longer exists (`unit_inventory_item.T_mode` → `inv_item_role_type`), so nothing was
  ever issued; also it required a manual `enable`. Now enum-compatible, **auto-enables
  on fort load**, and the kit gains a **tower-cap shield** — only noble drow are above
  such things. Verified live: two war goblins armed in the running fort.
- **Every drow is born a soldier**: `NATURAL_SKILL` 4 in fighter, dodger, sword,
  archer, and bowman on all castes (driders included) — worldgen war aid; applies to
  newly generated worlds.

## v0.4
- **Drider art fix**: DER's layered set applied its unconditioned layers (hair etc.) to
  every caste — the "hair but nothing else" drider. All 834 unconditioned layers now
  duplicated into explicit `CONDITION_CASTE:FEMALE`/`MALE` copies, so drider castes get
  zero layered art and only the static 3×3 sprite renders — always the same image
  regardless of worn items or coloring, as designed.
- Drider description: "A monstrous cross of spider and lady, blessed by evil gods to
  bring death!"
- **Cavern livestock only**: removed all `COMMON_DOMESTIC_*` (no surface farm animals);
  `USE_CAVE_ANIMALS`; ANIMAL blocks now: giant cave spiders (pet+siege), **cave dragons**
  (pet+siege), and **goblin slaves**.
- **`HA_GOBLIN_SLAVE`** — vanilla goblin fork, "A medium-sized humanoid subjected to
  cruelty by its evil masters." `INTELLIGENT` removed, `CAN_LEARN`+`SLOW_LEARNER` kept
  (trainable, skill-learning livestock — the troll model), `PET`, `WAGON_PULLER` (always
  pulls drow caravans), `PACK_ANIMAL`, `TRAINABLE`, **`BUILDINGDESTROYER:2`** — drow
  sieges bring wall-smashing enslaved goblins, troll-engineer style. Doesn't eat, drink,
  or sleep (goblin heritage). Uses vanilla goblin art re-keyed.
- Note: `CAVE_DRAGON` refers to the vanilla creature; Naut's Procedural Dragons cuts it
  to a stub — with that mod loaded, drow simply have no cave dragons (harmless).

## v0.3
- Final descriptions ("...hate all lesser races." / "A monstrous cross of spider and
  lady, they are blessed by evil gods to bring death!").
- **Hardened drider chitin**: shear/impact yield+fracture overridden to 200000 —
  copper (70k), bronze (~175k), and wooden weapons cannot pierce it at all; iron and
  steel edges still can; blunt weapons unaffected by design.
- **Dark palette for drow descriptions/art coherence**: skin/hair/eye color modifiers
  swapped from vanilla elf to Dark Elves Redux's sets (black/charcoal/gray/lavender
  skin, white/silver hair, purple/violet/indigo eyes).
- Note on the v0.2 invisible-art report: the game indexes graphics files at launch,
  and the art swap happened while DF was running — the session held dead file names.
  **Restart DF before judging art.** Version bumped (2→3) so existing worlds refresh
  their installed copy.

## v0.2
- **Fixed a generator bug that broke the whole creature in v0.1**: the giant-cave-spider
  bite extraction over-ran and pasted GCS content (including its `[CASTE:FEMALE]`/
  `[CASTE:MALE]` declarations) into the drow, re-declaring FEMALE bodiless → DF added
  `DOES_NOT_EXIST` ("HA_DROW:FEMALE has no body parts" in errorlog). v0.1 worlds had no
  working drow. Extraction now ends at `[ALL_ACTIVE]`.
- **Castes**: FEMALE 46, MALE 50, DRIDER_FEMALE 4 — **no male driders**. Gender creature
  classes added (`HA_DROW_FEMALE`/`HA_DROW_MALE`) for position gating.
- **Dark vision**: `LOW_LIGHT_VISION:10000` (adventurers can see underground).
- **Sites corrected**: NOT goblin dark fortresses — `CAVE_DETAILED` (dwarven fortress/
  mountain-hall family), `EXCLUSIVE_START_BIOME:MOUNTAIN`, `SETTLEMENT_BIOME:MOUNTAIN`
  only → insular non-expanding mountain civs (the dark-dwarf-v0.1 behavior, intended
  here), full surface+subterranean `BIOME_SUPPORT` for population, site cap **500**.
- **Weapons**: weighted list — scimitar ×10 (50%), bow ×5 (25%), scourge/whip/long
  sword/pick/battle axe ×1 each; **battle axes fell trees**; still no shields.
  (Weighting via duplicate WEAPON entries — verify in errorlog/worldgen; dual-wielded
  scimitars aren't raw-controllable, but players can set two-scimitar uniforms.)
- **Values**: CRAFTSMANSHIP 0 (indifferent), COMMERCE −30 (despised, caravans still run).
- **Matriarchy**: MONARCH → **queen** (female-only); CHAMPION+HAMMERER merged into one
  female-only **high priestess** (executions by whip + champion duties); militia
  commander/captains → **first honored male / honored males** (male-only); expedition
  leader → **matron mother** (female-only); manager/broker/bookkeeper unchanged.
- **Art swapped to Dark Elves Redux** (Endali): layered body/hair/wearables, portraits,
  statues, corpses — all pages and keys renamed `DARK_ELF`→`HA_DROW` so DER can coexist;
  statue tile page recovered from DER's item pages. Drider caste sprite unchanged.
- Descriptions set per design ("...hate all lesser races." / "...blessed by the evil
  gods to bring death!").

Sources: creature forked from **vanilla ELF** (creature_standard); entity forked from
**vanilla MOUNTAIN** (full dwarven industry); drider body forked from **FFF's
`SPIDER_CENTAUR_FFF`** (chipathingy), renamed `HA_DRIDER_CENTAUR`; drider venom and bite
copied verbatim from **vanilla giant cave spider**. All IDs `HA_*`; nothing vanilla touched.

## Creature (`creature_ha_drow.txt`) — `HA_DROW`
- Restructured to the per-caste-body pattern (lizardfolk-style): castes declared first,
  each with its own `[BODY:...]`, then `SELECT_CASTE:ALL` shared plans.
- Castes: FEMALE (48), MALE (48), **DRIDER_FEMALE (2), DRIDER_MALE (2)** → ~4% driders.
- Added creature-level `[EVIL]`, `[OUTSIDER_CONTROLLABLE]`, `[CAVE_ADAPT]`.
- Elf-inherited: no `MAXAGE` (ageless → near-never necromancers), sizes, skills.
- **Driders**: spider-centaur body + humanoid arms/head; **chitin tissue layered over the
  abdomen, legs, and feet** (natural armor; the unarmored humanoid torso is the weak
  point — armor it with mail/breastplate/helm/gauntlets, which their body supports);
  **giant-cave-spider paralytic venom** on a bite attack (same syndrome, renamed, drow
  immune); `WEBBER` + web-spray interaction; `WEBIMMUNE`, `NOSTUN`, `NOFEAR` (they DO
  tire — no NOEXERT); grows to **200,000 cm³** by age 18.
- Armor sizing note: driders need drider-sized gear (fort mode: the manager-order
  `specdata.race` technique; adventure mode: looted large armor). Coverage restrictions
  handle themselves via body parts (no boots/pants fit spider halves).

## Entity (`entity_ha_drow.txt`) — `HA_DROW_CIV`
- `DEFAULT_SITE_TYPE:DARK_FORTRESS`, `START_BIOME:ANY_LAND`, **zero `SETTLEMENT_BIOME`
  entries → deliberately insular: single spire-fortress civs that never expand** (per
  design), with `MAX_SITE_POP_NUMBER:500` so those single sites grow massive.
- `TRANSLATION:ELF`; full vanilla-dwarf job/reaction set (any metal incl. steel and
  adamantine); `SIEGE_SKILLED_MINERS` retained (goblin-slave sappers are future work).
- Weapons: **scimitar and bow only** (+ arrows); **no shields**; picks as diggers only.
- Evil bloc: `BABYSNATCHER`, `ABUSE_BODIES`, `BANDITRY:20` + `LOCAL_BANDITRY`,
  caravans **SPRING** only; progress triggers 3/3/3, sieges 4 (late-game threat).
- `ANIMAL` block: giant cave spiders `ALWAYS_PRESENT` + `ALWAYS_PET` + `ALWAYS_SIEGE`.
- Ethics: murder/torture/slavery/trophies/lying acceptable; cannibalism SHUNned (they're
  cruel, not dark dwarves). Values: power/cunning/craft high, truth/harmony negative.
- Religion spheres: caverns, darkness, night, treachery, murder, war, animals (no DEATH —
  combined with agelessness, necromancers stay near-nonexistent).

## Graphics
- Drow use the full vanilla elf art (layered sprites + portraits) re-keyed, palettes
  shipped. A dark-skin palette recolor is a later polish pass.
- **Driders** use `CREATURE_CASTE_GRAPHICS` with the user-made 96×96 (3×3
  `LARGE_IMAGE`) sprite — also our first live test of the large-image anchor convention.

## Known gaps / verify
- Drider armor sizing in fort mode (needs the specdata.race order trick or DFHack assist).
- Whether elf layered graphics also try to render drider castes over the caste sprite.
- `ha-always-hostile` DFHack script (per-member on-sight aggression) still to be written.
- Goblin-slave siege sappers still to be designed.

## v0.5
- **War-trained goblin slaves get gear**: new companion script (`enable ha-drow`) —
  any goblin slave reaching war-trained status is issued an obsidian short sword
  (wielded) and tower-cap wooden breastplate + helm (worn), via DFHack item creation.
  No shields, as befits drow doctrine. Announcement on each arming.
- (Drider art note: the earlier layer fix was verified correct in the installed
  files; the "hair only" sighting came from a session started before the fix was
  installed — graphics index at game launch, restart required.)

## v0.35
- Banditry 20 -> 40 (LOCAL already present).

## v0.36
- Graphics: removed the `ANIMATED` frame from the drider large sprite (it pointed at the same single frame, causing the grayscale flicker); static `DEFAULT` LARGE_IMAGE only, matching vanilla single-frame large creatures.
